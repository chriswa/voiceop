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
    struct SentencePlayback: Sendable {
        let jobID: String
        let text: String
        let voice: String
        let isLast: Bool
    }
    private struct Job: Sendable { let id: String; let voice: String; let segments: [Segment]; var next = 0; var state: State = .inProgress; var playbackState: PlaybackState? = .queued; var local = false; var version = 0 }

    private var jobs: [String: Job] = [:]
    private var order: [String] = []
    private var current: String?
    private var dictating = false
    private var muted = false
    private var configured = false
    /// `(sentence, onStart, onSynthesized) -> finishedNaturally`. Closure
    /// types cannot carry argument labels, so the two callbacks are positional:
    /// `onStart` is the first audible sample, `onSynthesized` is the clip's
    /// audio being fully in hand. See `fillSynthesisWindow` for why the second
    /// one is a scheduling input rather than just a log line.
    private var play: (@Sendable (SentencePlayback, @escaping @Sendable () -> Void, @escaping @Sendable () -> Void) async -> Bool)?
    /// Synthesize a clip without playing it, returning when it has settled.
    private var prefetch: (@Sendable (String, String) async -> Void)?
    private var halt: (@Sendable () -> Void)?
    /// Fires `true` when speech becomes active (a sentence is handed to
    /// playback) and `false` when the queue goes idle (the whole job finished or
    /// was interrupted). Drives the word overlay's visibility so it appears at
    /// synthesis start and persists across a job's sentences. `current != nil`
    /// is the signal: it is set before audio and stays set across the
    /// between-sentence gap (reset synchronously by `pump`), going nil only at a
    /// true finish/interrupt.
    private var onSpeechActivity: (@Sendable (Bool) -> Void)?
    private var speechActive = false

    /// How many clips may be synthesizing at once, across the whole queue.
    ///
    /// Synthesis is a shared, finite resource whatever the backend — a local
    /// model behind a small worker pool, or a remote service with a queue of
    /// its own — so this is the number that decides how much the lookahead
    /// competes with the sentence the listener is actually blocked on.
    private static let maxConcurrentSyntheses = 2

    /// Segment indices of `synthesisJob` whose synthesis has started and has
    /// not settled.
    private var synthesizing: Set<Int> = []
    /// The lowest segment index of `synthesisJob` whose synthesis has not been
    /// started. Everything below it has started; everything below it and absent
    /// from `synthesizing` has finished.
    private var synthesisFrontier = 0
    /// The job the two fields above describe. Late callbacks from a job that
    /// has been superseded are ignored rather than corrupting its successor's
    /// bookkeeping — synthesis outlives the job that asked for it, deliberately,
    /// so the clip still lands in cache.
    ///
    /// Which means the cap is per job, not global: for the moment either side
    /// of a barge-in, an interrupted job's clips can still be synthesizing
    /// while its replacement opens its own window. Accepted rather than
    /// overlooked. Counting across jobs would mean holding the new answer's
    /// first sentence behind audio nobody is going to hear, which is the wrong
    /// trade for a window that closes on its own within one clip.
    private var synthesisJob: String?
    /// A parked `GET ?wait=`. `since == nil` is the original contract — wake
    /// only at a terminal state — and `since == v` widens it to "wake at any
    /// change after version v". Both kinds coexist on one job.
    private struct Waiter { let since: Int?; let continuation: CheckedContinuation<Result, Never> }
    private var waiters: [String: [Waiter]] = [:]

    func configure(play: @escaping @Sendable (SentencePlayback, @escaping @Sendable () -> Void, @escaping @Sendable () -> Void) async -> Bool,
                   prefetch: @escaping @Sendable (String, String) async -> Void,
                   halt: @escaping @Sendable () -> Void,
                   onSpeechActivity: @escaping @Sendable (Bool) -> Void = { _ in }) {
        self.play = play; self.prefetch = prefetch; self.halt = halt
        self.onSpeechActivity = onSpeechActivity
        configured = true; pump()
    }

    /// Emit an active/idle transition when `current` crosses between nil and set.
    /// Called from a `defer` in every method that can change `current`, so it
    /// observes the settled value at method exit — never the transient nil that
    /// `finishedSentence`→`pump` passes through between a job's sentences.
    private func refreshActivity() {
        let active = current != nil
        guard active != speechActive else { return }
        speechActive = active
        onSpeechActivity?(active)
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
        defer { refreshActivity() }
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
            let index = job.next
            let segment = job.segments[index]
            // Paired with `startedSentence`'s line below: a "handed to playback"
            // with no "audible" after it localises a stall to synthesis, and is
            // the difference between a silent shortcut and a diagnosable one.
            Log.log("speech job \(id): handing sentence \(job.next + 1)/\(job.segments.count) to playback — \(Log.clip(segment.text))")
            openSynthesisWindow(for: job)
            Task { [weak self] in
                // Positional callbacks: first audible sample, then audio fully
                // in hand. See the `play` property for why they are unlabelled.
                let request = SentencePlayback(jobID: id, text: segment.text, voice: job.voice,
                                               isLast: index == job.segments.count - 1)
                let completed = await play(request, { [weak self] in
                    Task { await self?.startedSentence(id: id) }
                }, { [weak self] in
                    Task { await self?.synthesisSettled(job: id, index: index) }
                })
                await self?.finishedSentence(id: id, completed: completed)
            }
            return
        }
    }

    /// Point the synthesis window at `job`'s current sentence and open it.
    ///
    /// The sentence being handed to playback synthesizes through `play`, not
    /// `prefetch` — `play` streams it and starts sound on the first chunk,
    /// where waiting on a prefetch would hold the whole clip back — so this
    /// only *books* it into the window. Every other sentence is started by
    /// `fillSynthesisWindow`.
    private func openSynthesisWindow(for job: Job) {
        if synthesisJob != job.id {
            synthesisJob = job.id
            synthesizing = []
            synthesisFrontier = 0
        }
        if synthesisFrontier <= job.next {
            // Only the job's first sentence: every later one was already
            // started by the lookahead before playback reached it.
            synthesizing.insert(job.next)
            synthesisFrontier = job.next + 1
        }
        fillSynthesisWindow()
    }

    /// Start as many lookahead syntheses as the window currently allows.
    ///
    /// Two rules, and the second is the one that is easy to get wrong.
    ///
    /// At most `maxConcurrentSyntheses` clips synthesize at once, because they
    /// contend for one backend and the loser is whichever the listener happens
    /// to be waiting on.
    ///
    /// And nothing further than one sentence ahead starts while the sentence
    /// being *played* is still synthesizing. That sentence is the only thing
    /// standing between the listener and sound; if the backend is struggling
    /// with it, spending the other slot on a speculative third clip makes the
    /// struggle worse. Once it is in hand the window opens as far as the
    /// concurrency cap allows — which is the point of expressing this as a
    /// budget rather than a fixed distance. Four short sentences no longer
    /// ration the budget one at a time while a very long fifth sits unstarted:
    /// each short one settles, frees its slot, and the window walks forward to
    /// reach the long one while there is still speech left to cover it.
    private func fillSynthesisWindow() {
        guard let id = current, id == synthesisJob, let job = jobs[id], let prefetch else { return }
        while synthesizing.count < Self.maxConcurrentSyntheses, synthesisFrontier < job.segments.count {
            if synthesisFrontier > job.next + 1, synthesizing.contains(job.next) { return }
            let index = synthesisFrontier
            synthesisFrontier += 1
            synthesizing.insert(index)
            let text = job.segments[index].text
            let voice = job.voice
            Task { [weak self] in
                await prefetch(text, voice)
                await self?.synthesisSettled(job: id, index: index)
            }
        }
    }

    /// One clip has stopped competing for the synthesizer — because it
    /// succeeded, failed, or was already cached. Either way a slot is free.
    ///
    /// Safe to call more than once for the same clip, and it is: a sentence the
    /// lookahead started and playback then caught up with reports through both
    /// paths. Set removal makes the second call a no-op, and re-filling an
    /// already-full window is one loop test.
    private func synthesisSettled(job id: String, index: Int) {
        guard synthesisJob == id else { return }
        synthesizing.remove(index)
        fillSynthesisWindow()
    }

    private func startedSentence(id: String) {
        guard current == id, let job = jobs[id], !terminal(job.state) else { return }
        Log.log("speech job \(id): sentence \(job.next + 1)/\(job.segments.count) is audible")
        update(id) { $0.playbackState = .speaking }
    }
    private func finishedSentence(id: String, completed: Bool) {
        defer { refreshActivity() }
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
            pump()
        } else {
            update(id) { $0.next = next; $0.playbackState = dictating ? .waitingForUser : .queued }
            pump()
        }
    }
    private func interruptCurrent(state: State) {
        defer { refreshActivity() }
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
