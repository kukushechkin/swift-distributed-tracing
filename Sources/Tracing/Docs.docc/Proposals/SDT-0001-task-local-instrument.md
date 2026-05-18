# SDT-0001: task-local instrument

A wrapper instrument that adds task-local scoping on top of any inner ``Instrument``, giving applications
opt-in scoped overrides without process-global mutation — and without taxing apps that don't need scoping.

## Overview

- Proposal: SDT-0001
- Author(s): [Vladimir Kukushkin](https://github.com/kukushechkin)
- Status: **Awaiting Review**
- Issue: TBD
- Implementation: TBD
- Feature flag: none

### Introduction

This proposal adds ``TaskLocalInstrument`` and its static ``TaskLocalInstrument/with(_:_:)`` method.
The new type wraps any ``Instrument`` and adds a task-local layer of additional members entered via
``TaskLocalInstrument/with(_:_:)``. Applications that want scoped overrides bootstrap with this type;
applications that don't are unaffected.

### Motivation

``InstrumentationSystem/bootstrap(_:)`` installs an instrument **once** per process. From that point on every
free `withSpan` / `startSpan` call and every read of ``InstrumentationSystem/instrument`` resolves through
that single instrument. This works well for "one tracer for the whole application", but the one-shot,
process-wide constraint blocks two cases that matter in practice:

- **Parallel unit tests with per-test instruments.** Tests asserting on captured spans need an in-memory
  instrument scoped to the test, but `bootstrap` can only be called once per process (a second call crashes)
  and `bootstrapInternal` is `internal`. The workarounds are to serialize every span-emitting test or to
  thread a `Tracer` parameter through every library's public API — neither is good.

- **No scoped overrides.** An application cannot bind a different instrument for a subset of work. Routing
  spans from a subsystem through a local-only tracer for debugging, or augmenting `extract` per request with
  a tenant-specific propagator, has no clean path today.

```swift
public struct HTTPServer {
    public func handle(_ request: HTTPRequest) async throws -> HTTPResponse {
        var context = ServiceContext.topLevel
        InstrumentationSystem.instrument.extract(request.headers, into: &context, using: HTTPHeaderExtractor())
        return try await ServiceContext.$current.withValue(context) {
            try await withSpan("http.request") { _ in try await route(request) }
        }
    }
}
```

This library emits spans through the process-wide bootstrap — which works until any caller wants to scope
a different instrument for a subset of work: a subsystem routing through a debug exporter, a request
augmenting its propagation context, or a test capturing spans without mutating the state every other test
shares.

### Proposed solution

Introduce ``TaskLocalInstrument`` — a wrapper that carries an internal task-local layer of additional
members in front of an inner instrument. Applications that want scoped overrides bootstrap with it;
``TaskLocalInstrument/with(_:_:)`` enters scopes that are visible to every reachable
``TaskLocalInstrument`` until the closure returns.

```swift
// Single tracer with scoping enabled.
InstrumentationSystem.bootstrap(TaskLocalInstrument(OTelTracer(configuration: config)))

// Multiple base instruments with scoping — wrap a `MultiplexInstrument`.
InstrumentationSystem.bootstrap(
    TaskLocalInstrument(MultiplexInstrument([OTelTracer(configuration: config), metricsInstrument]))
)

// Unit test — parallel-safe, no global mutation.
@Test func spansAreCaptured() async {
    let tracer = InMemoryTracer()
    await TaskLocalInstrument.with(tracer) {
        await withSpan("op") { _ in }   // emits into `tracer`
    }
    #expect(tracer.spans.count == 1)
}
```

The opt-in is the bootstrap. An application that bootstraps a plain ``Instrument`` or ``MultiplexInstrument``
pays nothing on any hot path — the task-local read lives inside ``TaskLocalInstrument``'s methods, so it's
only consulted when the bootstrap chain reaches one. Apps that want scoping bootstrap with
``TaskLocalInstrument``, optionally wrapping a ``MultiplexInstrument`` for multiple base members.

### Detailed design

#### `TaskLocalInstrument`

A new public type alongside ``MultiplexInstrument``. Conforms to ``Instrument``, has a `Sendable`-friendly
internal `@TaskLocal` for the layered members, and exposes a static `with(_:_:)` for entering scopes.

```swift
@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
public struct TaskLocalInstrument: Sendable {
    /// Wrap an inner instrument with task-local scoping.
    ///
    /// - Parameter inner: The instrument to wrap. Defaults to ``NoOpInstrument`` so callers that only need
    ///   scoping (typically tests) can write `TaskLocalInstrument()` without picking a base.
    public init(_ inner: any Instrument = NoOpInstrument())

    /// Layer `instrument` in front of any currently scoped members for the duration of the closure.
    ///
    /// Inside the closure, every ``TaskLocalInstrument`` instance reachable from
    /// ``InstrumentationSystem/instrument`` walks the scoped layer before descending into its inner
    /// instrument. The newly layered instrument is prepended, so for nested ``with(_:_:)`` calls the
    /// innermost scope wins for discovery (``InstrumentationSystem/tracer``, free-function `withSpan` /
    /// `startSpan`). Propagation (`inject` / `extract`) iterates scoped forward then defers to `inner`,
    /// so the inner instrument is the last writer for overlapping `ServiceContext` or carrier keys; among
    /// nested scopes alone the outermost scope is the last writer.
    ///
    /// > Warning: `Task.detached` does not inherit task-local values. A detached task sees only `inner`
    /// > of any reachable ``TaskLocalInstrument``. If scoped instrumentation is required inside a detached
    /// > task, wrap its body in ``with(_:_:)`` explicitly.
    ///
    /// - Parameters:
    ///   - instrument: The instrument to layer in front of any currently scoped members.
    ///   - operation: The closure to run with the layered instrument bound.
    /// - Returns: The value returned by the closure.
    public static func with<Result, Failure: Error>(
        _ instrument: any Instrument,
        _ operation: () throws(Failure) -> Result
    ) throws(Failure) -> Result

    /// Async variant of ``with(_:_:)``. See that function for full documentation.
    #if compiler(>=6.2)
    public nonisolated(nonsending) static func with<Result, Failure: Error>(
        _ instrument: any Instrument,
        _ operation: () async throws(Failure) -> Result
    ) async throws(Failure) -> Result
    #else
    public static func with<Result, Failure: Error>(
        _ instrument: any Instrument,
        _ operation: () async throws(Failure) -> Result
    ) async throws(Failure) -> Result
    #endif
}
```

`Instrument` conformance iterates scoped members first, then defers to `inner`. The inner instrument runs
last and wins for overlapping `ServiceContext` or carrier keys — which keeps the bootstrapped tracer in
charge of `traceparent` and similar fields it owns.

```swift
extension TaskLocalInstrument: Instrument {
    public func inject<Carrier, Inject>(
        _ context: ServiceContext,
        into carrier: inout Carrier,
        using injector: Inject
    ) where Inject: Injector, Carrier == Inject.Carrier

    public func extract<Carrier, Extract>(
        _ carrier: Carrier,
        into context: inout ServiceContext,
        using extractor: Extract
    ) where Extract: Extractor, Carrier == Extract.Carrier
}
```

### API stability

- **Free `withSpan` / `startSpan` callers:** no change. Applications that don't bootstrap with
  ``TaskLocalInstrument`` see no behavioral change.
- **``InstrumentationSystem/instrument`` / ``InstrumentationSystem/tracer`` callers:** signatures unchanged.
  The accessors do not consult any task-local; they return the bootstrapped instrument directly. Behavior
  changes only when the bootstrap is (or contains) a ``TaskLocalInstrument`` and a scope is active.
- **``InstrumentationSystem/legacyTracer``:** unchanged. Still walks the bootstrapped instrument.
- **`Instrument` and `Tracer` implementations:** no new protocol requirements.
- **``LegacyTracer``-only implementations:** still discoverable, including when wrapped by a
  ``TaskLocalInstrument`` or layered into a scope.
- **``MultiplexInstrument``:** no public API change. ``MultiplexInstrument/firstInstrument(where:)`` is
  internal; its recursion now descends through the internal `_InstrumentContainer` protocol, which both
  multiplex types conform to.
- **``InstrumentationSystem/bootstrap(_:)`` users:** unchanged and not deprecated. The plain bootstrap
  remains the natural choice for a single process-wide tracer that never needs scoping.

### Future directions

**Explicit `tracer:` overloads on `withSpan` / `startSpan`.** For hot-path code that creates many spans, a
generic `tracer:` overload could accept a concrete tracer and return the concrete `Span` associated type,
bypassing existential dispatch.

**Opt-in replace semantics.** A paired variant such as ``TaskLocalInstrument/with(replacing:_:)`` that
shadows the outer scoped layer (and `inner`, optionally) instead of layering over them — for callers who
want full isolation, including overriding `traceparent` writes per request.

### Alternatives considered

#### Free function `withInstrument(merging:_:)` in core

A free `withInstrument(merging:_:)` with a task-local slot directly on ``InstrumentationSystem``, so every
read of ``InstrumentationSystem/instrument`` consults the task-local before falling back to the bootstrap.
Rejected because:

- It taxes apps that don't use scoping. Every read of ``InstrumentationSystem/instrument`` (and every free
  `withSpan` / `startSpan`) does a task-local read whether or not scoping is in play.
