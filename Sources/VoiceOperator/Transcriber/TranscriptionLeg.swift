import Foundation

/// One provider's share of one dictation: its live session, opened the moment the
/// dictation starts, the audio that arrives before that session is ready, and the
/// decision at the end between the session's answer and the provider's fallback.
///
/// `AudioArbiter` (local dictation) and `RemoteTranscriptionManager` (the phone)
/// both drive dictation through this, and a dictation with a shadow provider is
/// simply two legs fed the same audio.
///
/// Audio is taken synchronously (`append`) from whichever thread captured it and
/// sent in order: sends are chained rather than fired concurrently, because packet
/// order is load-bearing and two tasks racing into the session could reorder them.
final class TranscriptionLeg: @unchecked Sendable {
    struct Outcome: Sendable {
        let text: String
        /// Why the live session is not what produced `text` — nil when it is. The
        /// arbiter turns this into `StreamHealth`.
        let liveFailure: String?
    }

    let provider: any TranscriptionProvider
    let trace: DictationTrace
    private let logPrefix: String
    private let onOpenFailed: @Sendable (String) -> Void

    private let lock = NSLock()
    private var session: (any TranscriptionSession)?
    /// Audio captured before the session finished opening.
    private var pending = Data()
    private var sendChain: Task<Void, Never>?
    private var opening: Task<Void, Never>?
    /// Set when the live session is unusable, so we stop feeding it and fall back
    /// once the user finishes.
    private var failure: String?
    /// Set once this leg is definitively over and its session should be thrown
    /// away. Also stops a late-arriving open from installing a session nobody
    /// will use.
    private var abandoned = false

    /// Starts opening the provider's session at once — concurrently with the
    /// microphone, so by the time the first audio arrives it is usually ready.
    /// `onOpenFailed` hears about a session that could not open as soon as that is
    /// known, rather than at the end of the dictation.
    init(provider: any TranscriptionProvider, target: DictationTarget, trace: DictationTrace,
         logPrefix: String = "dictation", onOpenFailed: @escaping @Sendable (String) -> Void = { _ in }) {
        self.provider = provider
        self.trace = trace
        self.logPrefix = logPrefix
        self.onOpenFailed = onOpenFailed
        let task = Task { [weak self] in
            do {
                let session = try await provider.openSession(target: target, trace: trace)
                guard let self, self.install(session) else {
                    await session.cancel()
                    return
                }
            } catch {
                // We cancelled it ourselves (grace expired, or the dictation was
                // abandoned) — that path already said so, and `CancellationError`
                // renders as noise. Don't report it twice under a different name.
                guard !Task.isCancelled, let self else { return }
                self.openFailed(TranscriberError.userMessage(for: error))
            }
        }
        lock.withLock { opening = task }
    }

    /// True once the live session is known to be unusable — the dictation will go
    /// the long way round.
    var isBroken: Bool { lock.withLock { failure != nil } }

    /// Newly captured audio, in capture order.
    func append(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        lock.withLock {
            guard !abandoned, failure == nil else { return }
            guard let session else { pending.append(pcm); return }
            chainSend(pcm, to: session)
        }
    }

