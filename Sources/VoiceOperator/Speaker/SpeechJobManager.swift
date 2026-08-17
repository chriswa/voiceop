import Foundation

/// Sentence-aware, FIFO speech queue used by the local HTTP service and the
/// explicit Speak Clipboard action. Jobs acknowledge only complete sentences.
actor SpeechJobManager {
    static let shared = SpeechJobManager()

    /// The externally-visible lifecycle. It deliberately does not mirror the
    /// sentence player: a job is in progress until it reaches one terminal
    /// state, even while moving between individual sentences.
    enum State: String, Codable { case inProgress = "in_progress", completed, interruptedByUser = "interrupted_by_user", cancelledByClient = "cancelled_by_client", synthesisFailed = "synthesis_failed" }
    enum PlaybackState: String, Codable { case queued, waitingForUser = "waiting_for_user", speaking }
    struct Result: Codable, Sendable, Equatable {
        let id: String
        let state: State
        let playbackState: PlaybackState?
        let characterOffset: Int
        let error: String?
        /// Monotonic per job, bumped on every observable change. A client that
        /// echoes it back as `?since=` gets a change feed instead of a
        /// terminal-only wait; see `wait(id:seconds:since:)`.
        let version: Int
    }
    private struct Segment: Sendable { let text: String; let end: Int }
    private struct Job: Sendable { let id: String; let voice: String; let segments: [Segment]; var next = 0; var state: State = .inProgress; var playbackState: PlaybackState? = .queued; var local = false; var version = 0 }

    private var jobs: [String: Job] = [:]
    private var order: [String] = []
    private var current: String?
    private var dictating = false
    private var muted = false
    private var configured = false
    private var play: (@Sendable (String, String, @escaping @Sendable () -> Void) async -> Bool)?
    private var prefetch: (@Sendable (String, String) -> Void)?
    private var halt: (@Sendable () -> Void)?
    /// A parked `GET ?wait=`. `since == nil` is the original contract — wake
    /// only at a terminal state — and `since == v` widens it to "wake at any
    /// change after version v". Both kinds coexist on one job.
    private struct Waiter { let since: Int?; let continuation: CheckedContinuation<Result, Never> }
    private var waiters: [String: [Waiter]] = [:]

    func configure(play: @escaping @Sendable (String, String, @escaping @Sendable () -> Void) async -> Bool,
                   prefetch: @escaping @Sendable (String, String) -> Void,
                   halt: @escaping @Sendable () -> Void) {
        self.play = play; self.prefetch = prefetch; self.halt = halt; configured = true; pump()
    }

    func enqueue(text: String, voice: String, local: Bool = false) -> Result? {
        guard !muted else { return Result(id: "", state: .cancelledByClient, playbackState: nil, characterOffset: 0, error: "speech_muted", version: 0) }
        let segments = Self.segments(text)
        guard !segments.isEmpty else { return Result(id: "", state: .synthesisFailed, playbackState: nil, characterOffset: 0, error: "empty_text", version: 0) }
        let id = "sp_" + UUID().uuidString.lowercased()
        jobs[id] = Job(id: id, voice: voice, segments: segments, local: local)
        Log.log("speech job \(id): accepted \(text.count) chars as \(segments.count) sentence(s), voice=\(voice)")
        order.append(id); pump()
        return jobs[id].map(result)
    }

    nonisolated func enqueueLocal(text: String) { Task { _ = await self.enqueue(text: text, voice: "af_heart", local: true) } }

    /// Speak Clipboard toggle: stop any active/queued speech, otherwise enqueue
    /// `text` as a local job. Empty text is a no-op when nothing is speaking.
    nonisolated func speakOrStop(text: String) {
        Task {
            if await self.stopSpeaking() {
                Log.log("speak-clipboard: stopped speech that was already playing")
                return
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                Log.log("speak-clipboard: clipboard has no text — nothing to speak")
                return
            }
            guard let result = await self.enqueue(text: trimmed, voice: "af_heart", local: true) else {
                Log.log("speak-clipboard: enqueue returned nothing")
                return
            }
            Log.log("speak-clipboard: enqueued \(result.id) (\(trimmed.count) chars)"
                    + (result.error.map { " — rejected: \($0)" } ?? ""))
        }
    }

    /// Halt the current utterance and cancel anything still queued. Returns
    /// `true` when there was something to stop.
    func stopSpeaking() -> Bool {
        let pending = order.contains { id in
            guard let job = jobs[id] else { return false }
            return !terminal(job.state)
        }
        guard current != nil || pending else { return false }
        interruptCurrent(state: .interruptedByUser)
        for id in order {
            guard let job = jobs[id], !terminal(job.state) else { continue }
            update(id) { $0.state = .interruptedByUser; $0.playbackState = nil }
        }
        order.removeAll()
        return true
    }

    func result(id: String) -> Result? { jobs[id].map(result) }

    /// Long-poll a job.
    ///
    /// Without `since` this returns only at a terminal state (or after
    /// `seconds`), which is the job-level lifecycle this type deliberately
    /// exposes: sentence handoffs are not events a caller has to care about.
    ///
    /// With `since` it returns as soon as the job has moved past that version,
    /// which is the only way to observe `queued` → `speaking` without
    /// spin-polling. The cursor is what makes that race-free: a client that
    /// missed a transition while it was away has `job.version > since` already
    /// true and returns immediately, instead of parking to wait for a change
    /// that has already happened.
    func wait(id: String, seconds: UInt64, since: Int? = nil) async -> Result? {
        guard jobs[id] != nil else { return nil }
        if let ready = settled(id: id, since: since) { return ready }
        return await withTaskGroup(of: Result?.self) { group in
            group.addTask { await self.waitForChange(id: id, since: since) }
            group.addTask { try? await Task.sleep(for: .seconds(Double(seconds))); return nil }
            let first = await group.next()!
            group.cancelAll()
            if let first { return first }
            return self.result(id: id)
        }
    }
    /// The answer a waiter would get without waiting, if there is one.
    private func settled(id: String, since: Int?) -> Result? {
        guard let job = jobs[id] else { return nil }
        if terminal(job.state) { return result(job) }
        if let since, job.version > since { return result(job) }
        return nil
    }
    private func waitForChange(id: String, since: Int?) async -> Result? {
        guard jobs[id] != nil else { return nil }
        if let ready = settled(id: id, since: since) { return ready }
        return await withCheckedContinuation { continuation in
            waiters[id, default: []].append(Waiter(since: since, continuation: continuation))
        }
    }

    func beginDictation() { dictating = true; interruptCurrent(state: .interruptedByUser) }
    func endDictation() { dictating = false; pump() }
    func cancel(id: String) -> Result? {
        guard let job = jobs[id] else { return nil }
        guard !terminal(job.state) else { return result(job) }
        if current == id { interruptCurrent(state: .cancelledByClient) }
        else { update(id) { $0.state = .cancelledByClient; $0.playbackState = nil }; order.removeAll { $0 == id } }
        return jobs[id].map(result)
    }
    func setMuted(_ on: Bool) {
        muted = on
        guard on else { pump(); return }
        interruptCurrent(state: .cancelledByClient)
        for id in order where id != current {
            guard let job = jobs[id], !terminal(job.state) else { continue }
            update(id) { $0.state = .cancelledByClient; $0.playbackState = nil }
        }
        order.removeAll { $0 != current }
    }

    private func pump() {
        guard configured, !dictating, !muted, current == nil, let play else {
            // Waiting behind a dictation, or behind the sentence now playing, is
            // ordinary queueing and says nothing. The states below are the ones
            // that leave a job parked indefinitely, which is indistinguishable
            // from a shortcut that did nothing unless it is said out loud.
            if !order.isEmpty {
                if !configured { Log.log("speech queue: \(order.count) job(s) waiting — playback not configured yet") }
                else if muted { Log.log("speech queue: \(order.count) job(s) waiting — speech is muted") }
                else if play == nil { Log.log("speech queue: \(order.count) job(s) waiting — no playback handler") }
            }
            return
        }
        while let id = order.first {
            guard let job = jobs[id] else { order.removeFirst(); continue }
            if terminal(job.state) { order.removeFirst(); continue }
            guard job.next < job.segments.count else { update(id) { $0.state = .completed; $0.playbackState = nil }; order.removeFirst(); continue }
            current = id
            update(id) { $0.playbackState = .queued }
            let segment = job.segments[job.next]
            // Paired with `startedSentence`'s line below: a "handed to playback"
            // with no "audible" after it localises a stall to synthesis, and is
            // the difference between a silent shortcut and a diagnosable one.
            Log.log("speech job \(id): handing sentence \(job.next + 1)/\(job.segments.count) to playback — \(Log.clip(segment.text))")
            if let prefetch {
                for index in (job.next + 1)..<min(job.segments.count, job.next + 3) {
                    prefetch(job.segments[index].text, job.voice)
                }
            }
            Task { [weak self] in
                let completed = await play(segment.text, job.voice) { [weak self] in
                    Task { await self?.startedSentence(id: id) }
                }
                await self?.finishedSentence(id: id, completed: completed)
            }
            return
        }
    }
    private func startedSentence(id: String) {
        guard current == id, let job = jobs[id], !terminal(job.state) else { return }
        Log.log("speech job \(id): sentence \(job.next + 1)/\(job.segments.count) is audible")
        update(id) { $0.playbackState = .speaking }
    }
    private func finishedSentence(id: String, completed: Bool) {
        guard current == id, let job = jobs[id] else { return }
        current = nil
        if !completed {
            if !terminal(job.state) {
                Log.log("speech queue: \(id) synthesis/playback failed at sentence \(job.next + 1)/\(job.segments.count)")
                update(id) { $0.state = .synthesisFailed; $0.playbackState = nil }; order.removeAll { $0 == id }
            }
            pump(); return
        }
        let next = job.next + 1
        if next == job.segments.count {
            Log.log("speech job \(id): completed all \(job.segments.count) sentence(s)")
            update(id) { $0.next = next; $0.state = .completed; $0.playbackState = nil }
            order.removeAll { $0 == id }
        } else {
            update(id) { $0.next = next; $0.playbackState = dictating ? .waitingForUser : .queued }
            pump()
        }
    }
    private func interruptCurrent(state: State) {
        guard let id = current, let job = jobs[id] else { return }
        Log.log("speech job \(id): \(state.rawValue) at sentence \(job.next + 1)/\(job.segments.count)")
        // Halt the audio before announcing the state, so a client that reacts
        // to the terminal result is never racing sound that is still playing.
        order.removeAll { $0 == id }; current = nil; halt?()
        update(id) { $0.state = state; $0.playbackState = nil }
    }
    private func result(_ job: Job) -> Result {
        let offset = job.next == 0 ? 0 : job.segments[job.next - 1].end
        return Result(id: job.id, state: job.state, playbackState: job.playbackState, characterOffset: offset,
                      error: job.state == .synthesisFailed ? "synthesis_failed" : nil, version: job.version)
    }

    /// The only way a job is written after it is enqueued.
    ///
    /// Stamping the version and waking waiters here rather than at each call
    /// site is the point: a change feed whose producer has to *remember* to
    /// announce each mutation is one mutation away from silently going stale,
    /// and the whole reason this exists is that a client could not otherwise
    /// see `queued` → `speaking` at all.
    private func update(_ id: String, _ change: (inout Job) -> Void) {
        guard var job = jobs[id] else { return }
        let before = result(job)
        change(&job)
        // The version advances only on a change a client could actually see,
        // so `version` means exactly "what you can observe is different" and a
        // cursor poll is never woken by a write that restates the same thing —
        // `pump` re-asserting `queued`, for one.
        guard result(job) != before else { jobs[id] = job; return }
        job.version += 1
        jobs[id] = job
        signal(job)
    }
    private func signal(_ job: Job) {
        guard let parked = waiters[job.id], !parked.isEmpty else { return }
        let done = terminal(job.state)
        var ready: [Waiter] = [], remaining: [Waiter] = []
        for waiter in parked {
            if waiter.since.map({ job.version > $0 }) ?? done { ready.append(waiter) } else { remaining.append(waiter) }
        }
        waiters[job.id] = remaining.isEmpty ? nil : remaining
        let r = result(job)
        ready.forEach { $0.continuation.resume(returning: r) }
    }
    private func terminal(_ s: State) -> Bool { [.completed, .interruptedByUser, .cancelledByClient, .synthesisFailed].contains(s) }

    /// Sentence ranges are based on Foundation's linguistic sentence boundary
    /// detector. Offsets count Unicode scalars in the original input.
    private static func segments(_ text: String) -> [Segment] {
        let ns = text as NSString
        var answer: [Segment] = []
        let tagger = NSLinguisticTagger(tagSchemes: [.tokenType], options: 0)
        tagger.string = text
        tagger.enumerateTags(in: NSRange(location: 0, length: ns.length), unit: .sentence, scheme: .tokenType, options: []) { _, range, _ in
            let part = ns.substring(with: range)
            guard !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let before = ns.substring(to: NSMaxRange(range))
            answer.append(Segment(text: part, end: before.unicodeScalars.count))
        }
        if answer.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { answer.append(Segment(text: text, end: text.unicodeScalars.count)) }
        return answer
    }
}
