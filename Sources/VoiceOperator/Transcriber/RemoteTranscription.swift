import Foundation

/// The part of a live transcription stream remote sessions drive. `FlowSession`
/// is the real one; tests substitute a fake.
protocol TranscriptionStream: Sendable {
    func send(packets: [Data]) async
    func commit(packets: [Data], timeout: Duration) async throws -> String
    func cancel() async
}

extension FlowSession: TranscriptionStream {}

/// Where remote sessions get their transcription from. `live` is the same path
/// local dictation takes — `WisprFlowTranscriber`'s streaming session over the
/// shared `FlowChannel`, with the user's dictionary — and the same raw `/llm/asr`
/// fallback when there is no Baseten key or the stream fails.
struct RemoteTranscriptionBackend: Sendable {
    var openStream: @Sendable (DictationTrace) async throws -> any TranscriptionStream
    /// Transcribe a whole 16 kHz WAV clip without streaming (the fallback).
    var transcribeClip: @Sendable (Data) async throws -> String

    static let live: RemoteTranscriptionBackend = {
        let transcriber = WisprFlowTranscriber()
        return RemoteTranscriptionBackend(
            openStream: { trace in
                // Nudge the pooled connection in case it dropped while the Mac slept.
                FlowChannel.shared.warmUp()
                return try await transcriber.openLiveSession(app: FlowAppTarget(), trace: trace)
            },
            transcribeClip: { wav in
                try await transcriber.transcribeWithoutStreaming(wavData: wav, language: "en")
            })
    }()
}

/// How many remote transcriptions are in flight, readable synchronously from the
/// main actor so `RestartCoordinator.isBusy` can count them without awaiting.
final class RemoteTranscriptionActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var idleHandler: (@Sendable () -> Void)?

    var active: Int { lock.lock(); defer { lock.unlock() }; return count }

    /// Called whenever the count falls to zero — the moment a restart that was
    /// waiting on remote work may fire.
    var onIdle: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return idleHandler }
        set { lock.lock(); idleHandler = newValue; lock.unlock() }
    }

    fileprivate func set(_ value: Int) {
        lock.lock()
        let wasActive = count > 0
        count = value
        let handler = wasActive && value == 0 ? idleHandler : nil
        lock.unlock()
        handler?()
    }
}

