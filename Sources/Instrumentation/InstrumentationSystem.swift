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

/// A global facility where the default cross-cutting tool can be configured.
///
/// Applications choose one of two modes:
///
/// - **Bootstrap mode** — call ``bootstrap(_:)`` once at startup to install a process-wide
///   ``Instrument``. Reads of ``instrument`` return it directly.
/// - **Scoped mode** — never call ``bootstrap(_:)``; wrap the program entry (and per-test, per-module,
///   per-request closures) in ``withInstrument(_:_:)``. Reads of ``instrument`` return the active
///   task-local scope (``NoOpInstrument`` if none is active).
///
/// **Bootstrap takes priority over the task-local.** Inside a ``withInstrument(_:_:)`` scope, a call to
/// ``bootstrap(_:)`` traps — bootstrap is meant to be the first thing in `main`, before any scope is
/// entered. Conversely, a ``withInstrument(_:_:)`` call after ``bootstrap(_:)`` is a silent no-op: the
/// closure runs against the bootstrapped instrument. This keeps ``withInstrument(_:_:)`` library-safe —
/// a library that uses it internally can't break a bootstrapping application.
///
/// Compose multiple cross-cutting tools through ``MultiplexInstrument``.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)  // for TaskLocal ServiceContext
public enum InstrumentationSystem {
    /// Marked as @unchecked Sendable due to the synchronization being
    /// performed manually using locks.
    private final class Storage: @unchecked Sendable {
        private let lock = ReadWriteLock()
        // `nil` means "not bootstrapped" — the system is in scoped mode (or has no instrument at all).
        private var _instrument: Instrument?

        func bootstrap(_ instrument: Instrument) {
            self.lock.withWriterLock {
                precondition(
                    self._instrument == nil,
                    """
                    InstrumentationSystem can only be initialized once per process. Consider using MultiplexInstrument if
                    you need to use multiple instruments.
                    """
                )
                self._instrument = instrument
            }
        }

        func bootstrapInternal(_ instrument: Instrument?) {
            self.lock.withWriterLock {
                self._instrument = instrument
            }
        }

        var instrumentIfBootstrapped: Instrument? {
            self.lock.withReaderLock { self._instrument }
        }
    }

    private static let shared = Storage()

    /// Task-local scoped instrument bound by ``withInstrument(_:_:)``. Read in scoped mode (no
    /// bootstrap) — see ``instrument`` for the full resolution path.
    @TaskLocal fileprivate static var _taskLocalInstrument: (any Instrument)?

    /// Globally select the desired ``Instrument`` implementation.
    ///
    /// Puts the ``InstrumentationSystem`` into bootstrap mode for the lifetime of the process. After
    /// this call, ``instrument`` returns `instrument` directly. Bootstrap takes priority over any
    /// ``withInstrument(_:_:)`` scope: a `withInstrument` call in bootstrap mode is a silent no-op,
    /// the closure runs against the bootstrapped instrument.
    ///
    /// - Parameter instrument: The ``Instrument`` you want to share globally within your system.
    ///
    /// > Warning: Do not call this method more than once per process. Doing so will trap.
    ///
    /// > Warning: Do not call this method while a ``withInstrument(_:_:)`` scope is active in the
    /// > current task. Doing so will trap. Bootstrap is meant to be the first thing in `main`, before
    /// > any scope is entered. Libraries must not call this method.
    public static func bootstrap(_ instrument: Instrument) {
        precondition(
            Self._taskLocalInstrument == nil,
            """
            InstrumentationSystem.bootstrap was called while a withInstrument(_:_:) scope is active in this task. \
            Bootstrap is meant to be called once, early in main, before any withInstrument scope is entered. \
            Libraries must not call bootstrap; this is exclusively the application's responsibility.
            """
        )
        self.shared.bootstrap(instrument)
    }

    /// For testing scenarios one may want to set instruments multiple times, rather than the set-once semantics enforced by ``bootstrap(_:)``.
    ///
    /// Passing `nil` clears the bootstrap state — useful for tests that flip between modes.
    ///
    /// - Parameter instrument: the instrument to bootstrap the system with, or `nil` to clear the
    ///   bootstrap state entirely.
    internal static func bootstrapInternal(_ instrument: Instrument?) {
        self.shared.bootstrapInternal(instrument)
    }

