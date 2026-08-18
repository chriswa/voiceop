import Foundation
import XCTest
@testable import VoiceOperator

final class SpeechJobManagerTests: XCTestCase {
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
            play: { _, _, onStart in await gate.play(onStart: onStart) },
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
            play: { _, _, onStart in await gate.play(onStart: onStart) },
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
            play: { _, _, onStart in await gate.play(onStart: onStart) },
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
            play: { _, _, onStart in await gate.play(onStart: onStart) },
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

    /// The prefetch window is the whole reason a queued answer can be slower
    /// than a single sentence: every clip in flight competes for the same
    /// synthesizer. Pinning it at one lookahead keeps the concurrency at two
    /// and, more importantly, keeps the *current* sentence from being the one
    /// that loses the race it is blocking on.
    func testPrefetchesOnlyOneSentenceAhead() async {
        let manager = SpeechJobManager()
        let gate = PlaybackGate()
        let prefetched = Recorder()
        await manager.configure(
            play: { _, _, onStart in await gate.play(onStart: onStart) },
            prefetch: { text, _ in prefetched.record(text) },
            halt: {})

        _ = await manager.enqueue(
            text: "First sentence. Second sentence. Third sentence. Fourth sentence.",
            voice: "af_heart")!
        // `pump` prefetches before it hands the sentence to `play`, so a started
        // playback is a precise barrier: whatever this window was going to
        // request, it has requested by now.
        await gate.waitForStarts(1)

        // Sentence one is playing, so only sentence two may be in flight.
        XCTAssertEqual(prefetched.all.map(Self.trimmed), ["Second sentence."])

        await gate.startNext()
        await gate.finishNext()
        await gate.waitForStarts(2)

        // Sentence two is playing, so the window has advanced onto sentence
        // three — rather than having opened onto three *and* four at the start.
        XCTAssertEqual(prefetched.all.map(Self.trimmed), ["Second sentence.", "Third sentence."])
    }

    /// The lookahead has to stop at the end of the answer rather than running
    /// off the end of the segment list.
    func testDoesNotPrefetchPastTheLastSentence() async {
        let manager = SpeechJobManager()
        let gate = PlaybackGate()
        let prefetched = Recorder()
        await manager.configure(
            play: { _, _, onStart in await gate.play(onStart: onStart) },
            prefetch: { text, _ in prefetched.record(text) },
            halt: {})

        _ = await manager.enqueue(text: "Only sentence.", voice: "af_heart")!
        await gate.waitForStarts(1)

        XCTAssertEqual(prefetched.all, [])
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Records the texts `prefetch` was called with.
///
/// Lock-guarded rather than an actor because `prefetch` is a synchronous
/// `@Sendable` closure: recording on the caller's thread is what lets a started
/// playback stand in as a barrier, instead of the test sleeping and hoping.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    func record(_ text: String) { lock.lock(); texts.append(text); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return texts }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor PlaybackGate {
    private var starts = 0
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var completions: [CheckedContinuation<Bool, Never>] = []
    private var onStarts: [@Sendable () -> Void] = []

    func play(onStart: @escaping @Sendable () -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            completions.append(continuation)
            onStarts.append(onStart)
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
