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

// MARK: - TaskLocalInstrument scoping tests
//
// These tests assume the suite's `init` has bootstrapped a baseline `TaskLocalInstrument()`,
// which makes scoped members entered via `TaskLocalInstrument.with(_:_:)` reachable from
// `InstrumentationSystem.instrument` and the free-function `withSpan` / `startSpan` overloads.

extension InstrumentationSystemTests {

    // MARK: - Scope resolution

    @Test("InstrumentationSystem.tracer returns scoped tracer entered via TaskLocalInstrument.with")
    func tracerReturnsScoped() {
        let testTracer = TestTracer()

        TaskLocalInstrument.with(testTracer) {
            #expect(InstrumentationSystem.tracer is TestTracer)
        }
    }

    @Test("Scoped instrument is not visible outside the with(_:_:) closure")
    func scopedNotVisibleOutsideClosure() {
        let testTracer = TestTracer()

        TaskLocalInstrument.with(testTracer) {
            #expect(InstrumentationSystem.tracer is TestTracer)
        }

        // Outside the scope, no scoped tracer is layered. With baseline `TaskLocalInstrument()` (which
        // wraps `NoOpInstrument`) and no other tracer reachable, discovery returns NoOp.
        #expect(InstrumentationSystem.tracer is NoOpTracer)
    }

    // MARK: - Nesting

    @Test("Nested with(_:_:) — innermost tracer wins for span creation")
    func nestedScopes() {
        let outerTracer = TestTracer()
        let innerTracer = TestTracer()

        TaskLocalInstrument.with(outerTracer) {
            #expect(InstrumentationSystem.tracer as AnyObject === outerTracer)

            TaskLocalInstrument.with(innerTracer) {
                // Each `with` prepends the layered instrument, so the innermost scope is at index 0 of
                // the scoped list and wins for discovery.
                #expect(InstrumentationSystem.tracer as AnyObject === innerTracer)
            }

            #expect(InstrumentationSystem.tracer as AnyObject === outerTracer)
        }
    }

    @Test("Innermost non-tracer falls through to outer tracer for span creation")
    func innermostNonTracerFallsThroughToOuter() {
        let outerTracer = TestTracer()
        let innerPropagator = NoOpInstrument()

        TaskLocalInstrument.with(outerTracer) {
            TaskLocalInstrument.with(innerPropagator) {
                // innerPropagator is not a Tracer, so discovery walks past it and finds outerTracer next.
                withSpan("op") { _ in }
            }
        }

        #expect(outerTracer.spans.count == 1)
        #expect(outerTracer.spans.first?.operationName == "op")
    }

    // MARK: - withSpan / startSpan integration

    @Test("withSpan emits into scoped tracer")
    func withSpanUsesScopedTracer() {
        let testTracer = TestTracer()

        TaskLocalInstrument.with(testTracer) {
            withSpan("test-operation") { span in
                span.attributes["key"] = "value"
            }
        }

        #expect(testTracer.spans.count == 1)
        #expect(testTracer.spans.first?.operationName == "test-operation")
    }

    @Test("startSpan emits into scoped tracer")
    func startSpanUsesScopedTracer() {
        let testTracer = TestTracer()

        TaskLocalInstrument.with(testTracer) {
            let span = startSpan("manual-span")
            span.end()
        }

        #expect(testTracer.spans.count == 1)
        #expect(testTracer.spans.first?.operationName == "manual-span")
    }

    // MARK: - MultiplexInstrument resolution

    @Test("withSpan finds a Tracer inside a MultiplexInstrument bound via with(_:_:)")
    func withSpanResolvesTracerFromScopedMultiplex() {
        let tracer = TestTracer()
        let multiplex = MultiplexInstrument([NoOpInstrument(), tracer])

        TaskLocalInstrument.with(multiplex) {
            withSpan("multiplex-op") { _ in }
        }

        #expect(tracer.spans.count == 1)
        #expect(tracer.spans.first?.operationName == "multiplex-op")
    }

    @Test("withSpan finds a Tracer nested three levels deep in MultiplexInstruments")
    func withSpanResolvesTracerFromDeeplyNestedMultiplex() {
        // Pin that MultiplexInstrument.firstInstrument recurses through arbitrary depth.
        let tracer = TestTracer()
        let deepMultiplex = MultiplexInstrument([
            MultiplexInstrument([
                MultiplexInstrument([tracer])
            ])
        ])

        TaskLocalInstrument.with(deepMultiplex) {
            withSpan("deep-op") { _ in }
        }

        #expect(tracer.spans.count == 1)
        #expect(tracer.spans.first?.operationName == "deep-op")
    }