    /// Returns the current ``Instrument`` for use.
    ///
    /// - In bootstrap mode (``bootstrap(_:)`` has been called): returns the bootstrapped instrument.
    ///   The task-local is never read on this path — bootstrap-only users pay the cost of a single
    ///   rwlock-guarded read.
    /// - In scoped mode (no bootstrap): returns the active task-local scope, or ``NoOpInstrument`` if
    ///   no ``withInstrument(_:_:)`` scope is active in the current task.
    public static var instrument: Instrument {
        if let bootstrapped = shared.instrumentIfBootstrapped { return bootstrapped }
        return Self._taskLocalInstrument ?? NoOpInstrument()
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)  // for TaskLocal ServiceContext
extension InstrumentationSystem {
    /// INTERNAL API: Do Not Use
    ///
    /// In bootstrap mode, walks the bootstrapped instrument for the first member matching `predicate`
    /// (recursing through ``_InstrumentContainer`` members). In scoped mode, walks the active task-local
    /// scope the same way; returns `nil` if no scope is active.
    public static func _findInstrument(where predicate: (Instrument) -> Bool) -> Instrument? {
        if let bootstrapped = self.shared.instrumentIfBootstrapped {
            return Self._firstMember(of: bootstrapped, where: predicate)
        }
        guard let scoped = Self._taskLocalInstrument else { return nil }
        return Self._firstMember(of: scoped, where: predicate)
    }

    private static func _firstMember(
        of root: any Instrument,
        where predicate: (Instrument) -> Bool
    ) -> Instrument? {
        if let container = root as? _InstrumentContainer {
            return container.firstInstrument(where: predicate)
        } else if predicate(root) {
            return root
        } else {
            return nil
        }
    }
}

/// Replace the active ``Instrument`` with `instrument` for the duration of the closure.
///
/// Inside the closure, ``InstrumentationSystem/instrument``, ``InstrumentationSystem/_findInstrument(where:)``,
/// and the `tracer` / free-function `withSpan` / `startSpan` overloads (defined in the `Tracing`
/// module) resolve to `instrument`. Nested ``withInstrument(_:_:)`` calls each shadow their outer
/// scope; the innermost scope is the only one in effect.
///
/// > Note: ``withInstrument(_:_:)`` is library-safe to call regardless of the application's mode.
/// > If ``InstrumentationSystem/bootstrap(_:)`` has been called, the bootstrap takes priority — the
/// > scoped instrument has no effect and the closure runs as-is. If you're debugging and
/// > ``withInstrument(_:_:)`` appears to do nothing, check whether ``InstrumentationSystem/bootstrap(_:)``
/// > has been called elsewhere in the process.
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
) throws(Failure) -> Result {
    do {
        // Bind the task-local unconditionally. In bootstrap mode the binding has no observable effect
        // because ``InstrumentationSystem/instrument`` and ``_findInstrument`` always check the
        // bootstrap slot first — so this scope becomes a silent no-op without an extra rwlock read on
        // the hot path.
        return try InstrumentationSystem.$_taskLocalInstrument.withValue(instrument, operation: operation)
    } catch {
        // `TaskLocal.withValue` is `rethrows` over `operation`, which has typed throws
        // `throws(Failure)` — the only errors that flow out are typed `Failure`. Cancellation
        // propagates through the closure as `Failure`, not via `withValue`. The force cast is
        // unreachable in practice; it exists only because `rethrows` re-throws as `any Error`.
        throw error as! Failure
    }
}

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
) async throws(Failure) -> Result {
    do {
        return try await InstrumentationSystem.$_taskLocalInstrument.withValue(instrument, operation: operation)
    } catch {
        // See sync variant — unreachable; `rethrows` forces the catch to type-erase.
        throw error as! Failure
    }
}
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
) async throws(Failure) -> Result {
    do {
        return try await InstrumentationSystem.$_taskLocalInstrument.withValue(instrument, operation: operation)
    } catch {
        // See sync variant — unreachable; `rethrows` forces the catch to type-erase.
        throw error as! Failure
    }
}
#endif
