import Foundation
import XCTest
@testable import VoiceOperator

final class SpeechJobManagerTests: XCTestCase {
    func testSentenceSessionIdentityAndNextJobHandoff() async {
        let manager = SpeechJobManager()
        let gate = PlaybackGate()
        let requests = PlaybackRequests()
        await manager.configure(
            play: { request, onStart, _ in
                await requests.append(request)
                return await gate.play(onStart: onStart)
            }, prefetch: { _, _ in }, halt: {})
        let first = await manager.enqueue(text: "First sentence. Second sentence.", voice: "af_heart")!
        let second = await manager.enqueue(text: "Another job.", voice: "af_heart")!
        await gate.waitForStarts(1)
        await gate.finishNext()
        await gate.waitForStarts(2)
        await gate.finishNext()
        await gate.waitForStarts(3)
        let seen = await requests.values
        XCTAssertEqual(seen.map(\.jobID), [first.id, first.id, second.id])
        XCTAssertEqual(seen.map(\.isLast), [false, true, true])
        let completed = await manager.result(id: first.id)
        XCTAssertEqual(completed?.state, .completed)
        await gate.finishNext()
    }

    func testQueueRejectsMutedRequests() async {
        let manager = SpeechJobManager()
        await manager.setMuted(true)
        let result = await manager.enqueue(text: "Hello.", voice: "af_heart")
        XCTAssertEqual(result?.error, "speech_muted")
    }

    func testStopSpeakingInterruptsCurrentAndClearsQueue() async {
        let manager = SpeechJobManager()
        let gate = PlaybackGate()
        let halts = Counter()
        await manager.configure(
            play: { _, onStart, _ in await gate.play(onStart: onStart) },
            prefetch: { _, _ in },
            halt: { Task { await halts.increment() } })

        let first = await manager.enqueue(text: "First sentence.", voice: "af_heart")!
        let second = await manager.enqueue(text: "Second sentence.", voice: "af_heart")!
        await gate.waitForStarts(1)
        await gate.startNext()
        try? await Task.sleep(for: .milliseconds(20))

        let stopped = await manager.stopSpeaking()
        XCTAssertTrue(stopped)
        try? await Task.sleep(for: .milliseconds(20))
        let haltCount = await halts.value
        XCTAssertEqual(haltCount, 1)
        let firstState = await manager.result(id: first.id)?.state
        let secondState = await manager.result(id: second.id)?.state
        XCTAssertEqual(firstState, .interruptedByUser)
        XCTAssertEqual(secondState, .interruptedByUser)
        let stoppedAgain = await manager.stopSpeaking()
        XCTAssertFalse(stoppedAgain)
    }

    func testSentenceBoundariesDoNotChangePublicLifecycleOrWakeLongPoll() async {
        let manager = SpeechJobManager()
        let gate = PlaybackGate()
        await manager.configure(
            play: { _, onStart, _ in await gate.play(onStart: onStart) },
            prefetch: { _, _ in },
            halt: {})

        let accepted = await manager.enqueue(text: "First sentence. Second sentence.", voice: "af_heart")!
        XCTAssertEqual(accepted.state, .inProgress)
        await gate.waitForStarts(1)

        let waitingForFirstAudio = await manager.result(id: accepted.id)
        XCTAssertEqual(waitingForFirstAudio?.playbackState, .queued)
        await gate.startNext()
        try? await Task.sleep(for: .milliseconds(20))
        let firstPlayback = await manager.result(id: accepted.id)
        XCTAssertEqual(firstPlayback?.state, .inProgress)
        XCTAssertEqual(firstPlayback?.playbackState, .speaking)

        let longPoll = ResultBox()
        Task { await longPoll.store(await manager.wait(id: accepted.id, seconds: 30)) }
        try? await Task.sleep(for: .milliseconds(20))

        await gate.finishNext()
        await gate.waitForStarts(2)
        let waitingForSecondAudio = await manager.result(id: accepted.id)
        XCTAssertEqual(waitingForSecondAudio?.playbackState, .queued)
        await gate.startNext()
        try? await Task.sleep(for: .milliseconds(20))
        let secondPlayback = await manager.result(id: accepted.id)
        XCTAssertEqual(secondPlayback?.state, .inProgress)
        XCTAssertEqual(secondPlayback?.playbackState, .speaking)
        try? await Task.sleep(for: .milliseconds(20))
        let prematurelyCompleted = await longPoll.current()
        XCTAssertNil(prematurelyCompleted)

        await gate.finishNext()
        let terminal = await longPoll.waitForResult()
        XCTAssertEqual(terminal?.state, .completed)
        XCTAssertNil(terminal?.playbackState)
        XCTAssertEqual(terminal?.characterOffset, "First sentence. Second sentence.".unicodeScalars.count)
    }