    /// The audio has ended. Waits up to `openGrace` for a session still opening,
    /// commits `tail`, and if the live session is unusable or fails, transcribes
    /// `clip` (the whole recording as WAV) through the provider's fallback.
    ///
    /// Throws `CancellationError` if the leg was cancelled while committing,
    /// rather than spending a fallback on a dictation nobody wants.
    func finish(tail: Data, openGrace: Duration, clip: @escaping @Sendable () throws -> Data) async throws -> Outcome {
        // The lock is only ever taken in the synchronous helpers below, never in
        // a closure inside this async function: swiftc 6.3 hangs in its
        // closure-lifetime pass on `withLock` closures spread across the awaits.
        if let opening = openingStillPending(), await !Self.wait(for: opening, grace: openGrace) {
            Log.log("\(logPrefix): stream still opening \(openGrace) after key-up — using the recorded clip")
            trace.note("stream open timed out")
            markFailed("stream did not open in time")
        }

        let ready = takeForCommit()
        var liveFailure = ready.failure
        if let session = ready.session, ready.failure == nil {
            _ = await ready.chain?.value   // preserve ordering ahead of the commit
            do {
                let text = try await session.commit(pcm: ready.unsent + tail)
                releaseCommitted()
                return Outcome(text: text, liveFailure: nil)
            } catch {
                if isAbandoned { throw CancellationError() }
                guard provider.retriesAfterLiveFailure else {
                    releaseCommitted()
                    throw error
                }
                let reason = TranscriberError.userMessage(for: error)
                Log.log("\(logPrefix): live stream failed after commit (\(reason)) — re-transcribing the recorded clip")
                trace.note("live failed: \(reason)")
                liveFailure = reason
            }
        }
        // Whatever went wrong, this session is done: release it rather than
        // leaving it and its tasks alive.
        cancel()
        trace.note("fell back to \(provider.fallbackLabel)")
        let text = try await provider.transcribeAfterLiveFailure(wavData: try clip())
        return Outcome(text: text, liveFailure: liveFailure ?? "stream unavailable")
    }

    /// Abandon the leg. Idempotent, and safe whether or not the session ever opened.
    func cancel() {
        let session: (any TranscriptionSession)? = lock.withLock {
            abandoned = true
            sendChain?.cancel()
            sendChain = nil
            opening?.cancel()
            defer { self.session = nil }
            return self.session
        }
        if let session { Task { await session.cancel() } }
    }

    // MARK: - Plumbing

    private struct ReadyToCommit {
        let session: (any TranscriptionSession)?
        let chain: Task<Void, Never>?
        let unsent: Data
        let failure: String?
    }

    /// The open still in flight, if the session is neither ready nor failed.
    private func openingStillPending() -> Task<Void, Never>? {
        lock.withLock { session == nil && failure == nil ? opening : nil }
    }

    private func markFailed(_ reason: String) {
        lock.withLock { if failure == nil { failure = reason } }
    }

    private func takeForCommit() -> ReadyToCommit {
        lock.withLock {
            let ready = ReadyToCommit(session: session, chain: sendChain, unsent: pending, failure: failure)
            pending = Data()
            return ready
        }
    }

    private func releaseCommitted() {
        lock.withLock { session = nil; sendChain = nil }
    }

    private var isAbandoned: Bool { lock.withLock { abandoned } }

    /// Returns false if the leg no longer wants a session.
    private func install(_ session: any TranscriptionSession) -> Bool {
        lock.withLock {
            guard !abandoned, failure == nil else { return false }
            self.session = session
            if !pending.isEmpty {
                chainSend(pending, to: session)
                pending = Data()
            }
            return true
        }
    }

    private func openFailed(_ reason: String) {
        let report = lock.withLock { () -> Bool in
            guard !abandoned, failure == nil else { return false }
            failure = reason
            pending = Data()
            return true
        }
        guard report else { return }
        Log.log("\(logPrefix): live stream unavailable (\(reason)) — will transcribe the clip afterwards")
        trace.note("stream open failed: \(reason)")
        onOpenFailed(reason)
    }

    /// Caller holds `lock`.
    private func chainSend(_ pcm: Data, to session: any TranscriptionSession) {
        let previous = sendChain
        sendChain = Task {
            _ = await previous?.value
            await session.send(pcm: pcm)
        }
    }

    /// Whether `task` finished inside `grace`. Cancels it if not.
    ///
    /// A race on a continuation rather than a task group: a group drains its
    /// children before returning, so an open that ignores cancellation (a stalled
    /// token fetch) would hold the "grace period" open for as long as it liked.
    /// Here the losing waiter is simply left behind.
    static func wait(for task: Task<Void, Never>, grace: Duration) async -> Bool {
        let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            Task { await task.value; once.resume(true) }
            Task { try? await Task.sleep(for: grace); once.resume(false) }
        }
        if !finished { task.cancel() }
        return finished
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func resume(_ value: Bool) {
            lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                defer { continuation = nil }
                return continuation
            }?.resume(returning: value)
        }
    }
}
