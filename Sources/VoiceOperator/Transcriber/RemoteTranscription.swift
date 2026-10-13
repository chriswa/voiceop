import Foundation

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
/// Each session mirrors one local dictation: the provider's live session is
/// opened the moment the session is created (as key-down does), audio is
/// resampled to 16 kHz and handed over as it arrives, and `finish` commits the
/// tail. It shares nothing with `AudioArbiter` but the provider and
/// `TranscriptionLeg`: no paste, no cues, no overlay, no muting, so it runs safely
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

    private let provider: @Sendable () async -> any TranscriptionProvider
    private var sessions: [String: Session] = [:]
    private var reaper: Task<Void, Never>?

    /// `provider` is asked once per session, so a change of provider applies from
    /// the next one.
    init(provider: @escaping @Sendable () async -> any TranscriptionProvider = { TranscriptionProviders.primary }) {
        self.provider = provider
    }

    // MARK: - Session lifecycle

    /// The phone's audio and the transcript it gets back both pass through
    /// Spaceterm, so incognito mode refuses remote dictation outright.
    static let incognitoActivity = Incognito.Activity.spaceterm("phone dictation")

    func create(sampleRate: Int = PCM16Resampler.outputRate, now: Date = Date()) async throws -> String {
        try Incognito.check(Self.incognitoActivity)
        guard let resampler = PCM16Resampler(inputRate: sampleRate) else { throw Failure.unsupportedSampleRate }
        let id = UUID().uuidString.lowercased()
        let trace = DictationTrace("remote")
        trace.note("\(sampleRate) Hz in")
        let leg = TranscriptionLeg(provider: await provider(), target: DictationTarget(), trace: trace,
                                   logPrefix: "remote")
        sessions[id] = Session(id: id, resampler: resampler, leg: leg, now: now)
        updateActivity()
        startReaperIfNeeded()
        return id
    }

    func append(id: String, pcm: Data, now: Date = Date()) throws {
        let session = try openSession(id)
        session.lastActivity = now
        let converted = session.resampler.convert(pcm)
        guard !converted.isEmpty else { return }
        if session.pcm.isEmpty { session.trace.mark("first-audio") }
        session.pcm.append(converted)
        session.leg.append(converted)
    }

    /// Commit the session and wait for its transcript. Falls back to transcribing
    /// the whole clip without streaming if the live session never opened or failed.
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

        // End of stream: drain the resampler.
        let tail = session.resampler.flush()
        session.pcm.append(tail)
        let seconds = Double(session.pcm.count / 2) / Double(PCM16Resampler.outputRate)
        session.trace.note(String(format: "%.1fs audio", seconds))

        guard !session.pcm.isEmpty else {
            session.trace.note("no audio")
            session.leg.cancel()
            return ""
        }

        let clip = WAVFile(sampleRate: PCM16Resampler.outputRate, samples: session.pcm).data
        do {
            let outcome = try await session.leg.finish(tail: tail, openGrace: Self.streamOpenGrace,
                                                       clip: { clip })
            guard session.phase == .finishing else { throw Failure.alreadyFinished }   // cancelled meanwhile
            session.trace.note("\(outcome.text.count) chars")
            return outcome.text
        } catch {
            guard session.phase == .finishing, !(error is CancellationError) else { throw Failure.alreadyFinished }
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
        session.leg.cancel()
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
                session.leg.cancel()
            case .finished:
                sessions[id] = nil
            case .finishing:
                break
            }
        }
        updateActivity()
    }

    // MARK: - Plumbing

    /// Also where a session opened before incognito was turned on stops.
    private func openSession(_ id: String) throws -> Session {
        try Incognito.check(Self.incognitoActivity)
        guard let session = sessions[id] else { throw Failure.unknownSession }
        guard session.phase == .open else { throw Failure.alreadyFinished }
        return session
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

    /// One remote dictation. Confined to the manager actor.
    private final class Session {
        enum Phase { case open, finishing, finished }

        let id: String
        let resampler: PCM16Resampler
        let leg: TranscriptionLeg
        var trace: DictationTrace { leg.trace }
        var phase = Phase.open
        var lastActivity: Date
        /// Every 16 kHz sample received — the fallback transcribes this.
        var pcm = Data()

        init(id: String, resampler: PCM16Resampler, leg: TranscriptionLeg, now: Date) {
            self.id = id
            self.resampler = resampler
            self.leg = leg
            self.lastActivity = now
        }
    }
}
