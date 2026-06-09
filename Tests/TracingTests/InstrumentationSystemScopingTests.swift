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

// MARK: - InstrumentationSystem.withInstrument scoping tests
//
// `withInstrument(_:_:)` enters a task-local scope that fully replaces the
// bootstrap for the duration of the closure — every read of `InstrumentationSystem.instrument`,
// `InstrumentationSystem.tracer`, and the free-function `withSpan` / `startSpan` overloads resolves to
// the scoped instrument exclusively. The suite's `init` resets the bootstrap to `NoOpInstrument` so
// each test starts from the same baseline.

extension InstrumentationSystemTests {

    // MARK: - Scope resolution

    @Test("InstrumentationSystem.tracer returns scoped tracer entered via withInstrument")
    func tracerReturnsScoped() {
        let testTracer = TestTracer()

        withInstrument(testTracer) {
            #expect(InstrumentationSystem.tracer is TestTracer)
        }
    }

    @Test("Scoped tracer is not visible outside the withInstrument closure")
    func scopedNotVisibleOutsideClosure() {
        let testTracer = TestTracer()

        withInstrument(testTracer) {
            #expect(InstrumentationSystem.tracer is TestTracer)
        }

        // Outside the scope, no scoped tracer is installed. The bootstrap is `NoOpInstrument` (set by
        // the suite's `init`), so discovery returns NoOp.
        #expect(InstrumentationSystem.tracer is NoOpTracer)
    }

    // MARK: - Nesting (innermost replaces outer, no fall-through)

    @Test("Nested withInstrument — innermost tracer fully replaces the outer scope")
    func nestedScopesInnermostReplaces() {
        let outerTracer = TestTracer()
        let innerTracer = TestTracer()

        withInstrument(outerTracer) {
            #expect(InstrumentationSystem.tracer as AnyObject === outerTracer)

            withInstrument(innerTracer) {
                // Innermost scope is the only one in effect.
                #expect(InstrumentationSystem.tracer as AnyObject === innerTracer)
            }

            // Reverts to outer scope on closure exit.
            #expect(InstrumentationSystem.tracer as AnyObject === outerTracer)
        }
    }

    // MARK: - withSpan / startSpan integration

