# SDT-0001: task-local instrument

Adds `withInstrument(_:_:)` — a free function that binds an `Instrument` for a closure's task
scope. Applications choose between two mutually exclusive modes at startup: install once per process
via the existing `bootstrap`, or per task scope via `withInstrument`.

## Overview

- Proposal: SDT-0001
- Author(s): [Vladimir Kukushkin](https://github.com/kukushechkin)
- Status: **Awaiting Review**
- Issue: https://github.com/apple/swift-distributed-tracing/issues/168
- Implementation: TBD

### Motivation

Today the unit of instrument selection is the **process**: one instrument is installed at startup
and every `withSpan` for the lifetime of the process emits through it. This blocks any case that
wants a different tracer for a subset of work:

- **Parallel unit tests with per-test tracers.** A process-wide install can happen only once; tests
  that capture spans must serialize or thread a `Tracer` parameter through every library API.
- **Per-module / per-subsystem / per-request overrides.** No way to route a single subsystem through a different
  tracer for debugging, sampling overrides, tenant selection, or local-only export.

### Proposed solution

Introduce ``withInstrument(_:_:)``: a task-local that binds the active instrument for the duration
of a closure. Applications choose one of two modes at startup:

- **Bootstrap mode** — call ``bootstrap(_:)`` once at startup. ``withInstrument(_:_:)`` is a no-op
  in this mode (the closure runs against the bootstrapped instrument).
- **Scoped mode** — never call ``bootstrap(_:)``; wrap the program entry (and per-test, per-module,
  per-request closures) in ``withInstrument(_:_:)``. Nested scopes shadow their outer, the innermost
  is in effect.

**Bootstrap takes priority over the task-local** at runtime. ``withInstrument(_:_:)`` is library-safe
to call regardless of the application's mode: in bootstrap mode it is a silent no-op (the closure
runs against the bootstrapped instrument), so a library that uses ``withInstrument(_:_:)`` internally
won't break an application that has bootstrapped. The reverse — ``bootstrap(_:)`` called while a
``withInstrument(_:_:)`` scope is active in the current task — traps; bootstrap is meant to be the
first thing in `main`, before any scope is entered. **Libraries must not call ``bootstrap(_:)``** —
that decision belongs exclusively to the application.

```swift
// --- Scoped mode: wrap the entry point. Allows nested overrides. Do NOT also call bootstrap.
@main
struct Service {
    static func main() async throws {
        try await withInstrument(OTelTracer(configuration: config)) {
            try await Application.run()
        }
    }
}

// --- Bootstrap mode (no overrides anywhere in the process):
//   InstrumentationSystem.bootstrap(OTelTracer(configuration: config))
//   try await Application.run()

// Per-test (test target stays in scoped mode — never bootstraps):
@Test func spansAreCaptured() async {
    let tracer = InMemoryTracer()
    await withInstrument(tracer) {
        await withSpan("op") { _ in }
    }
    #expect(tracer.spans.count == 1)
}

// Per-module — route a subsystem through a debug tracer.
await withInstrument(debugTracer) { await runSubsystem() }

// Per-request — select between pre-built tracers.
let tenantTracer = tenantTracers[tenantID] ?? defaultTracer
try await withInstrument(tenantTracer) { try await handleRequest() }
```

### Detailed design

Two free-function overloads — sync and async — bind `instrument` as the task-local for the duration
of `operation`. The task-local is `@TaskLocal fileprivate static var _taskLocalInstrument:
(any Instrument)?` on ``InstrumentationSystem``; the free functions live in the same file and read
it via the synthesized `$_taskLocalInstrument` projection.

