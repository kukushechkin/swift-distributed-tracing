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

@_exported import Instrumentation

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension InstrumentationSystem {
    /// Returns the current ``Tracer``, derived from ``InstrumentationSystem/instrument``.
    ///
    /// Walks the bootstrapped instrument, descending into ``MultiplexInstrument`` and
    /// ``TaskLocalInstrument`` members, and returns the first conformer to ``Tracer``. Returns
    /// ``NoOpTracer`` if no conforming instrument is found.
    ///
    /// When the bootstrap is a ``TaskLocalInstrument``, scoped members entered via
    /// ``TaskLocalInstrument/with(_:_:)`` are walked first.
    ///
    /// - Returns: The current ``Tracer``, or ``NoOpTracer`` if none is configured.
    public static var tracer: any Tracer {
        let found: (any Tracer)? =
            (self._findInstrument(where: { $0 is (any Tracer) }) as? (any Tracer))
        return found ?? _noOpTracerSingleton
    }

    /// Resolves the tracer used by the free-function ``withSpan(_:context:ofKind:at:function:file:line:_:)-8gw3v``
    /// and ``startSpan(_:context:ofKind:at:function:file:line:)`` overloads.
    ///
    /// Returns `any LegacyTracer` so that existing bootstraps holding a tracer that conforms only to the
    /// deprecated ``LegacyTracer`` protocol remain discoverable. Walks the bootstrapped instrument a single
    /// time, preferring a modern ``Tracer`` conformer and falling back to the first ``LegacyTracer``-only
    /// conformer encountered.
    internal static var _legacyOrModernTracer: any LegacyTracer {
        var firstLegacyOnly: (any LegacyTracer)?
        let modernMatch = self._findInstrument(where: { instrument in
            if instrument is (any Tracer) {
                return true
            }
            if firstLegacyOnly == nil, let legacy = instrument as? (any LegacyTracer) {
                firstLegacyOnly = legacy
            }
            return false
        })
        if let modern = modernMatch as? (any Tracer) {
            return modern
        }
        return firstLegacyOnly ?? _noOpTracerSingleton
    }

    /// Returns the ``Tracer`` resolved through the current ``InstrumentationSystem/instrument``.
    ///
    /// Walks the bootstrapped instrument, descending into ``MultiplexInstrument`` and
    /// ``TaskLocalInstrument`` members, and returns the first conformer to ``LegacyTracer``.
    /// Returns ``NoOpTracer`` if none is found.
    ///
    /// - Returns: A ``Tracer`` if one is reachable from the current instrument, otherwise ``NoOpTracer``.
    @available(*, deprecated, message: "prefer tracer")
    public static var legacyTracer: any LegacyTracer {
        let found: (any LegacyTracer)? =
            (self._findInstrument(where: { $0 is (any LegacyTracer) }) as? (any LegacyTracer))
        return found ?? _noOpTracerSingleton
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
private let _noOpTracerSingleton: NoOpTracer = NoOpTracer()
