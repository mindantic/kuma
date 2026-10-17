import Combine
import XCTest
@testable import KumaCore

final class FakeVoice: VoiceEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Void, Error>?
    private(set) var spokenTexts: [String] = []
    private(set) var startTimes: [Date] = []
    private(set) var stopCount = 0
    var autoFinishAfter: Duration?

    var spoken: [String] { lock.withLock { spokenTexts } }
    var isSpeaking: Bool { lock.withLock { waiting != nil } }

    func speak(_ text: String, voice: String, speed: Double) async throws {
        lock.withLock {
            spokenTexts.append(text)
            startTimes.append(Date())
        }
        if let auto = autoFinishAfter {
            try await Task.sleep(for: auto)
            return
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.withLock { waiting = cont }
        }
    }

    func finishCurrent() {
        let cont = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            let c = waiting
            waiting = nil
            return c
        }
        cont?.resume()
    }

    func stop() {
        let cont = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            stopCount += 1
            let c = waiting
            waiting = nil
            return c
        }
        cont?.resume(throwing: CancellationError())
    }
}

@MainActor
func waitUntil(timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("condition not met in time", file: file, line: line)
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

func briefing(_ text: String, session: String? = nil, _ priority: Priority = .normal) -> Briefing {
    Briefing(sessionId: session ?? text, project: "kuma", tool: .claude, text: text, priority: priority, voice: "am_onyx", speed: 1.0)
}

@MainActor
final class VoiceQueueTests: XCTestCase {
    private var bag = Set<AnyCancellable>()

    private func makeQueue(_ voice: FakeVoice, gap: Duration = .milliseconds(1), max: Int = 30) -> BriefingQueue {
        BriefingQueue(voice: voice, gap: gap, maxPending: max)
    }

    func testFIFOForNormalAndFyi() async {
        let voice = FakeVoice()
        let q = makeQueue(voice)
        q.enqueue(briefing("a"))
        q.enqueue(briefing("b", .fyi))
        q.enqueue(briefing("c"))
        await waitUntil { voice.isSpeaking }
        XCTAssertEqual(q.current?.text, "a")
        XCTAssertEqual(q.pending.map(\.text), ["b", "c"])
        for expected in ["b", "c"] {
            voice.finishCurrent()
            await waitUntil { q.current?.text == expected && voice.isSpeaking }
        }
        voice.finishCurrent()
        await waitUntil { q.isIdle }
        XCTAssertEqual(voice.spoken, ["a", "b", "c"])
    }

    func testHighGoesAheadWithoutInterrupting() async {
        let voice = FakeVoice()
        let q = makeQueue(voice)
        q.enqueue(briefing("n1"))
        await waitUntil { voice.isSpeaking }
        q.enqueue(briefing("n2"))
        q.enqueue(briefing("f1", .fyi))
        q.enqueue(briefing("h1", .high))
        q.enqueue(briefing("h2", .high))
        XCTAssertEqual(q.current?.text, "n1")
        XCTAssertEqual(voice.stopCount, 0)
        XCTAssertEqual(q.pending.map(\.text), ["h1", "h2", "n2", "f1"])
    }

    func testSameSessionMergesKeepingHigherPriorityAndPlace() async {
        let voice = FakeVoice()
        let q = makeQueue(voice)
        q.enqueue(briefing("busy"))
        await waitUntil { voice.isSpeaking }
        q.enqueue(briefing("s1 old", session: "s1", .high))
        q.enqueue(briefing("s2", session: "s2"))
        q.enqueue(briefing("s3", session: "s3"))
        q.enqueue(briefing("s1 new", session: "s1", .fyi))
        XCTAssertEqual(q.pending.map(\.text), ["s1 new", "s2", "s3"])
        XCTAssertEqual(q.pending.first?.priority, .high)

        q.enqueue(briefing("s3 urgent", session: "s3", .high))
        XCTAssertEqual(q.pending.map(\.text), ["s1 new", "s3 urgent", "s2"])
        q.enqueue(briefing("s2 newer", session: "s2", .normal))
        XCTAssertEqual(q.pending.map(\.text), ["s1 new", "s3 urgent", "s2 newer"])
        XCTAssertEqual(q.pending.count, 3)
    }

    func testSameSessionAsCurrentQueuesBehind() async {
        let voice = FakeVoice()
        let q = makeQueue(voice)
        q.enqueue(briefing("one", session: "s"))
        await waitUntil { voice.isSpeaking }
        q.enqueue(briefing("two", session: "s"))
        XCTAssertEqual(q.current?.text, "one")
        XCTAssertEqual(q.pending.map(\.text), ["two"])
    }

    func testSkipCurrentMovesToNext() async {
        let voice = FakeVoice()
        let q = makeQueue(voice)
        var events: [BriefingFinished] = []
        var callback: [(String, Bool)] = []
        q.finished.sink { events.append($0) }.store(in: &bag)
        q.onFinished = { callback.append(($0.text, $1)) }
        q.enqueue(briefing("a"))
        q.enqueue(briefing("b"))
        await waitUntil { voice.isSpeaking }
        q.skipCurrent()
        await waitUntil { q.current?.text == "b" && voice.isSpeaking }
        XCTAssertEqual(events.first?.briefing.text, "a")
        XCTAssertEqual(events.first?.outcome, .skipped)
        XCTAssertEqual(callback.first?.1, true)
        voice.finishCurrent()
        await waitUntil { q.isIdle }
        XCTAssertEqual(events.last?.outcome, .completed)
        XCTAssertEqual(callback.last?.1, false)
    }

    func testClearAllStopsAndEmpties() async {
        let voice = FakeVoice()
        let q = makeQueue(voice)
        var events: [BriefingFinished] = []
        q.finished.sink { events.append($0) }.store(in: &bag)
        q.enqueue(briefing("a"))
        q.enqueue(briefing("b"))
        q.enqueue(briefing("c"))
        await waitUntil { voice.isSpeaking }
        q.clearAll()
        await waitUntil { q.isIdle }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(voice.spoken, ["a"])
        XCTAssertEqual(events.map(\.outcome), [.cleared])
    }

    func testPauseRequeuesAndResumeReplays() async {
        let voice = FakeVoice()
        let q = makeQueue(voice)
        var startedTexts: [String] = []
        q.started.sink { startedTexts.append($0.text) }.store(in: &bag)
        q.enqueue(briefing("a"))
        q.enqueue(briefing("b"))
        await waitUntil { voice.isSpeaking }
        q.pause()
        await waitUntil { q.current == nil }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(q.isPaused)
        XCTAssertEqual(q.pending.map(\.text), ["a", "b"])
        q.enqueue(briefing("c"))
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(q.current)
        q.resume()
        await waitUntil { q.current?.text == "a" && voice.isSpeaking }
        voice.finishCurrent()
        await waitUntil { q.current?.text == "b" && voice.isSpeaking }
        voice.finishCurrent()
        await waitUntil { q.current?.text == "c" && voice.isSpeaking }
        voice.finishCurrent()
        await waitUntil { q.isIdle }
        XCTAssertEqual(startedTexts, ["a", "a", "b", "c"])
    }

    func testRemovePendingBySession() async {
        let voice = FakeVoice()
        let q = makeQueue(voice)
        q.enqueue(briefing("busy"))
        await waitUntil { voice.isSpeaking }
        q.enqueue(briefing("x", session: "muted"))
        q.enqueue(briefing("y", session: "other"))
        q.removePending(sessionId: "muted")
        XCTAssertEqual(q.pending.map(\.text), ["y"])
        XCTAssertEqual(q.current?.text, "busy")
    }

    func testCapacityDropsOldestFyiFirst() async {
        let voice = FakeVoice()
        let q = makeQueue(voice, max: 3)
        q.enqueue(briefing("busy"))
        await waitUntil { voice.isSpeaking }
        q.enqueue(briefing("n1"))
        q.enqueue(briefing("f1", .fyi))
        q.enqueue(briefing("f2", .fyi))
        q.enqueue(briefing("n2"))
        XCTAssertEqual(q.pending.map(\.text), ["n1", "f2", "n2"])
        q.enqueue(briefing("h1", .high))
        XCTAssertEqual(q.pending.map(\.text), ["h1", "n1", "n2"])
        q.enqueue(briefing("h2", .high))
        XCTAssertEqual(q.pending.map(\.text), ["h1", "h2", "n2"])
    }

    func testGapBetweenItems() async {
        let voice = FakeVoice()
        voice.autoFinishAfter = .milliseconds(20)
        let q = makeQueue(voice, gap: .milliseconds(350))
        q.enqueue(briefing("a"))
        q.enqueue(briefing("b"))
        await waitUntil { voice.spoken.count == 2 }
        let times = voice.startTimes
        XCTAssertGreaterThanOrEqual(times[1].timeIntervalSince(times[0]), 0.36)
    }

    func testVoiceErrorReportsFailureAndContinues() async {
        final class Broken: VoiceEngine {
            var calls = 0
            func speak(_ text: String, voice: String, speed: Double) async throws {
                calls += 1
                if text == "bad" { throw KokoroError.timedOut }
            }
            func stop() {}
        }
        let voice = Broken()
        let q = BriefingQueue(voice: voice, gap: .milliseconds(1))
        var events: [BriefingFinished] = []
        q.finished.sink { events.append($0) }.store(in: &bag)
        q.enqueue(briefing("bad"))
        q.enqueue(briefing("good"))
        await waitUntil { events.count == 2 }
        XCTAssertEqual(events.map(\.briefing.text), ["bad", "good"])
        XCTAssertTrue(events[0].wasSkipped)
        if case .failed = events[0].outcome {} else { XCTFail("expected failure") }
        XCTAssertEqual(events[1].outcome, .completed)
    }
}

final class VoiceFallbackTests: XCTestCase {
    final class Failing: VoiceEngine {
        var error: Error
        var calls = 0
        init(_ error: Error) { self.error = error }
        func speak(_ text: String, voice: String, speed: Double) async throws {
            calls += 1
            throw error
        }
        func stop() {}
    }

    func testFallsBackOnError() async throws {
        let primary = Failing(KokoroError.processExited("boom"))
        let backup = FakeVoice()
        backup.autoFinishAfter = .milliseconds(1)
        let voice = FallbackVoice(primary: primary, fallback: backup, isPrimaryReady: { true })
        try await voice.speak("hi", voice: "am_onyx", speed: 1)
        XCTAssertEqual(primary.calls, 1)
        XCTAssertEqual(backup.spoken, ["hi"])
        XCTAssertEqual(voice.lastPrimaryError as? KokoroError, .processExited("boom"))
    }

    func testSkipsPrimaryWhenNotReady() async throws {
        let primary = Failing(KokoroError.timedOut)
        let backup = FakeVoice()
        backup.autoFinishAfter = .milliseconds(1)
        let voice = FallbackVoice(primary: primary, fallback: backup, isPrimaryReady: { false })
        try await voice.speak("hi", voice: "am_onyx", speed: 1)
        XCTAssertEqual(primary.calls, 0)
        XCTAssertEqual(backup.spoken, ["hi"])
    }

    func testCancellationDoesNotFallBack() async {
        let primary = Failing(CancellationError())
        let backup = FakeVoice()
        let voice = FallbackVoice(primary: primary, fallback: backup, isPrimaryReady: { true })
        do {
            try await voice.speak("hi", voice: "am_onyx", speed: 1)
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(backup.spoken, [])
    }

    func testCatalogCoversPreferredVoices() {
        let ids = Set(KokoroVoices.catalog.map(\.id))
        for id in ["am_onyx", "am_michael", "bm_george", "bm_lewis", "bm_daniel", "bm_fable", "af_heart"] {
            XCTAssertTrue(ids.contains(id), id)
        }
        XCTAssertEqual(ids.count, KokoroVoices.catalog.count)
        XCTAssertEqual(KokoroVoices.info(for: "bm_george")?.lang, "en-gb")
        XCTAssertEqual(KokoroVoices.defaultVoice, "am_onyx")
    }

    @MainActor
    func testAudibleWaitsForPlaybackToStart() async throws {
        final class SlowStart: VoiceEngine, @unchecked Sendable {
            func speak(_ text: String, voice: String, speed: Double) async throws {}
            func speak(_ text: String, voice: String, speed: Double, onStart: @escaping @Sendable () -> Void) async throws {
                try await Task.sleep(for: .milliseconds(300))
                onStart()
                try await Task.sleep(for: .milliseconds(300))
            }
            func stop() {}
        }
        let queue = BriefingQueue(voice: SlowStart(), gap: .milliseconds(1))
        queue.enqueue(briefing("a"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(queue.current)
        XCTAssertNil(queue.audible)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(queue.audible?.text, queue.current?.text)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(queue.audible)
    }
}