    @Test("withSpan emits into scoped tracer")
    func withSpanUsesScopedTracer() {
        let testTracer = TestTracer()

        withInstrument(testTracer) {
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

        withInstrument(testTracer) {
            let span = startSpan("manual-span")
            span.end()
        }

        #expect(testTracer.spans.count == 1)
        #expect(testTracer.spans.first?.operationName == "manual-span")
    }

    // MARK: - Inner scope fully replaces outer scope
    //
    // In scoped mode (no bootstrap) the application wraps its entry point in an outer
    // ``withInstrument(_:_:)`` and per-test/per-module/per-request callers nest a different instrument.
    // The inner scope must fully replace the outer for both discovery and propagation — there is no
    // fall-through.

    @Test("Inner scope fully replaces the outer scope")
    func innerScopeReplacesOuter() {
        let outerTracer = TestTracer()
        let innerTracer = TestTracer()

        withInstrument(outerTracer) {
            withInstrument(innerTracer) {
                #expect(InstrumentationSystem.tracer as AnyObject === innerTracer)
                withSpan("scoped-op") { _ in }
            }
            // Outside the inner scope, the outer is reachable again.
            #expect(InstrumentationSystem.tracer as AnyObject === outerTracer)
        }
        #expect(innerTracer.spans.count == 1)
        #expect(outerTracer.spans.isEmpty)
    }

    @Test("Inner scope fully replaces a MultiplexInstrument outer scope")
    func innerScopeReplacesMultiplexOuter() {
        // When the outer scope is a `MultiplexInstrument` (e.g. an application that combines several
        // cross-cutting tools as its program-wide default), an inner ``withInstrument(_:_:)`` must
        // shadow it entirely — discovery does not fall through to the multiplex's members.
        let outerTracer = TestTracer()
        let innerTracer = TestTracer()

        withInstrument(MultiplexInstrument([outerTracer])) {
            withInstrument(innerTracer) {
                #expect(InstrumentationSystem.tracer as AnyObject === innerTracer)
                withSpan("scoped-op") { _ in }
            }
            // Outside the inner scope, the multiplex outer is reachable again and discovery recurses
            // into it.
            #expect(InstrumentationSystem.tracer as AnyObject === outerTracer)
        }
        #expect(innerTracer.spans.count == 1)
        #expect(outerTracer.spans.isEmpty)
    }

    // MARK: - Propagation under replace: inner is the only writer

    @Test("Inner scope is the only writer on extract — outer is shadowed")
    func innerExtractShadowsOuter() {
        let outerWriter = KeyWriterInstrument(value: "outer")
        let innerWriter = KeyWriterTracer(value: "inner")

        var context = ServiceContext.topLevel
        let dummy = DummyCarrier()

        // The inner scope fully replaces the outer for inject/extract. The outer's writer never runs,
        // so the inner value is the final one for overlapping `ServiceContext` keys.
        withInstrument(outerWriter) {
            withInstrument(innerWriter) {
                InstrumentationSystem.instrument.extract(dummy, into: &context, using: KeyWriterExtractor())
            }
        }

        #expect(context[WrittenValueKey.self] == "inner")
    }

    @Test("Inner scope is the only writer on inject — outer is shadowed")
    func innerInjectShadowsOuter() {
        let outerWriter = KeyWriterInstrument(value: "outer")
        let innerWriter = KeyWriterTracer(value: "inner")

        var carrier = DummyCarrier()

        withInstrument(outerWriter) {
            withInstrument(innerWriter) {
                InstrumentationSystem.instrument.inject(
                    ServiceContext.topLevel,
                    into: &carrier,
                    using: KeyWriterInjector()
                )
            }
        }

        #expect(carrier.value == "inner")
    }

    // MARK: - Scoping a non-Tracer Instrument (propagator-only)
    //
    // `withInstrument` accepts `any Instrument`, so a propagator-only instrument can be installed as the
    // scope. Inside such a scope `instrument` returns the scoped propagator and propagation routes
    // through it, but `tracer` falls through to `NoOpTracer` because the scoped value doesn't conform to
    // ``Tracer`` — same contract as bootstrapping a propagator-only.

    @Test("withInstrument with a non-Tracer Instrument: tracer is NoOpTracer, propagation works")
    func withInstrumentNonTracerScope() {
        let scopedPropagator = KeyWriterInstrument(value: "propagator-only")

        withInstrument(scopedPropagator) {
            #expect(InstrumentationSystem.instrument is KeyWriterInstrument)
            #expect(InstrumentationSystem.tracer is NoOpTracer)

            var context = ServiceContext.topLevel
            let dummy = DummyCarrier()
            InstrumentationSystem.instrument.extract(dummy, into: &context, using: KeyWriterExtractor())
            #expect(context[WrittenValueKey.self] == "propagator-only")
        }
    }

    @Test("withInstrument can scope a MultiplexInstrument")
    func withInstrumentMultiplexScope() {
        // Scoping a ``MultiplexInstrument`` works: discovery recurses into its members, so a `Tracer`
        // nested in the multiplex remains reachable.
        let nestedTracer = TestTracer()

        withInstrument(MultiplexInstrument([nestedTracer])) {
            withSpan("scoped-multiplex-op") { _ in }
            #expect(InstrumentationSystem.tracer as AnyObject === nestedTracer)
        }

        #expect(nestedTracer.spans.count == 1)
    }

    // MARK: - Bootstrap takes priority over withInstrument
    //
    // ``withInstrument(_:_:)`` is library-safe: a library that calls it internally must not break an
    // application that has bootstrapped. When bootstrap is set, the scope is a silent no-op — reads
    // through ``InstrumentationSystem/instrument`` and the free `withSpan` overloads return the
    // bootstrapped instrument, regardless of what the scope passed to `withInstrument`.

    @Test("withInstrument is a silent no-op when bootstrap is set; spans go to the bootstrap")
    func withInstrumentNoOpUnderBootstrap() {
        let bootstrapped = TestTracer()
        let scoped = TestTracer()
        InstrumentationSystem.bootstrapInternal(bootstrapped)

        withInstrument(scoped) {
            // Inside the would-be scope, reads return the bootstrapped instrument.
            #expect(InstrumentationSystem.tracer as AnyObject === bootstrapped)
            withSpan("op") { _ in }
        }

        #expect(bootstrapped.spans.count == 1)
        #expect(scoped.spans.isEmpty)
    }

    @Test("withInstrument under bootstrap still forwards return value and errors")
    func withInstrumentReturnAndThrowUnderBootstrap() {
        let bootstrapped = TestTracer()
        let scoped = TestTracer()
        InstrumentationSystem.bootstrapInternal(bootstrapped)

        // Return value forwards.
        let result = withInstrument(scoped) { 42 }
        #expect(result == 42)

        // Error forwards (with typed throws).
        do {
            try withInstrument(scoped) { () throws(ExampleSpanError) in throw ExampleSpanError() }
            Issue.record("Should have thrown")
        } catch {
            #expect(error is ExampleSpanError)
        }
    }

    // MARK: - Async

    @Test("withInstrument works with async closures")
    func withScopeAsync() async {
        let testTracer = TestTracer()

        await withInstrument(testTracer) {
            #expect(InstrumentationSystem.tracer is TestTracer)
        }
    }

    @Test("withSpan uses scoped tracer in async context")
    func withSpanAsyncUsesScopedTracer() async {
        let testTracer = TestTracer()

        await withInstrument(testTracer) {
            await withSpan("async-operation") { span in
                span.attributes["async"] = true
            }
        }

        #expect(testTracer.spans.count == 1)
        #expect(testTracer.spans.first?.operationName == "async-operation")
    }

    // MARK: - Sibling scope isolation

    @Test("Sibling withInstrument scopes in the same parent task are isolated")
    func siblingScopesAreIsolated() async {
        let tracer1 = TestTracer()
        let tracer2 = TestTracer()

        async let r1: Void = withInstrument(tracer1) {
            await Task.yield()
            await withSpan("span-a") { _ in }
        }
        async let r2: Void = withInstrument(tracer2) {
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

    @Test("withInstrument propagates errors from sync closures")
    func withScopePropagatesSyncErrors() {
        let tracer = TestTracer()

        do {
            try withInstrument(tracer) {
                throw ExampleSpanError()
            }
            Issue.record("Should have thrown")
        } catch {
            #expect(error is ExampleSpanError)
        }
    }

    @Test("withInstrument propagates errors from async closures")
    func withScopePropagatesAsyncErrors() async {
        let tracer = TestTracer()

        do {
            try await withInstrument(tracer) {
                throw ExampleSpanError()
            }
            Issue.record("Should have thrown")
        } catch {
            #expect(error is ExampleSpanError)
        }
    }

    @Test("withInstrument forwards typed throws without hitting the unreachable fatal-error path")
    func withScopeTypedThrowsRoundTrip() async {
        let tracer = TestTracer()

        // Both the sync and async overloads take a `throws(Failure)` closure. If `withValue` ever
        // forwarded an error whose type was not exactly `Failure`, the internal `fatalError` would trap;
        // because `TaskLocal.withValue` is `rethrows`, only the closure's errors flow out, so the first
        // catch clause matches and the fatal-error branch is unreachable.
        func typedThrower() throws(ExampleSpanError) {
            throw ExampleSpanError()
        }

        var caught: ExampleSpanError?
        do {
            try withInstrument(tracer) { () throws(ExampleSpanError) in
                try typedThrower()
            }
        } catch {
            caught = error
        }
        #expect(caught != nil)

        var caughtAsync: ExampleSpanError?
        do {
            try await withInstrument(tracer) { () async throws(ExampleSpanError) in
                try typedThrower()
            }
        } catch {
            caughtAsync = error
        }
        #expect(caughtAsync != nil)
    }

    @Test("Nested withInstrument with different Failure types each propagate their own typed errors")
    func nestedScopesWithDifferentFailureTypes() {
        // Pins that each `withInstrument` frame's `as Failure` resolves to its own static type, not an erased
        // one — if a regression caused `as Failure` to collapse, the inner ErrB would trap on the outer's
        // ErrA cast.
        struct ErrA: Error {}
        struct ErrB: Error {}
        let outerTracer = TestTracer()
        let innerTracer = TestTracer()

        var innerHandled = false
        var outerHandled = false
        do {
            try withInstrument(outerTracer) { () throws(ErrA) in
                do {
                    try withInstrument(innerTracer) { () throws(ErrB) in
                        throw ErrB()
                    }
                } catch {
                    #expect(error is ErrB)
                    innerHandled = true
                }
                throw ErrA()
            }
        } catch {
            #expect(error is ErrA)
            outerHandled = true
        }
        #expect(innerHandled)
        #expect(outerHandled)
    }

    // MARK: - Return value forwarding

    @Test("withInstrument returns value from sync closure")
    func withScopeReturnsValueSync() {
        let tracer = TestTracer()

        let result = withInstrument(tracer) {
            42
        }

        #expect(result == 42)
    }

    @Test("withInstrument returns value from async closure")
    func withScopeReturnsValueAsync() async {
        let tracer = TestTracer()

        let result = await withInstrument(tracer) {
            "async-result"
        }

        #expect(result == "async-result")
    }

    // MARK: - Task propagation

    @Test("Task.detached does not inherit scoped tracer")
    func detachedTaskDoesNotInherit() async {
        let testTracer = TestTracer()

        await withInstrument(testTracer) {
            #expect(InstrumentationSystem.tracer is TestTracer)

            let resolvedInDetached = await Task.detached {
                InstrumentationSystem.tracer
            }.value

            #expect(resolvedInDetached is NoOpTracer)
        }
    }

    @Test("Unstructured Task inherits scoped tracer")
    func unstructuredTaskInheritsInstrument() async {
        let testTracer = TestTracer()

        let resolved = await withInstrument(testTracer) {
            await Task {
                InstrumentationSystem.tracer
            }.value
        }

        #expect(resolved is TestTracer)
    }

    @Test("Structured child tasks inherit scoped tracer")
    func structuredChildTasksInheritInstrument() async {
        let testTracer = TestTracer()

        await withInstrument(testTracer) {
            for i in 0..<3 {
                await withSpan("task-\(i)") { _ in }
            }
        }

        #expect(testTracer.spans.count == 3)
    }

    @Test("withTaskGroup child tasks inherit scoped tracer")
    func taskGroupChildrenInheritInstrument() async {
        let testTracer = TestTracer()

        await withInstrument(testTracer) {
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<3 {
                    group.addTask {
                        await withSpan("group-task-\(i)") { _ in }
                    }
                }
            }
        }

        #expect(testTracer.spans.count == 3)
    }

    // MARK: - Span escape across scope boundaries
    //
    // Pins the documented split-hierarchy behavior: a span that survives an inner scope, child spans
    // started via the free functions after the inner scope exits, and tasks created before the inner
    // scope is entered all resolve through whatever tracer is in scope at the call site — not the
    // inner scope's tracer. These tests exist so a future refactor that accidentally introduces layered
    // or sticky semantics fails loudly.

    @Test("Span survives inner scope; child via free function after inner exit goes to outer")
    func childSpanAfterInnerScopeExitResolvesToOuter() {
        let outer = TestTracer()
        let inner = TestTracer()

        var escapedSpan: (any Span)?
        withInstrument(outer) {
            withInstrument(inner) {
                escapedSpan = startSpan("escaped-parent")
            }
            // Inside the outer scope but after the inner exited.
            withSpan("child-after-inner-exit") { _ in }
        }
        escapedSpan?.end()

        #expect(inner.spans.count == 1)
        #expect(inner.spans.first?.operationName == "escaped-parent")
        #expect(outer.spans.count == 1)
        #expect(outer.spans.first?.operationName == "child-after-inner-exit")
    }

    @Test("Task created before inner scope captures the outer tracer, not the later-entered inner")
    func taskCreatedBeforeInnerScopeCapturesOuter() async {
        let outer = TestTracer()
        let inner = TestTracer()

        await withInstrument(outer) {
            // Pre-existing task held on a continuation it'll receive from inside the inner scope. The
            // task was created in the outer scope only, so it captured the outer task-local at
            // creation. Resuming it from inside the inner scope does not retroactively rebind its
            // task-locals.
            let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
            let outsideTask = Task<Bool, Never> {
                for await _ in stream { break }
                return InstrumentationSystem.tracer as AnyObject === outer
            }

            await withInstrument(inner) {
                continuation.yield(())
                continuation.finish()
            }

            let outsideSawOuter = await outsideTask.value
            #expect(outsideSawOuter)
        }
    }

    @Test("Continuation resumed by an outer-scope task starts child spans against the outer tracer")
    func childSpanStartedOnOuterScopeTaskGoesToOuter() async {
        let outer = TestTracer()
        let inner = TestTracer()

        await withInstrument(outer) {
            // A task created in the outer scope receives a signal from inside the inner scope and
            // starts its span *there*. The span is emitted through the outer tracer because that
            // task's captured task-local state is the one in effect at its creation site.
            let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
            let outsideTask = Task<Void, Never> {
                for await _ in stream { break }
                await withSpan("started-from-outer") { _ in }
            }

            await withInstrument(inner) {
                continuation.yield(())
                continuation.finish()
            }
            await outsideTask.value
        }

        #expect(inner.spans.isEmpty)
        #expect(outer.spans.count == 1)
        #expect(outer.spans.first?.operationName == "started-from-outer")
    }
}

// MARK: - Fixtures for propagation tests

/// `ServiceContext` key written by `KeyWriterInstrument` / `KeyWriterTracer` on extract.
private enum WrittenValueKey: ServiceContextKey {
    typealias Value = String
    static var nameOverride: String? { "written-value" }
}

/// Minimal carrier type with a single string slot.
private struct DummyCarrier: Sendable {
    var value: String?
}

/// Instrument that writes a fixed string to ``WrittenValueKey`` on `extract` and to the carrier's `value`
/// slot on `inject`. Used to represent a bootstrapped instrument in propagation tests.
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

/// Tracer that writes a fixed string to ``WrittenValueKey`` on `extract` and to the carrier's `value`
/// slot on `inject`. Used to represent a scoped tracer in propagation tests; spans go to a no-op span
/// because the tests only inspect propagation, not span recording.
private struct KeyWriterTracer: Tracer {
    let value: String

    func startSpan<Instant: TracerInstant>(
        _ operationName: String,
        context: @autoclosure () -> ServiceContext,
        ofKind kind: SpanKind,
        at instant: @autoclosure () -> Instant,
        function: String,
        file fileID: String,
        line: UInt
    ) -> NoOpTracer.NoOpSpan {
        NoOpTracer.NoOpSpan(context: context())
    }

    func forceFlush() {}

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