```swift
/// Replace the active ``Instrument`` with `instrument` for the duration of the closure.
///
/// Inside the closure, ``InstrumentationSystem/instrument``, ``InstrumentationSystem/_findInstrument(where:)``,
/// and the `tracer` / free-function `withSpan` / `startSpan` overloads (defined in the `Tracing`
/// module) resolve to `instrument`. Nested ``withInstrument(_:_:)`` calls each shadow their outer
/// scope; the innermost scope is the only one in effect.
///
/// > Note: ``withInstrument(_:_:)`` is library-safe to call regardless of the application's mode.
/// > If ``InstrumentationSystem/bootstrap(_:)`` has been called, the bootstrap takes priority — the
/// > scoped instrument has no effect and the closure runs as-is. This way a library that uses
/// > ``withInstrument(_:_:)`` internally doesn't break applications that bootstrap.
///
/// > Note: Scoping a non-``Tracer`` ``Instrument`` (a propagator-only) inside a
/// > ``withInstrument(_:_:)`` scope makes ``InstrumentationSystem/tracer`` resolve to ``NoOpTracer``
/// > for the duration — span emission is silenced just as it is when
/// > ``InstrumentationSystem/bootstrap(_:)`` installs a propagator-only. Use a ``MultiplexInstrument``
/// > containing a ``Tracer`` if you want both span emission and additional propagation.
///
/// > Warning: `Task.detached` does not inherit task-local values. In bootstrap mode a detached task
/// > sees the bootstrap (reads check bootstrap first); in scoped mode it sees ``NoOpInstrument``. If a
/// > scoped instrument is required inside a detached task, wrap its body in ``withInstrument(_:_:)``
/// > explicitly.
///
/// - Parameters:
///   - instrument: The instrument to install for the duration of the closure.
///   - operation: The closure to run with the scoped instrument bound.
/// - Returns: The value returned by the closure.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public func withInstrument<Result, Failure: Error>(
    _ instrument: any Instrument,
    _ operation: () throws(Failure) -> Result
) throws(Failure) -> Result

#if compiler(>=6.2)
/// Async variant of ``withInstrument(_:_:)``. See that function for full documentation.
///
/// `nonisolated(nonsending)` mirrors the pre-6.2 default (caller-isolated, no executor hop on entry).
/// Do not unify with the pre-6.2 branch — without this annotation under 6.2, the function would gain
/// an implicit hop into the global executor.
///
/// - Parameters:
///   - instrument: The instrument to install for the duration of the closure.
///   - operation: The async closure to run with the scoped instrument bound.
/// - Returns: The value returned by the closure.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public nonisolated(nonsending) func withInstrument<Result, Failure: Error>(
    _ instrument: any Instrument,
    _ operation: () async throws(Failure) -> Result
) async throws(Failure) -> Result
#else
/// Async variant of ``withInstrument(_:_:)``. See that function for full documentation.
///
/// - Parameters:
///   - instrument: The instrument to install for the duration of the closure.
///   - operation: The async closure to run with the scoped instrument bound.
/// - Returns: The value returned by the closure.
//
// Pre-6.2 toolchains predate SE-0461. The plain `func` here matches the pre-SE-0461 default
// (caller-isolated, no executor hop on entry), so the missing `nonisolated(nonsending)` is
// intentional, not an oversight — do not unify the branches.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public func withInstrument<Result, Failure: Error>(
    _ instrument: any Instrument,
    _ operation: () async throws(Failure) -> Result
) async throws(Failure) -> Result
#endif
```

#### Resolution

``InstrumentationSystem.instrument`` and `InstrumentationSystem._findInstrument(where:) ` resolve in this order:

1. **Bootstrap slot first.** If ``bootstrap(_:)`` has been called, return its value. The task-local
   is never read on this path.
2. **Task-local fallback.** Otherwise, return the active ``withInstrument(_:_:)`` scope, or
   ``NoOpInstrument`` if no scope is active.

### API stability

- **No protocol changes; existing public surface unchanged.** ``Instrument``, ``Tracer``, and
  ``MultiplexInstrument`` retain their signatures and behavior. ``InstrumentationSystem.instrument``,
  ``InstrumentationSystem.tracer``, and ``InstrumentationSystem.legacyTracer`` keep their
  signatures and stay source-compatible. Their *resolved value* depends on the application's chosen
  mode (Bootstrap or Scoped).
- **Bootstrap mode** (the path existing users follow) — `withSpan` performs one rwlock-guarded read
  per call to resolve the bootstrapped instrument; the task-local is never read on this path. Same
  cost shape as before this proposal.

### Future directions

**Explicit `tracer:` overloads on `withSpan` / `startSpan`.** For hot-path code that creates many
spans, a generic `tracer:` overload could accept a concrete tracer and return the concrete `Span`
associated type, bypassing existential dispatch and the resolution lookup entirely.

### Alternatives considered

#### A special Instrument type handling structured instruments inside it

One of the alternatives considered was a special instrument holding the task-local variable providing
extra API surface similar to `TaskLocalInstrument.withInstrument(scopedInstrument){}`.
The benefit of this approach is it is purely additive opt-in from the application point of view.
However, this special instrument type must be bootstrapped and if not, the whole API surface becomes
noop.

#### Task-local instrument to have higher priority than the bootstrapped one

Frame the task-local API as scoped override for the bootstrapped instrument. Rejected, becuase
every existing `bootstrap` user will now pay task-local check in every span.

#### Trap on `withInstrument(_:_:)` after `bootstrap(_:)`

Symmetric with the trap on `bootstrap(_:)` during a scope: if you call ``withInstrument(_:_:)`` after
``bootstrap(_:)``, fail loudly. Rejected because it makes ``withInstrument(_:_:)`` library-unsafe — a
library that uses it internally would crash any application that has bootstrapped, regardless of
whether the application asked for the library's scoping behavior or not. The chosen design (silent
no-op) preserves the property that adding a `withInstrument` call to a library cannot crash a
downstream application; the closure runs against the bootstrapped instrument instead.
