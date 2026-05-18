//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Tracing open source project
//
// Copyright (c) 2020-2023 Apple Inc. and the Swift Distributed Tracing project authors
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
/// It is set up just once in a given program to select the desired ``Instrument`` implementation.
///
/// Set up the instrumentation using ``bootstrap(_:)``, and access the globally available instrument using ``instrument``.
/// If you need to use more that one cross-cutting tool you can do so by using ``MultiplexInstrument``.
///
/// To enable scoped overrides (per-test, per-tenant, per-subsystem) without process-global mutation,
/// bootstrap with ``TaskLocalInstrument`` and enter scopes via ``TaskLocalInstrument/with(_:_:)``.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)  // for TaskLocal ServiceContext
public enum InstrumentationSystem {
    /// Marked as @unchecked Sendable due to the synchronization being
    /// performed manually using locks.
    private final class Storage: @unchecked Sendable {
        private let lock = ReadWriteLock()
        private var _instrument: Instrument = NoOpInstrument()
        private var _isInitialized = false

        func bootstrap(_ instrument: Instrument) {
            self.lock.withWriterLock {
                precondition(
                    !self._isInitialized,
                    """
                    InstrumentationSystem can only be initialized once per process. Consider using MultiplexInstrument if
                    you need to use multiple instruments.
                    """
                )
                self._instrument = instrument
                self._isInitialized = true
            }
        }

        func bootstrapInternal(_ instrument: Instrument?) {
            self.lock.withWriterLock {
                self._instrument = instrument ?? NoOpInstrument()
            }
        }

        var instrument: Instrument {
            self.lock.withReaderLock { self._instrument }
        }

        func _findInstrument(where predicate: (Instrument) -> Bool) -> Instrument? {
            self.lock.withReaderLock {
                if let container = self._instrument as? _InstrumentContainer {
                    return container.firstInstrument(where: predicate)
                } else if predicate(self._instrument) {
                    return self._instrument
                } else {
                    return nil
                }
            }
        }
    }

    private static let shared = Storage()

    /// Globally select the desired ``Instrument`` implementation.
    ///
    /// - Parameter instrument: The ``Instrument`` you want to share globally within your system.
    ///
    /// > Warning: Do not call this method more than once. This will lead to a crash.
    public static func bootstrap(_ instrument: Instrument) {
        self.shared.bootstrap(instrument)
    }

    /// For testing scenarios one may want to set instruments multiple times, rather than the set-once semantics enforced by ``bootstrap(_:)``.
    ///
    /// - Parameter instrument: the instrument to boostrap the system with, if `nil` the ``NoOpInstrument`` is bootstrapped.
    internal static func bootstrapInternal(_ instrument: Instrument?) {
        self.shared.bootstrapInternal(instrument)
    }

    /// Returns the currently bootstrapped ``Instrument``, or a ``NoOpInstrument`` if none was set.
    ///
    /// If the bootstrapped instrument is a ``TaskLocalInstrument``, scoped members entered via
    /// ``TaskLocalInstrument/with(_:_:)`` participate when the returned instrument's methods are invoked —
    /// they're walked from `inject` / `extract` and from discovery (``tracer``, ``_findInstrument(where:)``).
    public static var instrument: Instrument {
        shared.instrument
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)  // for TaskLocal ServiceContext
extension InstrumentationSystem {
    /// INTERNAL API: Do Not Use
    ///
    /// Walks the bootstrapped instrument for the first member matching `predicate`. Recurses into
    /// ``_InstrumentContainer`` members, including ``MultiplexInstrument`` members and the scoped
    /// task-local layer of ``TaskLocalInstrument``.
    public static func _findInstrument(where predicate: (Instrument) -> Bool) -> Instrument? {
        self.shared._findInstrument(where: predicate)
    }
}
