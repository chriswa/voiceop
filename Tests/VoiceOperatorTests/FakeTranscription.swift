import Foundation
@testable import VoiceOperator

/// A provider whose live session and whole-clip transcription the test scripts.
struct FakeProvider: TranscriptionProvider {
    let id = TranscriptionProviderID.parakeet
    var session: FakeSession?
    var openError: Error?
    /// Holds the open until the test releases it, when set.
    var openGate: Gate?
    var fallback: @Sendable (Data) async throws -> String = { _ in "fallback" }

    init(session: FakeSession? = nil, openError: Error? = nil, openGate: Gate? = nil,
         fallback: @escaping @Sendable (Data) async throws -> String = { _ in "fallback" }) {
        self.session = session
        self.openError = openError
        self.openGate = openGate
        self.fallback = fallback
    }

    func openSession(target: DictationTarget, trace: DictationTrace?) async throws -> any TranscriptionSession {
        if let openGate { await openGate.wait() }
        if let openError { throw openError }
        return session ?? FakeSession(result: .success(""))
    }
    func transcribe(wavData: Data) async throws -> Transcript { Transcript(text: try await fallback(wavData)) }
    func prewarm() async -> String? { nil }
}

/// Records every byte it is sent, in order, and answers the commit with `result`.
actor FakeSession: TranscriptionSession {
    private let result: Result<String, Error>
    private let words: [TranscribedWord]?
    private(set) var received = Data()
    private var sent = 0
    private var committed = 0
    private(set) var cancelled = false
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []

    init(result: Result<String, Error>, words: [TranscribedWord]? = nil) { self.result = result; self.words = words }

    var byteCounts: (sent: Int, committed: Int) { (sent, committed) }

    func send(pcm: Data) {
        sent += pcm.count
        received.append(pcm)
    }
    func commit(pcm: Data) throws -> Transcript {
        committed = pcm.count
        received.append(pcm)
        return Transcript(text: try result.get(), words: words)
    }
    func cancel() {
        cancelled = true
        cancelWaiters.forEach { $0.resume() }
        cancelWaiters = []
    }
    func waitUntilCancelled() async {
        guard !cancelled else { return }
        await withCheckedContinuation { cancelWaiters.append($0) }
    }
}

/// A failure for the fakes to throw, shown as its `message`.
struct FakeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A one-shot latch: `wait` suspends until `open`.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
