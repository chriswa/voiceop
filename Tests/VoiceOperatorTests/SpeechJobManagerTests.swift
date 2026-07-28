import XCTest
@testable import VoiceOperator

final class SpeechJobManagerTests: XCTestCase {
    func testQueueRejectsMutedRequests() async {
        let manager = SpeechJobManager()
        await manager.setMuted(true)
        let result = await manager.enqueue(text: "Hello.", voice: "af_heart")
        XCTAssertEqual(result?.error, "speech_muted")
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