- It puts API surface in the core ``Instrumentation`` package whose only purpose is the new mechanism,
  rather than offering a self-contained instrument type that participates through the existing composition
  rules.

The wrapper pushes the cost behind an opt-in: only apps that bootstrap ``TaskLocalInstrument`` (or compose
one inside a regular ``MultiplexInstrument``) pay the task-local read, and even then only inside that
type's methods.

#### Wrapper types layered onto each protocol — `ScopedInstrument`, `ScopedTracer<U>`, `ScopedLegacyTracer`

Considered: provide one wrapper per instrument category — ``ScopedInstrument: Instrument``,
``ScopedTracer<U: Tracer>: Tracer where Span = U.Span``, ``ScopedLegacyTracer: LegacyTracer`` — each
holding its own task-local for typed discovery. Rejected because:

- ``ScopedTracer<U>`` is generic over a concrete `U`; its ``with(_:_:)`` only accepts instances of `U`.
  This kills the test-isolation use case, where tests need to substitute a different concrete tracer
  (an in-memory implementation) for the production tracer.
- Routing test isolation through ``ScopedLegacyTracer`` works but forces users into the deprecated
  ``LegacyTracer`` / `any Span` path even when their production tracer is modern.
- Three new public types plus a discoverability hook for the wrappers, vs. one new public type with
  composition through existing rules.

