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
    /// Why a sentence stopped playing.
    ///
    /// Three cases rather than a Bool: a listener cutting the voice off and
    /// synthesis breaking are different events, and only one of them is an
    /// error the client should hear about.
    enum SentenceOutcome: Sendable {
        /// Played to its last sample.
        case finished
        /// Stopped on purpose, carrying where the voice had got to if it is
        /// known. The interrupt is *reported* here rather than merely allowed
        /// for, because whoever stops the audio and whoever announces the stop
        /// are two different paths racing each other, and only one of them can
        /// win. Either landing first now settles the job the same way.
        case interrupted(SpokenPosition?)
        /// Neither: synthesis or playback broke.
        case failed
    }
    /// One voice's stretch of a job. A job is one or more of these, spoken in
    /// order as a single utterance: the job's text is their texts joined with
    /// a single space, and every offset the job reports is into that joined
    /// text. One job rather than one per voice so that synthesis lookahead,
    /// barge-in and `character_offset` all span the voice changes.
    struct Part: Sendable, Equatable {
        let text: String
        let voice: String
        /// What sits between two parts in the job's text.
        static let separator = " "
        static func joined(_ parts: [Part]) -> String { parts.map(\.text).joined(separator: separator) }
    }
    /// One sentence of a job, and the voice that speaks it. `start` and `end`
    /// are its UTF-16 offsets in the job's (joined) text — UTF-16 because that
    /// is what every consumer of `character_offset` indexes strings by, and
    /// because a scalar count disagrees with all of them as soon as a job
    /// contains an emoji or anything else outside the BMP. `start` is not
    /// always the previous sentence's `end`: the separator between two parts
    /// belongs to neither of them.
    private struct Segment: Sendable { let text: String; let voice: String; let start: Int; let end: Int }
    struct SentencePlayback: Sendable {
        let jobID: String
        let text: String
        /// This sentence's voice, which can differ from its neighbours'.
        let voice: String
        let isLast: Bool
    }
    private struct Job: Sendable {
        let id: String; let segments: [Segment]
        var next = 0
        var state: State = .inProgress
        var playbackState: PlaybackState? = .queued
        var local = false
        var version = 0
        /// Where the voice actually stopped, recorded when a listener cut the
        /// job off part-way through a sentence. Absent for every other way a
        /// job ends, which is what keeps `character_offset` at sentence
        /// resolution when that is all there is to report.
        var stoppedAt: SpokenPosition?
    }

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
    private var play: (@Sendable (SentencePlayback, @escaping @Sendable () -> Void, @escaping @Sendable () -> Void) async -> SentenceOutcome)?
    /// Synthesize a clip without playing it, returning when it has settled.
    private var prefetch: (@Sendable (String, String) async -> Void)?
    /// Stop the audio, and say how far into the current sentence it had got.
    ///
    /// One closure rather than a reader and a separate stopper, because
    /// stopping is what destroys the word timings: splitting them leaves two
    /// calls whose order is load-bearing and nothing to enforce it.
    private var halt: (@Sendable () async -> SpokenPosition?)?
    /// How far into the current sentence the voice has got, read without
    /// stopping it: the same word timings `halt` reads, for a client asking
    /// mid-speech (`liveResult`).
    private var spokenPosition: (@Sendable () async -> SpokenPosition?)?
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

    func configure(play: @escaping @Sendable (SentencePlayback, @escaping @Sendable () -> Void, @escaping @Sendable () -> Void) async -> SentenceOutcome,
                   prefetch: @escaping @Sendable (String, String) async -> Void,
                   halt: @escaping @Sendable () async -> SpokenPosition?,
                   spokenPosition: @escaping @Sendable () async -> SpokenPosition? = { nil },
                   onSpeechActivity: @escaping @Sendable (Bool) -> Void = { _ in }) {
        self.play = play; self.prefetch = prefetch; self.halt = halt; self.spokenPosition = spokenPosition
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
        enqueue(parts: [Part(text: text, voice: voice)], local: local)
    }

    func enqueue(parts: [Part], local: Bool = false) -> Result? {
        guard !muted else { return Result(id: "", state: .cancelledByClient, playbackState: nil, characterOffset: 0, error: "speech_muted", version: 0) }
        let segments = Self.segments(parts)
        guard !segments.isEmpty else { return Result(id: "", state: .synthesisFailed, playbackState: nil, characterOffset: 0, error: "empty_text", version: 0) }
        let id = "sp_" + UUID().uuidString.lowercased()
        jobs[id] = Job(id: id, segments: segments, local: local)
        let chars = parts.reduce(0) { $0 + $1.text.count } + Part.separator.count * max(0, parts.count - 1)
        let voices = parts.map(\.voice).joined(separator: ",")
        Log.log("speech job \(id): accepted \(chars) chars in \(parts.count) part(s) as \(segments.count) sentence(s), voice=\(voices)")
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
    func stopSpeaking() async -> Bool {
        let pending = order.contains { id in
            guard let job = jobs[id] else { return false }
            return !terminal(job.state)
        }
        guard current != nil || pending else { return false }
        await interruptCurrent(state: .interruptedByUser)
        for id in order {
            guard let job = jobs[id], !terminal(job.state) else { continue }
            update(id) { $0.state = .interruptedByUser; $0.playbackState = nil }
        }
        order.removeAll()
        return true
    }

    func result(id: String) -> Result? { jobs[id].map(result) }

    /// A job's result with `character_offset` at word resolution while it is
    /// the one speaking: how far into the current sentence the voice has got,
    /// by the narration's word timings, instead of the end of the last
    /// sentence that finished. Never less than that sentence-level offset. A
    /// client that decides mid-speech what is still to come — Spaceterm's
    /// receptionist, weighing whether news should cut in — needs to know where
    /// the voice is now, not where it was at the last full stop.
    func liveResult(id: String) async -> Result? {
        guard let job = jobs[id] else { return nil }
        guard current == id, job.playbackState == .speaking, !terminal(job.state),
              let position = await spokenPosition?() else { return result(job) }
        // The actor may have moved on while the position was read.
        guard var now = jobs[id], current == id, !terminal(now.state) else { return jobs[id].map(result) }
        let sentenceLevel = result(now)
        now.stoppedAt = position
        let wordLevel = result(now)
        return wordLevel.characterOffset > sentenceLevel.characterOffset ? wordLevel : sentenceLevel
    }

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

    func beginDictation() async { dictating = true; await interruptCurrent(state: .interruptedByUser) }
    func endDictation() { dictating = false; pump() }
    func cancel(id: String) async -> Result? {
        guard let job = jobs[id] else { return nil }
        guard !terminal(job.state) else { return result(job) }
        if current == id { await interruptCurrent(state: .cancelledByClient) }
        else { update(id) { $0.state = .cancelledByClient; $0.playbackState = nil }; order.removeAll { $0 == id } }
        return jobs[id].map(result)
    }
    func setMuted(_ on: Bool) async {
        muted = on
        guard on else { pump(); return }
        await interruptCurrent(state: .cancelledByClient)
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
            Log.log("speech job \(id): handing sentence \(job.next + 1)/\(job.segments.count) to playback, voice=\(segment.voice) — \(Log.clip(segment.text))")
            openSynthesisWindow(for: job)
            Task { [weak self] in
                // Positional callbacks: first audible sample, then audio fully
                // in hand. See the `play` property for why they are unlabelled.
                let request = SentencePlayback(jobID: id, text: segment.text, voice: segment.voice,
                                               isLast: index == job.segments.count - 1)
                let outcome = await play(request, { [weak self] in
                    Task { await self?.startedSentence(id: id) }
                }, { [weak self] in
                    Task { await self?.synthesisSettled(job: id, index: index) }
                })
                await self?.finishedSentence(id: id, outcome: outcome)
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
            // The segment's own voice: the window runs straight across a
            // change of speaker, which is why a multi-voice reply is one job.
            let text = job.segments[index].text
            let voice = job.segments[index].voice
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
    private func finishedSentence(id: String, outcome: SentenceOutcome) {
        defer { refreshActivity() }
        guard current == id, let job = jobs[id] else { return }
        current = nil
        if case .interrupted(let stoppedAt) = outcome {
            // Settle it here rather than wait for the interrupt path to say so.
            // Dictation stops the voice itself, ahead of telling this queue, so
            // whichever of the two arrives first has to be able to finish the
            // job — see `SentenceOutcome`. The other finds it terminal and
            // leaves it alone.
            if !terminal(job.state) {
                Log.log("speech job \(id): interrupted_by_user at sentence \(job.next + 1)/\(job.segments.count)")
                if let stoppedAt {
                    Log.log("speech job \(id): voice stopped \(stoppedAt.characterOffset) chars into sentence \(stoppedAt.sentence + 1)")
                }
                update(id) { $0.state = .interruptedByUser; $0.playbackState = nil; $0.stoppedAt = stoppedAt }
                order.removeAll { $0 == id }
            }
            pump(); return
        }
        if case .failed = outcome {
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
    private func interruptCurrent(state: State) async {
        defer { refreshActivity() }
        guard let id = current, let job = jobs[id], !terminal(job.state) else { return }
        Log.log("speech job \(id): \(state.rawValue) at sentence \(job.next + 1)/\(job.segments.count)")
        // Halt the audio before announcing the state, so a client that reacts
        // to the terminal result is never racing sound that is still playing.
        // Awaited now that halting also reports where it stopped: the offset has
        // to be in hand before the terminal state that carries it is published.
        order.removeAll { $0 == id }; current = nil
        let stoppedAt = await halt?()
        if let stoppedAt {
            Log.log("speech job \(id): voice stopped \(stoppedAt.characterOffset) chars into sentence \(stoppedAt.sentence + 1)")
        }
        update(id) { $0.state = state; $0.playbackState = nil; $0.stoppedAt = stoppedAt }
    }
    private func result(_ job: Job) -> Result {
        return Result(id: job.id, state: job.state, playbackState: job.playbackState,
                      characterOffset: Self.characterOffset(job),
                      error: job.state == .synthesisFailed ? "synthesis_failed" : nil, version: job.version)
    }

    /// How much of the job's text the listener has heard, in UTF-16 offsets.
    ///
    /// Sentence resolution by default: everything up to the end of the last
    /// sentence that finished. A listener who cut the job off mid-sentence gets
    /// word resolution instead, which is the difference between a client
    /// believing they heard nothing of a long sentence and knowing they heard
    /// all but its last three words.
    ///
    /// The interrupted position's own sentence index sets the base, not
    /// `job.next`. Those two agree while playback runs forwards and part ways
    /// the moment someone rewinds into an earlier sentence and stops it there.
    ///
    /// The base is that sentence's own `start`, not its predecessor's `end`:
    /// the first sentence of a later part begins after the separator, and the
    /// word offset is measured from the sentence text the synthesizer was given.
    private static func characterOffset(_ job: Job) -> Int {
        guard let stopped = job.stoppedAt, job.segments.indices.contains(stopped.sentence) else {
            return job.next == 0 ? 0 : job.segments[job.next - 1].end
        }
        let base = job.segments[stopped.sentence].start
        // Clamped to the sentence it belongs to: the offset is measured against
        // the sentence text the synthesizer was given, and nothing downstream
        // should have to defend itself against a position past its end.
        let within = min(max(0, stopped.characterOffset), (job.segments[stopped.sentence].text as NSString).length)
        return base + within
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
    /// detector, run over each part on its own so that no sentence spans two
    /// voices. Offsets are UTF-16 positions in the parts' joined text.
    private static func segments(_ parts: [Part]) -> [Segment] {
        var answer: [Segment] = []
        var partStart = 0
        for (i, part) in parts.enumerated() {
            if i > 0 { partStart += (Part.separator as NSString).length }
            answer += segments(part.text, voice: part.voice, at: partStart)
            partStart += (part.text as NSString).length
        }
        return answer
    }
    private static func segments(_ text: String, voice: String, at base: Int) -> [Segment] {
        let ns = text as NSString
        var answer: [Segment] = []
        let tagger = NSLinguisticTagger(tagSchemes: [.tokenType], options: 0)
        tagger.string = text
        tagger.enumerateTags(in: NSRange(location: 0, length: ns.length), unit: .sentence, scheme: .tokenType, options: []) { _, range, _ in
            let part = ns.substring(with: range)
            guard !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            answer.append(Segment(text: part, voice: voice, start: base + range.location, end: base + NSMaxRange(range)))
        }
        if answer.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            answer.append(Segment(text: text, voice: voice, start: base, end: base + ns.length))
        }
        return answer
    }
}
