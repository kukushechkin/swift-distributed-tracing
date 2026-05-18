//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Tracing open source project
//
// Copyright (c) 2020-2025 Apple Inc. and the Swift Distributed Tracing project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Tracing project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ServiceContextModule

/// Wraps an inner ``Instrument`` and adds task-local scoping on top of it. Bootstrapped at the application
/// root, it lets a scope layer additional instruments in front of `inner` without touching the global
/// bootstrap — useful for parallel-safe testing, per-tenant routing, and scoped overrides.
///
/// The opt-in is the bootstrap: an application that bootstraps a plain ``Instrument`` or
/// ``MultiplexInstrument`` pays no task-local read on any hot path. Apps that want scoping bootstrap with
/// this type, optionally wrapping a ``MultiplexInstrument`` for multiple base members.
///
/// ```swift
/// // Single tracer with scoping enabled.
/// InstrumentationSystem.bootstrap(TaskLocalInstrument(OTelTracer(configuration: config)))
///
/// // Multiple base instruments with scoping.
/// InstrumentationSystem.bootstrap(
///     TaskLocalInstrument(MultiplexInstrument([OTelTracer(...), metricsInstrument]))
/// )
///
/// // Unit test — parallel-safe, no global mutation.
/// @Test func spansAreCaptured() async {
///     let tracer = InMemoryTracer()
///     await TaskLocalInstrument.with(tracer) {
///         await withSpan("op") { _ in }
///     }
///     #expect(tracer.spans.count == 1)
/// }
/// ```
///
/// > Note: The task-local layer is shared across all ``TaskLocalInstrument`` instances in a process.
/// > A scope entered via ``with(_:_:)`` is observed by every reachable ``TaskLocalInstrument`` for the
/// > duration of the closure, regardless of which instance is reached during discovery or propagation.
@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
public struct TaskLocalInstrument: Sendable {
    private var inner: any Instrument

    /// Task-local additional members layered in front of `inner` for the duration of a ``with(_:_:)`` scope.
    /// Internal storage — callers enter scopes by calling ``with(_:_:)``.
    @TaskLocal internal static var scoped: [Instrument] = []

    /// Wrap an inner instrument with task-local scoping.
    ///
    /// - Parameter inner: The instrument to wrap. Defaults to ``NoOpInstrument`` so callers that only need
    ///   scoping (typically tests) can write `TaskLocalInstrument()` without picking a base.
    public init(_ inner: any Instrument = NoOpInstrument()) {
        self.inner = inner
    }

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
    /// > Warning: `Task.detached` does not inherit task-local values. A detached task sees only `inner` of
    /// > any reachable ``TaskLocalInstrument``. If scoped instrumentation is required inside a detached
    /// > task, wrap its body in ``with(_:_:)`` explicitly.
    ///
    /// - Parameters:
    ///   - instrument: The instrument to layer in front of any currently scoped members.
    ///   - operation: The closure to run with the layered instrument bound.
    /// - Returns: The value returned by the closure.
    public static func with<Result, Failure: Error>(
        _ instrument: any Instrument,
        _ operation: () throws(Failure) -> Result
    ) throws(Failure) -> Result {
        let merged = [instrument] + Self.scoped
        do {
            return try Self.$scoped.withValue(merged, operation: operation)
        } catch {
            // FIXME: remove when `TaskLocal.withValue` gains typed-throws support.
            // Safe today: `operation` has typed throws `throws(Failure)`, and `TaskLocal.withValue` is
            // `rethrows` — it does not introduce errors of its own, so every error reaching this catch
            // originated from `operation` and is therefore of type `Failure`.
            throw error as! Failure
        }
    }

    #if compiler(>=6.2)
    /// Async variant of ``with(_:_:)``. See that function for full documentation.
    ///
    /// - Parameters:
    ///   - instrument: The instrument to layer in front of any currently scoped members.
    ///   - operation: The async closure to run with the layered instrument bound.
    /// - Returns: The value returned by the closure.
    public nonisolated(nonsending) static func with<Result, Failure: Error>(
        _ instrument: any Instrument,
        _ operation: () async throws(Failure) -> Result
    ) async throws(Failure) -> Result {
        let merged = [instrument] + Self.scoped
        do {
            return try await Self.$scoped.withValue(merged, operation: operation)
        } catch {
            // FIXME: remove when `TaskLocal.withValue` gains typed-throws support.
            // Safe for the same reason as the sync variant above.
            throw error as! Failure
        }
    }
    #else
    /// Async variant of ``with(_:_:)``. See that function for full documentation.
    ///
    /// - Parameters:
    ///   - instrument: The instrument to layer in front of any currently scoped members.
    ///   - operation: The async closure to run with the layered instrument bound.
    /// - Returns: The value returned by the closure.
    public static func with<Result, Failure: Error>(
        _ instrument: any Instrument,
        _ operation: () async throws(Failure) -> Result
    ) async throws(Failure) -> Result {
        let merged = [instrument] + Self.scoped
        do {
            return try await Self.$scoped.withValue(merged, operation: operation)
        } catch {
            // FIXME: remove when `TaskLocal.withValue` gains typed-throws support.
            // Safe for the same reason as the sync variant above.
            throw error as! Failure
        }
    }
    #endif
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension TaskLocalInstrument: _InstrumentContainer {
    /// Walks scoped task-local entries first (innermost layered last via prepend, so it's at index 0),
    /// recursing through any nested ``_InstrumentContainer`` members. After the scoped layer is exhausted,
    /// descends into `inner` so conformers nested inside the wrapped instrument stay reachable.
    func firstInstrument(where predicate: (Instrument) -> Bool) -> Instrument? {
        for member in Self.scoped {
            if let container = member as? _InstrumentContainer {
                if let found = container.firstInstrument(where: predicate) { return found }
            } else if predicate(member) {
                return member
            }
        }
        if let container = self.inner as? _InstrumentContainer {
            return container.firstInstrument(where: predicate)
        } else if predicate(self.inner) {
            return self.inner
        } else {
            return nil
        }
    }
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension TaskLocalInstrument: Instrument {
    /// Inject scoped members first, then defer to `inner`. `inner` runs last and owns the final write for
    /// overlapping carrier keys.
    public func inject<Carrier, Inject>(_ context: ServiceContext, into carrier: inout Carrier, using injector: Inject)
    where Inject: Injector, Carrier == Inject.Carrier {
        for instrument in Self.scoped { instrument.inject(context, into: &carrier, using: injector) }
        self.inner.inject(context, into: &carrier, using: injector)
    }

    /// Extract through scoped members first, then defer to `inner`. `inner` runs last and owns the final
    /// write for overlapping `ServiceContext` keys.
    public func extract<Carrier, Extract>(
        _ carrier: Carrier,
        into context: inout ServiceContext,
        using extractor: Extract
    ) where Extract: Extractor, Carrier == Extract.Carrier {
        for instrument in Self.scoped { instrument.extract(carrier, into: &context, using: extractor) }
        self.inner.extract(carrier, into: &context, using: extractor)
    }
}
