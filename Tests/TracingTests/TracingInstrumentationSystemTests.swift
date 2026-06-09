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

import Testing
import Tracing

@testable import Instrumentation

extension InstrumentationSystem {
    fileprivate static func _legacyTracer<T>(of tracerType: T.Type) -> T? where T: LegacyTracer {
        self._findInstrument(where: { $0 is T }) as? T
    }

    fileprivate static func _tracer<T>(of tracerType: T.Type) -> T? where T: Tracer {
        self._findInstrument(where: { $0 is T }) as? T
    }

    fileprivate static func _instrument<I>(of instrumentType: I.Type) -> I? where I: Instrument {
        self._findInstrument(where: { $0 is I }) as? I
    }
}

/// All tests that touch `InstrumentationSystem` global state run here under a single `.serialized` suite.
/// Each test's `init` resets the bootstrap to `NoOpInstrument`, so individual tests can either mutate the
/// bootstrap (and rely on the next `init` to reset) or just enter scopes via
/// `InstrumentationSystem.withInstrument(_:_:)`.
@Suite("InstrumentationSystem", .serialized)
struct InstrumentationSystemTests {

    init() {
        InstrumentationSystem.bootstrapInternal(nil)
    }

    // MARK: - Bootstrap discovery

    @Test("Provides access to a tracer")
    func accessToTracer() {
        InstrumentationSystem.bootstrapInternal(nil)

        let tracer = TestTracer()

        #expect(InstrumentationSystem._legacyTracer(of: TestTracer.self) == nil)
        #expect(InstrumentationSystem._tracer(of: TestTracer.self) == nil)

        InstrumentationSystem.bootstrapInternal(tracer)
        #expect(InstrumentationSystem.instrument is MultiplexInstrument == false)
        #expect(InstrumentationSystem._instrument(of: TestTracer.self) === tracer)
        #expect(InstrumentationSystem._instrument(of: NoOpInstrument.self) == nil)

        #expect(InstrumentationSystem._legacyTracer(of: TestTracer.self) === tracer)
        #expect(InstrumentationSystem.legacyTracer is TestTracer)
        #expect(InstrumentationSystem._tracer(of: TestTracer.self) === tracer)
        #expect(InstrumentationSystem.tracer is TestTracer)

        let multiplexInstrument = MultiplexInstrument([tracer])
        InstrumentationSystem.bootstrapInternal(multiplexInstrument)
        #expect(InstrumentationSystem.instrument is MultiplexInstrument)
        #expect(InstrumentationSystem._instrument(of: TestTracer.self) === tracer)

        #expect(InstrumentationSystem._legacyTracer(of: TestTracer.self) === tracer)
        #expect(InstrumentationSystem.legacyTracer is TestTracer)
        #expect(InstrumentationSystem._tracer(of: TestTracer.self) === tracer)
        #expect(InstrumentationSystem.tracer is TestTracer)
    }