    /// The opt-in counterpart of the test above: a client that passes a cursor
    /// wants playback transitions, which a terminal-only wait cannot deliver.
    func testCursorLongPollWakesOnPlaybackTransitions() async {
        let manager = SpeechJobManager()
        let gate = PlaybackGate()
        await manager.configure(
            play: { _, onStart, _ in await gate.play(onStart: onStart) },
            prefetch: { _, _ in },
            halt: {})

        let accepted = await manager.enqueue(text: "First sentence. Second sentence.", voice: "af_heart")!
        await gate.waitForStarts(1)
        let queued = await manager.result(id: accepted.id)!
        XCTAssertEqual(queued.playbackState, .queued)

        let poll = ResultBox()
        Task { await poll.store(await manager.wait(id: accepted.id, seconds: 30, since: queued.version)) }
        try? await Task.sleep(for: .milliseconds(20))
        let beforeAudio = await poll.current()
        XCTAssertNil(beforeAudio, "nothing changed yet, so the poll must still be parked")

        await gate.startNext()
        let speaking = await poll.waitForResult()
        XCTAssertEqual(speaking?.state, .inProgress)
        XCTAssertEqual(speaking?.playbackState, .speaking)
        XCTAssertGreaterThan(speaking!.version, queued.version)
    }

    /// Without this, a client that was away when the job moved would park for
    /// the full wait on a transition that had already happened — which is the
    /// terminal-only behaviour it was trying to escape.
    func testCursorLongPollReturnsImmediatelyForAChangeAlreadyMissed() async {
        let manager = SpeechJobManager()
        let gate = PlaybackGate()
        await manager.configure(
            play: { _, onStart, _ in await gate.play(onStart: onStart) },
            prefetch: { _, _ in },
            halt: {})

        let accepted = await manager.enqueue(text: "First sentence. Second sentence.", voice: "af_heart")!
        await gate.waitForStarts(1)
        let queued = await manager.result(id: accepted.id)!
        await gate.startNext()
        try? await Task.sleep(for: .milliseconds(20))

        // The client only now asks, holding the version from before the change.
        let missed = await manager.wait(id: accepted.id, seconds: 30, since: queued.version)
        XCTAssertEqual(missed?.playbackState, .speaking)
    }

    /// Two clips synthesize at once and no more: the one being played, and one
    /// lookahead. A third would be competing with the sentence the listener is
    /// actually blocked on, at whichever backend they share.
    func testSynthesizesAtMostTwoClipsAtOnce() async {
        let h = await startWindowHarness(sentences: 5)

        // Sentence one synthesizes through `play`; only sentence two is a
        // lookahead, and nothing else has been started.
        await h.assertStarted(["Two."])

        // Settling the lookahead does not buy a third: sentence one still has
        // the other slot, and still has not produced its audio.
        await h.synth.settle("Two.")
        try? await Task.sleep(for: .milliseconds(20))
        await h.assertStarted(["Two."])
    }

    /// The rule that is easy to get wrong. While the sentence being played is
    /// still synthesizing it is the only thing between the listener and sound,
    /// so the window must not spend its free slot looking further ahead — even
    /// though, positionally, it could.
    func testHoldsTheWindowShutWhileTheCurrentSentenceIsStillSynthesizing() async {
        let h = await startWindowHarness(sentences: 5)

        // The backend answers the lookahead first and is still labouring over
        // the sentence being played.
        await h.synth.settle("Two.")
        try? await Task.sleep(for: .milliseconds(20))
        await h.assertStarted(["Two."], "a third clip started while sentence one was still synthesizing")

        // The moment sentence one's audio is in hand, the window opens as far
        // as the budget allows: both free slots go to the next two sentences.
        await h.gate.synthesizeNext()
        await h.synth.waitForStarts(3)
        await h.assertStarted(["Two.", "Three.", "Four."])
    }

    /// A budget rather than a fixed distance. Short sentences settle quickly and
    /// the window walks forward through them, so a long sentence further down
    /// the answer starts while there is still speech left to cover it — instead
    /// of waiting for playback to reach its immediate predecessor.
    func testWalksTheWindowForwardThroughShortSentences() async {
        let h = await startWindowHarness(sentences: 5)

        // Sentence one's audio arrives; sentence two is long and stays in
        // flight for the rest of this test, holding one slot throughout.
        await h.gate.synthesizeNext()
        await h.synth.waitForStarts(2)

        // The other slot now walks: each short sentence settles and frees it.
        await h.synth.settle("Three.")
        await h.synth.waitForStarts(3)
        await h.synth.settle("Four.")
        await h.synth.waitForStarts(4)

        // Sentence five is under way while sentence one is still playing — the
        // whole point. A one-ahead window would not have reached it until
        // playback was on sentence four.
        await h.assertStarted(["Two.", "Three.", "Four.", "Five."])
        let playback = await h.manager.result(id: h.jobId)?.playbackState
        XCTAssertEqual(playback, .queued, "playback should still be on sentence one")
    }