    @Test("withSpan finds a LegacyTracer-only conformer nested inside a MultiplexInstrument inside with(_:_:)")
    func withSpanFindsLegacyOnlyNestedInScopedMultiplex() {
        let legacyOnly = LegacyOnlyTestTracer()
        let scopedMultiplex = MultiplexInstrument([legacyOnly])

        TaskLocalInstrument.with(scopedMultiplex) {
            withSpan("scoped-legacy-op") { _ in }
        }

        #expect(legacyOnly.startedOperationNames == ["scoped-legacy-op"])
    }

    // MARK: - Scoped wins over base bootstrap members

    @Test("Scoped tracer takes precedence over a tracer in the bootstrap's base members")
    func scopedTakesPrecedenceOverBootstrapTracer() {
        let baseTracer = TestTracer()
        let scopedTracer = TestTracer()
        InstrumentationSystem.bootstrapInternal(TaskLocalInstrument(baseTracer))

        TaskLocalInstrument.with(scopedTracer) {
            #expect(InstrumentationSystem.tracer as AnyObject === scopedTracer)
        }

        // Outside the scope, base tracer is reachable again.
        #expect(InstrumentationSystem.tracer as AnyObject === baseTracer)
    }

    @Test("Layering a non-Tracer keeps a base-member Tracer reachable")
    func scopingNonTracerPreservesBootstrapTracer() {
        // Regression test for the silent-NoOp footgun: an application bootstraps a TaskLocalInstrument
        // wrapping a Tracer; a scope adds a pure propagator. Spans must still reach the inner tracer.
        let baseTracer = TestTracer()
        InstrumentationSystem.bootstrapInternal(TaskLocalInstrument(baseTracer))

        TaskLocalInstrument.with(NoOpInstrument()) {
            withSpan("scoped-op") { _ in }
        }

        #expect(baseTracer.spans.count == 1)
        #expect(baseTracer.spans.first?.operationName == "scoped-op")
    }

    // MARK: - Propagation precedence: inner instrument wins for overlapping keys

    @Test("Inner instrument wins ServiceContext writes on extract — scoped runs first")
    func innerExtractWinsForOverlappingKey() {
        let innerWriter = KeyWriterInstrument(value: "inner")
        let scopedWriter = KeyWriterInstrument(value: "scoped")
        InstrumentationSystem.bootstrapInternal(TaskLocalInstrument(innerWriter))

        var context = ServiceContext.topLevel
        let dummy = DummyCarrier()

        // `extract` iterates scoped first, then defers to `inner`. For overlapping `ServiceContext` keys
        // the inner instrument is the last writer and wins.
        TaskLocalInstrument.with(scopedWriter) {
            InstrumentationSystem.instrument.extract(dummy, into: &context, using: KeyWriterExtractor())
        }

        #expect(context[WrittenValueKey.self] == "inner")
    }

    @Test("Inner instrument wins carrier writes on inject — scoped runs first")
    func innerInjectWinsForOverlappingKey() {
        let innerWriter = KeyWriterInstrument(value: "inner")
        let scopedWriter = KeyWriterInstrument(value: "scoped")
        InstrumentationSystem.bootstrapInternal(TaskLocalInstrument(innerWriter))

        var carrier = DummyCarrier()

        // Same forward iteration as extract: scoped first, inner last.
        TaskLocalInstrument.with(scopedWriter) {
            InstrumentationSystem.instrument.inject(
                ServiceContext.topLevel,
                into: &carrier,
                using: KeyWriterInjector()
            )
        }

        #expect(carrier.value == "inner")
    }

    // MARK: - Async

    @Test("with(_:_:) works with async closures")
    func withScopeAsync() async {
        let testTracer = TestTracer()

        await TaskLocalInstrument.with(testTracer) {
            #expect(InstrumentationSystem.tracer is TestTracer)
        }
    }

    @Test("withSpan uses scoped tracer in async context")
    func withSpanAsyncUsesScopedTracer() async {
        let testTracer = TestTracer()

        await TaskLocalInstrument.with(testTracer) {
            await withSpan("async-operation") { span in
                span.attributes["async"] = true
            }
        }

        #expect(testTracer.spans.count == 1)
        #expect(testTracer.spans.first?.operationName == "async-operation")
    }

    // MARK: - Sibling scope isolation

    @Test("Sibling with(_:_:) scopes in the same parent task are isolated")
    func siblingScopesAreIsolated() async {
        let tracer1 = TestTracer()
        let tracer2 = TestTracer()

        async let r1: Void = TaskLocalInstrument.with(tracer1) {
            await Task.yield()
            await withSpan("span-a") { _ in }
        }
        async let r2: Void = TaskLocalInstrument.with(tracer2) {
            await Task.yield()
            await withSpan("span-b") { _ in }
        }
        _ = await (r1, r2)

        #expect(tracer1.spans.count == 1)
        #expect(tracer1.spans.first?.operationName == "span-a")
        #expect(tracer2.spans.count == 1)
        #expect(tracer2.spans.first?.operationName == "span-b")
    }