/// Dictation for clients that cannot run it themselves — the Spaceterm phone
/// client, relayed by the Spaceterm server over the loopback HTTP API.
///
/// Each session mirrors one local dictation: the Flow stream is opened the moment
/// the session is created (as key-down does), audio is resampled to 16 kHz,
/// opus-encoded in whole 20 ms frames and pushed up the stream as it arrives, and
/// `finish` commits the tail. It shares nothing with `AudioArbiter` but the
/// transcriber: no paste, no cues, no overlay, no muting, so it runs safely
/// alongside a local dictation.
actor RemoteTranscriptionManager {
    static let shared = RemoteTranscriptionManager()

    /// Sessions untouched this long are dropped (open ones cancelled).
    static let idleLimit: TimeInterval = 120
    /// How long `finish` waits for a stream still opening, as `AudioArbiter` does.
    static let streamOpenGrace: Duration = .seconds(2)

    enum Failure: Error, Equatable {
        case unknownSession
        case alreadyFinished
        case unsupportedSampleRate
        /// Transcription failed upstream; `unavailable` means signed out (503)
        /// rather than a failed request (502).
        case upstream(message: String, unavailable: Bool)
    }

    nonisolated let activity = RemoteTranscriptionActivity()

    private let backend: RemoteTranscriptionBackend
    private var sessions: [String: Session] = [:]
    private var reaper: Task<Void, Never>?

    init(backend: RemoteTranscriptionBackend = .live) {
        self.backend = backend
    }

    // MARK: - Session lifecycle

    func create(sampleRate: Int = PCM16Resampler.outputRate, now: Date = Date()) throws -> String {
        guard let resampler = PCM16Resampler(inputRate: sampleRate) else { throw Failure.unsupportedSampleRate }
        let id = UUID().uuidString.lowercased()
        let trace = DictationTrace("remote")
        trace.note("\(sampleRate) Hz in")
        let session = Session(id: id, resampler: resampler, encoder: try? OpusEncoder(), trace: trace, now: now)
        if session.encoder == nil { session.broken = true; trace.note("opus encoder unavailable") }
        sessions[id] = session
        updateActivity()
        startReaperIfNeeded()
        if !session.broken {
            let backend = backend
            session.opening = Task { [weak self] in
                do {
                    let stream = try await backend.openStream(trace)
                    await self?.install(stream, in: id)
                } catch {
                    await self?.streamFailed(in: id, error: error)
                }
            }
        }
        return id
    }

    func append(id: String, pcm: Data, now: Date = Date()) throws {
        let session = try openSession(id)
        session.lastActivity = now
        let converted = session.resampler.convert(pcm)
        guard !converted.isEmpty else { return }
        if session.pcm.isEmpty { session.trace.mark("first-audio") }
        session.pcm.append(converted)
        encodeWholeFrames(session)
    }

    /// Commit the session and wait for its transcript. Falls back to transcribing
    /// the whole clip without streaming if the stream never opened or failed.
    func finish(id: String, now: Date = Date()) async throws -> String {
        let session = try openSession(id)
        session.phase = .finishing
        session.lastActivity = now
        session.trace.mark("finish")
        updateActivity()
        defer {
            if session.phase == .finishing { session.phase = .finished }
            session.lastActivity = Date()
            session.trace.flush()
            updateActivity()
        }

        if session.stream == nil, !session.broken, let opening = session.opening {
            if await !Self.wait(for: opening, grace: Self.streamOpenGrace) {
                session.trace.note("stream open timed out")
                session.broken = true
            }
        }
        guard session.phase == .finishing else { throw Failure.alreadyFinished }   // cancelled meanwhile

        // End of stream: drain the resampler and pad the final partial frame.
        session.pcm.append(session.resampler.flush())
        var tail = session.pending
        session.pending = []
        if let encoder = session.encoder, session.encodedOffset < session.pcm.count {
            tail += (try? encoder.encode(pcm: session.pcm.subdata(in: session.encodedOffset ..< session.pcm.count)).packets) ?? []
            session.encodedOffset = session.pcm.count
        }
        let seconds = Double(session.pcm.count / 2) / Double(PCM16Resampler.outputRate)
        session.trace.note(String(format: "%.1fs audio", seconds))

        guard !session.pcm.isEmpty else {
            session.trace.note("no audio")
            await release(session)
            return ""
        }

        if let stream = session.stream, !session.broken {
            _ = await session.sendChain?.value
            do {
                let text = try await stream.commit(packets: tail, timeout: FlowSession.defaultCommitTimeout)
                session.trace.note("\(text.count) chars")
                return text
            } catch {
                guard session.phase == .finishing else { throw Failure.alreadyFinished }
                let reason = TranscriberError.userMessage(for: error)
                Log.log("remote: live stream failed after commit (\(reason)) — re-transcribing the clip")
                session.trace.note("live failed: \(reason)")
            }
        }
        await release(session)
        session.trace.note("fell back to raw /llm/asr")
        do {
            let text = try await backend.transcribeClip(WAVFile(sampleRate: PCM16Resampler.outputRate,
                                                                samples: session.pcm).data)
            session.trace.note("\(text.count) chars")
            return text
        } catch {
            let message = TranscriberError.userMessage(for: error)
            session.trace.note("failed: \(message)")
            let unavailable: Bool
            switch error {
            case TranscriberError.notSignedIn, TranscriberError.signInExpired: unavailable = true
            default: unavailable = false
            }
            throw Failure.upstream(message: message, unavailable: unavailable)
        }
    }

    /// Discard a session, whatever state it is in.
    func cancel(id: String) async throws {
        guard let session = sessions.removeValue(forKey: id) else { throw Failure.unknownSession }
        if session.phase != .finished {
            session.phase = .finished
            session.trace.note("cancelled")
            session.trace.flush()
        }
        await release(session)
        updateActivity()
    }

    /// Cancel open sessions idle past `idleLimit`; forget finished ones. A session
    /// mid-`finish` is left alone — the commit's own hang guard bounds it.
    func reap(now: Date = Date()) async {
        for (id, session) in sessions where now.timeIntervalSince(session.lastActivity) > Self.idleLimit {
            switch session.phase {
            case .open:
                Log.log("remote: reaping session idle for over \(Int(Self.idleLimit))s")
                session.phase = .finished
                session.trace.note("reaped idle")
                session.trace.flush()
                sessions[id] = nil
                await release(session)
            case .finished:
                sessions[id] = nil
            case .finishing:
                break
            }
        }
        updateActivity()
    }

    // MARK: - Plumbing

    private func openSession(_ id: String) throws -> Session {
        guard let session = sessions[id] else { throw Failure.unknownSession }
        guard session.phase == .open else { throw Failure.alreadyFinished }
        return session
    }

    private func install(_ stream: any TranscriptionStream, in id: String) async {
        guard let session = sessions[id], session.phase != .finished, !session.broken else {
            await stream.cancel()
            return
        }
        session.stream = stream
        let pending = session.pending
        session.pending = []
        deliver(pending, to: session)
    }

    private func streamFailed(in id: String, error: Error) {
        guard !Task.isCancelled, let session = sessions[id] else { return }
        let reason = TranscriberError.userMessage(for: error)
        Log.log("remote: live stream unavailable (\(reason)) — will transcribe the clip afterwards")
        session.trace.note("stream open failed: \(reason)")
        session.broken = true
        session.pending = []
    }

    private func encodeWholeFrames(_ session: Session) {
        guard !session.broken, let encoder = session.encoder, session.encodedOffset < session.pcm.count else { return }
        do {
            let slice = session.pcm.subdata(in: session.encodedOffset ..< session.pcm.count)
            let (audio, consumed) = try encoder.encodeWholeFrames(pcm: slice)
            session.encodedOffset += consumed
            deliver(audio.packets, to: session)
        } catch {
            Log.log("remote: opus encode failed: \(error)")
            session.broken = true
        }
    }

    /// Send now if the stream is open, else hold until it is. Sends are chained
    /// so packet order on the wire survives actor reentrancy.
    private func deliver(_ packets: [Data], to session: Session) {
        guard !packets.isEmpty, !session.broken else { return }
        guard let stream = session.stream else { session.pending += packets; return }
        let previous = session.sendChain
        session.sendChain = Task {
            _ = await previous?.value
            await stream.send(packets: packets)
        }
    }

    private func release(_ session: Session) async {
        await session.detach()?.cancel()
    }

    private func updateActivity() {
        activity.set(sessions.values.filter { $0.phase != .finished }.count)
    }

    private func startReaperIfNeeded() {
        guard reaper == nil else { return }
        reaper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await self?.reap()
            }
        }
    }

    /// Whether `task` finished inside `grace`. Cancels it if not.
    private static func wait(for task: Task<Void, Never>, grace: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
                return true
            }
            group.addTask {
                try? await Task.sleep(for: grace)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// One remote dictation. Confined to the manager actor.
    private final class Session {
        enum Phase { case open, finishing, finished }

        let id: String
        let resampler: PCM16Resampler
        let encoder: OpusEncoder?
        let trace: DictationTrace
        var phase = Phase.open
        var lastActivity: Date
        /// Every 16 kHz sample received — the fallback transcribes this.
        var pcm = Data()
        /// How far into `pcm` the encoder has consumed (whole frames only).
        var encodedOffset = 0
        /// Packets encoded before the stream opened.
        var pending: [Data] = []
        var stream: (any TranscriptionStream)?
        var opening: Task<Void, Never>?
        var sendChain: Task<Void, Never>?
        /// The stream is unusable; `finish` goes straight to the fallback.
        var broken = false

        init(id: String, resampler: PCM16Resampler, encoder: OpusEncoder?, trace: DictationTrace, now: Date) {
            self.id = id
            self.resampler = resampler
            self.encoder = encoder
            self.trace = trace
            self.lastActivity = now
        }

        /// Stop using the stream and hand it back for cancelling. Idempotent; a
        /// late-opening stream sees `broken` and cancels itself in `install`.
        func detach() -> (any TranscriptionStream)? {
            broken = true
            opening?.cancel()
            sendChain?.cancel()
            sendChain = nil
            defer { stream = nil }
            return stream
        }
    }
}