    /// The window has to stop at the end of the answer rather than running off
    /// the end of the segment list.
    func testDoesNotLookPastTheLastSentence() async {
        let h = await startWindowHarness(sentences: 1)
        await h.gate.synthesizeNext()
        try? await Task.sleep(for: .milliseconds(20))

        await h.assertStarted([])
    }
}

/// One job, `sentences` sentences long, with both halves of synthesis under the
/// test's control: `gate` owns the sentence being played (its `onSynthesized`),
/// `synth` owns every lookahead.
private struct WindowHarness {
    let manager: SpeechJobManager
    let gate: PlaybackGate
    let synth: SynthesisGate
    let jobId: String

    /// Awaiting actor state inside an `XCTAssert` autoclosure does not compile,
    /// so every check of what reached the synthesizer goes through here. `line`
    /// keeps a failure reported against the calling test.
    func assertStarted(_ expected: [String], _ message: String = "",
                       file: StaticString = #filePath, line: UInt = #line) async {
        let started = await synth.startedTexts
        XCTAssertEqual(started, expected, message, file: file, line: line)
    }
}

/// Enqueue one job and wait until sentence one has been handed to playback and
/// its lookahead, if any, has actually reached the synthesizer. Both barriers
/// matter: the window is opened synchronously, but starts its requests in
/// detached tasks.
private func startWindowHarness(sentences: Int) async -> WindowHarness {
    let manager = SpeechJobManager()
    let gate = PlaybackGate()
    let synth = SynthesisGate()
    let words = ["One.", "Two.", "Three.", "Four.", "Five."]
    await manager.configure(
        play: { _, onStart, onSynthesized in
            await gate.play(onStart: onStart, onSynthesized: onSynthesized)
        },
        prefetch: { text, _ in await synth.synthesize(text) },
        halt: {})
    let accepted = await manager.enqueue(
        text: words.prefix(sentences).joined(separator: " "), voice: "af_heart")!
    await gate.waitForStarts(1)
    if sentences > 1 { await synth.waitForStarts(1) }
    return WindowHarness(manager: manager, gate: gate, synth: synth, jobId: accepted.id)
}

/// Stands in for the synthesizer behind `prefetch`: records what was asked for,
/// and holds each request open until the test settles it by name.
private actor SynthesisGate {
    private var started: [String] = []
    private var pending: [String: CheckedContinuation<Void, Never>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    /// Sentence segments carry their trailing space; tests name them without.
    private static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func synthesize(_ text: String) async {
        let name = Self.key(text)
        started.append(name)
        let ready = waiters.filter { $0.0 <= started.count }
        waiters.removeAll { $0.0 <= started.count }
        ready.forEach { $0.1.resume() }
        await withCheckedContinuation { pending[name] = $0 }
    }

    var startedTexts: [String] { started }

    func settle(_ name: String) { pending.removeValue(forKey: name)?.resume() }

    func waitForStarts(_ count: Int) async {
        guard started.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor PlaybackRequests {
    private(set) var values: [SpeechJobManager.SentencePlayback] = []
    func append(_ request: SpeechJobManager.SentencePlayback) { values.append(request) }
}

private actor PlaybackGate {
    private var starts = 0
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var completions: [CheckedContinuation<Bool, Never>] = []
    private var onStarts: [@Sendable () -> Void] = []
    private var onSyntheses: [@Sendable () -> Void] = []

    func play(onStart: @escaping @Sendable () -> Void,
              onSynthesized: @escaping @Sendable () -> Void = {}) async -> Bool {
        await withCheckedContinuation { continuation in
            completions.append(continuation)
            onStarts.append(onStart)
            onSyntheses.append(onSynthesized)
            starts += 1
            let ready = startWaiters.filter { $0.0 <= starts }
            startWaiters.removeAll { $0.0 <= starts }
            ready.forEach { $0.1.resume() }
        }
    }

    func startNext() {
        precondition(!onStarts.isEmpty)
        onStarts.removeFirst()()
    }

    /// Report that the sentence now playing has all of its audio — a distinct
    /// moment from `startNext` (sound began) and `finishNext` (sound ended).
    func synthesizeNext() {
        precondition(!onSyntheses.isEmpty)
        onSyntheses.removeFirst()()
    }

    func waitForStarts(_ count: Int) async {
        guard starts < count else { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func finishNext() {
        precondition(!completions.isEmpty)
        completions.removeFirst().resume(returning: true)
    }
}

private actor ResultBox {
    private var result: SpeechJobManager.Result?
    private var waiters: [CheckedContinuation<SpeechJobManager.Result?, Never>] = []

    func store(_ result: SpeechJobManager.Result?) {
        self.result = result
        let waiters = self.waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume(returning: result) }
    }

    func current() -> SpeechJobManager.Result? { result }

    func waitForResult() async -> SpeechJobManager.Result? {
        if let result { return result }
        return await withCheckedContinuation { waiters.append($0) }
    }
}