#### Replace semantics by default

Considered: have ``TaskLocalInstrument/with(_:_:)`` shadow the outer scoped layer instead of layering over
it. Rejected because it introduces a silent-NoOp failure mode — an app bootstraps a ``Tracer``, a scope
binds a pure propagator, and spans vanish because the scope's instrument is not a ``Tracer`` and the inner
tracer is shadowed. Layered prepend keeps inner tracers reachable while still letting an inner scope win
for span emission. A `with(replacing:_:)` variant is captured under future directions.

#### Task-local ``Tracer`` only, leave ``Instrument`` global

Rejected because it leaves distributed tracing half-configured: `withSpan` would resolve through task-local
but ``InstrumentationSystem/instrument`` — every boundary-crossing library's `extract` / `inject` accessor —
would still go through the global bootstrap. A test would capture spans but fail to read incoming trace IDs
from headers.

#### Expose `bootstrapInternal` publicly for tests

Rejected because it addresses only the testing half of the motivation and preserves the same one-shot,
process-global mutation model. Parallel tests would still race over one slot, and library authors would
still have no way to scope an instrument per request, tenant, or middleware.

#### Pass the instrument to the closure

`TaskLocalInstrument.with(instrument) { instrument in ... }` instead of
`TaskLocalInstrument.with(instrument) { ... }`.

Rejected because library code typically uses ``InstrumentationSystem/instrument`` and `withSpan` /
`startSpan` rather than calling methods on the instrument directly. Passing it to the closure would
encourage direct usage over the free-function API.