    @Test("Global tracing methods preserve arguments")
    func globalTracingMethods() async throws {
        // Bootstrap with TestTracer to capture spans
        let tracer = TestTracer()
        InstrumentationSystem.bootstrapInternal(tracer)

        // Create custom timestamps for testing
        let clock = DefaultTracerClock()
        let customInstant1 = clock.now
        let customInstant2 = clock.now
        let customInstant3 = clock.now

        // Create custom contexts to verify they're preserved
        var customContext1 = ServiceContext.topLevel
        customContext1[TestContextKey.self] = "context1"

        var customContext2 = ServiceContext.topLevel
        customContext2[TestContextKey.self] = "context2"

        // Test 1: startSpan with custom instant
        let span1 = startSpan(
            "startSpan-with-instant",
            at: customInstant1,
            context: customContext1,
            ofKind: .client
        )
        span1.end()

        // Test 2: startSpan without instant (uses default)
        let span2 = startSpan(
            "startSpan-default-instant",
            context: customContext2,
            ofKind: .server
        )
        span2.end()

        // Test 3: startSpan with instant (different parameter order)
        let span3 = startSpan(
            "startSpan-instant-alt",
            context: .topLevel,
            ofKind: .producer,
            at: customInstant2
        )
        span3.end()

        // Test 4: withSpan synchronous with custom instant
        let result1 = withSpan(
            "withSpan-sync-instant",
            at: customInstant3,
            context: customContext1,
            ofKind: .consumer
        ) { span -> String in
            #expect(span.operationName == "withSpan-sync-instant")
            return "sync-result"
        }
        #expect(result1 == "sync-result")

        // Test 5: withSpan synchronous without instant
        let result2 = withSpan(
            "withSpan-sync-default",
            context: customContext2,
            ofKind: .internal
        ) { span -> Int in
            #expect(span.operationName == "withSpan-sync-default")
            return 42
        }
        #expect(result2 == 42)

        // Test 6: withSpan synchronous with instant (alt parameter order)
        let result3 = withSpan(
            "withSpan-sync-instant-alt",
            context: .topLevel,
            ofKind: .server,
            at: clock.now
        ) { _ in
            "alt-result"
        }
        #expect(result3 == "alt-result")

        // Test 7: withSpan async with custom instant and isolation
        let result4 = await withSpan(
            "withSpan-async-instant-isolation",
            at: clock.now,
            context: customContext1,
            ofKind: .client,
            isolation: nil
        ) { span -> String in
            #expect(span.operationName == "withSpan-async-instant-isolation")
            return "async-result"
        }
        #expect(result4 == "async-result")

        // Test 8: withSpan async without instant but with isolation
        let result5 = await withSpan(
            "withSpan-async-default-isolation",
            context: customContext2,
            ofKind: .producer,
            isolation: nil
        ) { span -> Bool in
            #expect(span.operationName == "withSpan-async-default-isolation")
            return true
        }
        #expect(result5 == true)

        // Test 9: withSpan async with instant, isolation (alt parameter order)
        let result6 = await withSpan(
            "withSpan-async-instant-isolation-alt",
            context: .topLevel,
            ofKind: .consumer,
            at: clock.now,
            isolation: nil
        ) { _ in
            99
        }
        #expect(result6 == 99)

        // Verify all spans were recorded with correct properties
        let finishedSpans = tracer.spans
        #expect(finishedSpans.count == 9)

        let recorded1 = finishedSpans[0]
        #expect(recorded1.operationName == "startSpan-with-instant")
        #expect(recorded1.kind == .client)
        #expect(recorded1.context[TestContextKey.self] == "context1")
        #expect(recorded1.startTimestampNanosSinceEpoch == customInstant1.nanosecondsSinceEpoch)

        let recorded2 = finishedSpans[1]
        #expect(recorded2.operationName == "startSpan-default-instant")
        #expect(recorded2.kind == .server)
        #expect(recorded2.context[TestContextKey.self] == "context2")

        let recorded3 = finishedSpans[2]
        #expect(recorded3.operationName == "startSpan-instant-alt")
        #expect(recorded3.kind == .producer)
        #expect(recorded3.startTimestampNanosSinceEpoch == customInstant2.nanosecondsSinceEpoch)

        let recorded4 = finishedSpans[3]
        #expect(recorded4.operationName == "withSpan-sync-instant")
        #expect(recorded4.kind == .consumer)
        #expect(recorded4.context[TestContextKey.self] == "context1")
        #expect(recorded4.startTimestampNanosSinceEpoch == customInstant3.nanosecondsSinceEpoch)

        let recorded5 = finishedSpans[4]
        #expect(recorded5.operationName == "withSpan-sync-default")
        #expect(recorded5.kind == .internal)
        #expect(recorded5.context[TestContextKey.self] == "context2")

        let recorded6 = finishedSpans[5]
        #expect(recorded6.operationName == "withSpan-sync-instant-alt")
        #expect(recorded6.kind == .server)

        let recorded7 = finishedSpans[6]
        #expect(recorded7.operationName == "withSpan-async-instant-isolation")
        #expect(recorded7.kind == .client)
        #expect(recorded7.context[TestContextKey.self] == "context1")

        let recorded8 = finishedSpans[7]
        #expect(recorded8.operationName == "withSpan-async-default-isolation")
        #expect(recorded8.kind == .producer)
        #expect(recorded8.context[TestContextKey.self] == "context2")

        let recorded9 = finishedSpans[8]
        #expect(recorded9.operationName == "withSpan-async-instant-isolation-alt")
        #expect(recorded9.kind == .consumer)
    }