    // MARK: - Error propagation and typed throws

    @Test("with(_:_:) propagates errors from sync closures")
    func withScopePropagatesSyncErrors() {
        let tracer = TestTracer()

        do {
            try TaskLocalInstrument.with(tracer) {
                throw ExampleSpanError()
            }
            Issue.record("Should have thrown")
        } catch {
            #expect(error is ExampleSpanError)
        }
    }

    @Test("with(_:_:) propagates errors from async closures")
    func withScopePropagatesAsyncErrors() async {
        let tracer = TestTracer()

        do {
            try await TaskLocalInstrument.with(tracer) {
                throw ExampleSpanError()
            }
            Issue.record("Should have thrown")
        } catch {
            #expect(error is ExampleSpanError)
        }
    }

    @Test("with(_:_:) forwards typed throws without hitting the force-cast path")
    func withScopeTypedThrowsRoundTrip() async {
        let tracer = TestTracer()

        // Both the sync and async overloads take a `throws(Failure)` closure. If `withValue` ever forwarded
        // an error whose type was not exactly `Failure`, the internal `throw error as! Failure` would trap.
        func typedThrower() throws(ExampleSpanError) {
            throw ExampleSpanError()
        }

        var caught: ExampleSpanError?
        do {
            try TaskLocalInstrument.with(tracer) { () throws(ExampleSpanError) in
                try typedThrower()
            }
        } catch {
            caught = error
        }
        #expect(caught != nil)

        var caughtAsync: ExampleSpanError?
        do {
            try await TaskLocalInstrument.with(tracer) { () async throws(ExampleSpanError) in
                try typedThrower()
            }
        } catch {
            caughtAsync = error
        }
        #expect(caughtAsync != nil)
    }

    // MARK: - Return value forwarding

    @Test("with(_:_:) returns value from sync closure")
    func withScopeReturnsValueSync() {
        let tracer = TestTracer()

        let result = TaskLocalInstrument.with(tracer) {
            42
        }

        #expect(result == 42)
    }

    @Test("with(_:_:) returns value from async closure")
    func withScopeReturnsValueAsync() async {
        let tracer = TestTracer()

        let result = await TaskLocalInstrument.with(tracer) {
            "async-result"
        }

        #expect(result == "async-result")
    }

    // MARK: - Task propagation

    @Test("Task.detached does not inherit scoped instrument")
    func detachedTaskDoesNotInherit() async {
        let testTracer = TestTracer()

        await TaskLocalInstrument.with(testTracer) {
            #expect(InstrumentationSystem.tracer is TestTracer)

            let resolvedInDetached = await Task.detached {
                InstrumentationSystem.tracer
            }.value

            #expect(resolvedInDetached is NoOpTracer)
        }
    }

    @Test("Unstructured Task inherits scoped instrument")
    func unstructuredTaskInheritsInstrument() async {
        let testTracer = TestTracer()

        let resolved = await TaskLocalInstrument.with(testTracer) {
            await Task {
                InstrumentationSystem.tracer
            }.value
        }

        #expect(resolved is TestTracer)
    }

    @Test("Structured child tasks inherit scoped instrument")
    func structuredChildTasksInheritInstrument() async {
        let testTracer = TestTracer()

        await TaskLocalInstrument.with(testTracer) {
            for i in 0..<3 {
                await withSpan("task-\(i)") { _ in }
            }
        }

        #expect(testTracer.spans.count == 3)
    }
}

// MARK: - Fixtures for propagation precedence tests

/// `ServiceContext` key written by `KeyWriterInstrument` on extract.
private enum WrittenValueKey: ServiceContextKey {
    typealias Value = String
    static var nameOverride: String? { "written-value" }
}

/// Minimal carrier type with a single string slot.
private struct DummyCarrier: Sendable {
    var value: String?
}

/// Instrument that writes a fixed string to ``WrittenValueKey`` on `extract` and to the carrier's `value`
/// slot on `inject`.
private struct KeyWriterInstrument: Instrument {
    let value: String

    func extract<Carrier, Extract>(_ carrier: Carrier, into context: inout ServiceContext, using extractor: Extract)
    where Extract: Extractor, Extract.Carrier == Carrier {
        context[WrittenValueKey.self] = self.value
    }

    func inject<Carrier, Inject>(_ context: ServiceContext, into carrier: inout Carrier, using injector: Inject)
    where Inject: Injector, Inject.Carrier == Carrier {
        injector.inject(self.value, forKey: "written-value", into: &carrier)
    }
}

private struct KeyWriterExtractor: Extractor {
    func extract(key: String, from carrier: DummyCarrier) -> String? {
        carrier.value
    }
}

private struct KeyWriterInjector: Injector {
    func inject(_ value: String, forKey key: String, into carrier: inout DummyCarrier) {
        carrier.value = value
    }
}
