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

/// A pseudo instrument to use to instrument using multiple instruments across a
/// common service context.
public struct MultiplexInstrument {
    private var instruments: [Instrument]

    /// Create a multiplex instrument.
    ///
    /// - Parameter instruments: An array of ``Instrument``, each of which the tracer uses to
    /// ``Instrument/inject(_:into:using:)`` or ``Instrument/extract(_:into:using:)``
    /// through the same `ServiceContext`.
    public init(_ instruments: [Instrument]) {
        self.instruments = instruments
    }
}

extension MultiplexInstrument: _InstrumentContainer {
    /// Walks the multiplex looking for the first member that satisfies `predicate`, recursing into any
    /// nested ``_InstrumentContainer`` members.
    ///
    /// A nested container is never itself a candidate (it fails most useful predicates like `is Tracer`);
    /// the walk descends into it so conformers deeper in the tree stay reachable.
    func firstInstrument(where predicate: (Instrument) -> Bool) -> Instrument? {
        for member in self.instruments {
            if let container = member as? _InstrumentContainer {
                if let found = container.firstInstrument(where: predicate) {
                    return found
                }
            } else if predicate(member) {
                return member
            }
        }
        return nil
    }
}

extension MultiplexInstrument: Instrument {
    /// Extract values from a service context and inject them into the given carrier using the provided injector.
    ///
    /// - Parameters:
    ///   - context: The `ServiceContext` from which relevant information is extracted.
    ///   - carrier: The `Carrier` into which this information is injected.
    ///   - injector: The ``Injector`` to use to inject extracted `ServiceContext` into the given `Carrier`.
    public func inject<Carrier, Inject>(_ context: ServiceContext, into carrier: inout Carrier, using injector: Inject)
    where Inject: Injector, Carrier == Inject.Carrier {
        for instrument in self.instruments { instrument.inject(context, into: &carrier, using: injector) }
    }

    /// Extract values from a carrier, using the given extractor, and inject them into the provided service context.
    /// - Parameters:
    ///   - carrier: The `Carrier` that was used to propagate values across boundaries.
    ///   - context: The `ServiceContext` into which these values should be injected.
    ///   - extractor: The ``Extractor`` that extracts values from the given `Carrier`.
    public func extract<Carrier, Extract>(
        _ carrier: Carrier,
        into context: inout ServiceContext,
        using extractor: Extract
    )
    where Extract: Extractor, Carrier == Extract.Carrier {
        for instrument in self.instruments { instrument.extract(carrier, into: &context, using: extractor) }
    }
}