    @Test("InstrumentationSystem.tracer returns NoOpTracer when nothing is configured")
    func tracerDefaultsToNoOp() {
        InstrumentationSystem.bootstrapInternal(nil)
        #expect(InstrumentationSystem.tracer is NoOpTracer)
    }

    @Test("InstrumentationSystem.tracer falls back to bootstrap when no scope is entered")
    func tracerFallsBackToBootstrap() {
        let testTracer = TestTracer()
        InstrumentationSystem.bootstrapInternal(testTracer)

        let resolved = InstrumentationSystem.tracer
        #expect(resolved is TestTracer)
    }

    // MARK: - LegacyTracer-only discoverability

    @Test("Free withSpan finds a LegacyTracer-only bootstrapped tracer")
    func freeWithSpanFindsLegacyTracerOnly() {
        let legacyOnly = LegacyOnlyTestTracer()
        InstrumentationSystem.bootstrapInternal(legacyOnly)

        withSpan("legacy-op") { _ in }

        #expect(legacyOnly.startedOperationNames == ["legacy-op"])
    }

    @Test("Free startSpan finds a LegacyTracer-only bootstrapped tracer")
    func freeStartSpanFindsLegacyTracerOnly() {
        let legacyOnly = LegacyOnlyTestTracer()
        InstrumentationSystem.bootstrapInternal(legacyOnly)

        let span = startSpan("legacy-start")
        span.end()

        #expect(legacyOnly.startedOperationNames == ["legacy-start"])
    }

    @Test("Modern Tracer in bootstrap takes precedence over LegacyTracer-only in multiplex")
    func modernTracerWinsOverLegacy() {
        let legacyOnly = LegacyOnlyTestTracer()
        let modern = TestTracer()
        InstrumentationSystem.bootstrapInternal(MultiplexInstrument([legacyOnly, modern]))

        withSpan("multiplex-op") { _ in }

        #expect(modern.spans.count == 1)
        #expect(legacyOnly.startedOperationNames.isEmpty)
    }
}

// Test context key for verification
private enum TestContextKey: ServiceContextKey {
    typealias Value = String
}

// MARK: - LegacyTracer-only fixture
//
// Conforms to ``LegacyTracer`` ONLY (no ``Tracer`` conformance). Used to verify that the free
// ``withSpan`` / ``startSpan`` resolution chain still discovers a bootstrapped tracer that
// predates the ``Tracer`` protocol.
final class LegacyOnlyTestTracer: LegacyTracer, @unchecked Sendable {
    private(set) var startedOperationNames: [String] = []

    func startAnySpan<Instant: TracerInstant>(
        _ operationName: String,
        context: @autoclosure () -> ServiceContext,
        ofKind kind: SpanKind,
        at instant: @autoclosure () -> Instant,
        function: String,
        file fileID: String,
        line: UInt
    ) -> any Tracing.Span {
        self.startedOperationNames.append(operationName)
        return NoOpTracer.NoOpSpan(context: context())
    }

    func forceFlush() {}

    func extract<Carrier, Extract>(_ carrier: Carrier, into context: inout ServiceContext, using extractor: Extract)
    where Extract: Extractor, Extract.Carrier == Carrier {}

    func inject<Carrier, Inject>(_ context: ServiceContext, into carrier: inout Carrier, using injector: Inject)
    where Inject: Injector, Inject.Carrier == Carrier {}
}
