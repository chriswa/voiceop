import Foundation

/// Hands-free mode, for one audio source: start talking with a client's trigger
/// word — "Control, what's Kevin doing?" — and just keep going, and stop when
/// you are done.
///
/// Ported from Spaceterm's `src/mobile/hands-free.ts`, which ran on the phone
/// and in Spaceterm's desktop renderer until hands-free moved here (see
/// `docs/hands-free-plan.md`). What it does is unchanged; where it does it is not.
/// A source is the Mac's microphone or a client's stream (a phone, through the
/// iOS SDK), and every decision about what it hears is made here, so a client
/// only carries audio, draws what it is told, and acts on transcripts.
///
/// What the source hears goes through `WakeListener`, scored frame by frame by
/// the speech detector (Silero), so music or a noisy room is not speech. When
/// someone starts talking with nobody talking just before, the first second of
/// it is checked with Apple's on-device model for a leading trigger word. Only
/// the trigger said first counts. On a match a dictation opens through the
/// user's transcription provider, fed everything said since the first syllable
/// out of the listener's buffer, then live — so nothing waits on the check.
///
/// It ends at a pause, when the turn model (Smart Turn) says the speaker sounds
/// finished, or when a pause outlasts a patience that grows with how long they
/// have been talking (`UtteranceEndpointer`). The transcript goes to the client
/// whose trigger word it was, trigger word and all; the client strips it.
///
/// After the trigger word, and as hands-free is turned on, a conversation window
/// opens: speech starts a dictation without the trigger word — the check is only
/// that it was words, not a cough or filler. It stays open while either side is
/// speaking and closes once neither has for `conversationMs`. "Let me turn this
/// off", or "<trigger>, shutdown", closes it at once.
///
/// It does not listen while the source says it is playing on a device without
/// echo cancellation (`HandsFreeSourceState.deaf`), nor while a Fn dictation has
/// the Mac's microphone. Speech over the client's own voice — playing with echo
/// cancellation, or Voice Operator's — turns that voice down (`duck`), and once
/// the check says it was for the client, cuts it off (`cutIn`), dated to when
/// the user began talking.
///
/// Not thread-safe: every call is made on one queue (`HandsFreeService`), and
/// every dependency answers back on it.
final class HandsFreeEngine: @unchecked Sendable {
    enum Phase: String, Sendable { case off, listening, hearing, sending }

    /// A cue the client plays (or makes felt) its own way.
    enum Cue: String, Sendable {
        /// Hands-free is on and listening.
        case ready
        /// A dictation began — the trigger word or words in the window were heard.
        case dictationStart
        /// The dictation's words are being sent.
        case dictationEnd
        /// Speech that needed the trigger word turned out not to start with it.
        case notWakeWord
        /// The conversation window ran out: the trigger word is needed again.
        case conversationClosed
        /// "Let me turn this off" or "<trigger>, shutdown".
        case shutdown
        /// A dictation failed.
        case error

        /// The haptic it suggests, where the client can make one.
        var haptic: String? {
            switch self {
            case .dictationStart: return "tap"
            case .dictationEnd: return "double"
            case .conversationClosed: return "triple"
            default: return nil
            }
        }
    }

    /// Everything the engine tells its clients. Each goes to one client
    /// (`HandsFreeEngine.Outgoing.client`) or, for what concerns whoever is
    /// listening on this source, to all of them.
    enum Event: Equatable {
        /// What hands-free is doing. `closesAt` (wall-clock ms) is when the
        /// conversation window closes if nobody speaks; nil while it is held
        /// open or closed. `checking`: speech is being checked. `pending`:
        /// speech that needs the trigger word is undecided — the client's cue
        /// for a repeating "deciding" beep.
        case state(phase: Phase, conversation: Bool, closesAt: Double?, checking: Bool, pending: Bool)
        /// The end-of-dictation gauge, as data points the client animates from:
        /// quiet since `quietSince` (wall ms; nil while they talk) ends it at
        /// `patienceMs`; `turn` is the turn model's latest answer and the
        /// threshold it was held to; `sampling` the threshold while it is being
        /// asked about the pause.
        case gauge(quietSince: Double?, patienceMs: Double?, turn: Double?, threshold: Double, sampling: Bool)
        case cue(Cue)
        /// Turn the client's voice down for someone talking over it, or back up.
        case duck(Bool)
        /// The user cut the client's voice off: they began talking `msAgo`
        /// milliseconds ago, which is as far as they heard it.
        case cutIn(msAgo: Int)
        /// What was dictated, trigger word included. Empty when nothing was
        /// caught. `interrupted`: it cut the client's voice off. `shutdown`:
        /// it was a phrase that ends the conversation.
        case transcript(text: String, trigger: String?, interrupted: Bool, reason: String, shutdown: Bool)
    }

    struct Outgoing: Equatable {
        /// The client it is for; nil for every client listening on this source.
        let client: String?
        let event: Event
    }

    /// A dictation as the engine drives it: fed audio, finished or cancelled once.
    /// `finish` answers on the engine's queue.
    protocol Dictation: AnyObject {
        func append(_ pcm: [Int16])
        func finish(_ done: @escaping (Result<String, Error>) -> Void)
        func cancel()
    }

    /// What the words-check made of a clip: what Apple's model heard, or why it
    /// could not say.
    enum CheckAnswer { case heard(String), failed(String) }

    /// A timer the engine can cancel.
    protocol Timer { func cancel() }

    struct Deps {
        /// What was said in the clip (16 kHz s16le mono).
        var check: (_ clip: [Int16], _ done: @escaping (CheckAnswer) -> Void) -> Void
        /// Open a dictation for `client`, fed `backlog` first.
        var beginDictation: (_ client: String, _ backlog: [Int16]) -> Dictation
        /// The turn model's probability that the speaker has finished, or nil.
        var turn: (_ audio: [Float], _ done: @escaping (Double?) -> Void) -> Void
        /// Run `block` on the engine's queue after `ms`.
        var after: (_ ms: Double, _ block: @escaping () -> Void) -> Timer
        /// Wall clock, ms since 1970: for the gauge and window data points.
        var now: () -> Double
        var emit: (Outgoing) -> Void
        /// For the decision record: what was heard and decided.
        var record: (_ kind: String, _ detail: [String: Any]) -> Void
        var log: (String) -> Void
    }

    /// What the host knows that the audio does not say, read every frame.
    struct SourceState {
        /// Not listening: Voice Operator's own voice is playing on speakers, the
        /// client is playing without echo cancellation, or a Fn dictation has
        /// the microphone. The reason, for the record.
        var deaf: String?
        /// The client's voice playing on the source's device, with echo
        /// cancellation: it is turned down for anyone speaking, and can be cut off.
        var clientSpeaking = false
        /// Voice Operator speaking for a client (on the Mac): cut off by the
        /// trigger word too, and holding the window open.
        var voiceOperatorSpeaking = false
    }

    // MARK: - Tunables beyond `HandsFreeTuning`

    /// Through a pause, the turn model is asked again this often.
    static let turnSampleMs: Double = 500
    /// Frames without speech (about half a second) before a voice turned down
    /// for someone talking comes back up.
    static let unduckFrames = 16
    /// Quiet (about half a second) that ends speech watched for "let me turn
    /// this off", so the whole of it is checked.
    static let shutdownEndFrames = 16
    /// Speech watched for it that runs past this (about four seconds) is
    /// something longer, and let go.
    static let shutdownMaxFrames = 125
    /// Listening this long with no audio at all is recorded: the client shows
    /// hands-free on, so nothing else would say it is deaf.
    static let deafAfterMs: Double = 5000
    /// While listening, how often to record the room: how loud, and how much
    /// of it was speech — the first report this soon, so even a short try says
    /// what the source heard.
    static let levelsReportMs: Double = 30_000
    static let firstLevelsMs: Double = 5_000

    let tuning: HandsFreeTuning
    private let deps: Deps
    private var scorer: FrameScorer
    private let framer = Framer()
    private let listener: WakeListener
    /// Clients listening on this source, and their trigger words.
    private(set) var triggers: [String: String] = [:]
    /// The client that turned it on, and whose the conversation window is when
    /// no trigger word said otherwise.
    private var owner: String
    var sourceState: () -> SourceState = { SourceState() }

    private(set) var phase: Phase = .off
    private var live = false
    private var conversation = false
    /// The client whose window it is.
    private var conversationClient: String?
    private var silentFrames = 0
    private var closesAt: Double?
    private var checking = 0
    /// Of those, checks of candidates the listener handed out — not "let me turn
    /// this off" — which the pending beep waits on.
    private var candidatesChecking = 0
    private var stoodAside = false
    private var ducked = false
    private var speechRun = 0
    private var quietRun = 0
    private var shutdownWatch: (start: Int, frames: Int, quietFrames: Int)?
    /// The dictation under way.
    private var utterance: Utterance?
    /// Bumped at every pause, every resumption, and the dictation's end: a turn
    /// verdict counts only for the pause it was asked about.
    private var pauseNumber = 0
    private var lastState: Event?
    private var lastGauge: Event?
    private var heardSamples = 0
    /// Bumped whenever the source stalls: a wait for it to come back counts only
    /// for the stall it began at.
    private var stalls = 0
    private var deafTimer: Timer?
    /// The room since the last levels report.
    private var levels = (frames: 0, speechFrames: 0, sumDb: 0.0, maxDb: -120.0)
    private var firstLevels = true

    private final class Utterance {
        let client: String
        let trigger: String?
        let dictation: Dictation
        let endpointer: UtteranceEndpointer
        let interrupted: Bool
        /// Everything dictated so far, for the turn model's last eight seconds.
        var audio: [Int16]
        var backstop: Timer?
        var turn: Double?
        var sampling = false
        var ended = false
        init(client: String, trigger: String?, dictation: Dictation, endpointer: UtteranceEndpointer,
             interrupted: Bool, audio: [Int16]) {
            self.client = client
            self.trigger = trigger
            self.dictation = dictation
            self.endpointer = endpointer
            self.interrupted = interrupted
            self.audio = audio
        }
    }

    init(owner: String, trigger: String, scorer: FrameScorer, tuning: HandsFreeTuning = .standard, deps: Deps) {
        self.owner = owner
        self.tuning = tuning
        self.deps = deps
        self.scorer = scorer
        triggers[owner] = trigger
        let record = deps.record
        listener = WakeListener(tuning: tuning) { sighting in
            record("speech", ["verdict": sighting.verdict.rawValue, "durationMs": sighting.durationMs,
                              "noSpeechBeforeMs": sighting.noSpeechBeforeMs, "peakDb": sighting.peakDb])
        }
    }

    // MARK: - Driving it

    /// Swap the speech detector — Silero once it has loaded, loudness before.
    func setScorer(_ scorer: FrameScorer) {
        self.scorer = scorer
        listener.resume()
        deps.record("detector", ["name": scorer.name])
    }

    /// Another client listens on this source too (the Mac's microphone is shared).
    func addClient(_ client: String, trigger: String) { triggers[client] = trigger }

    /// A client stops listening here. Its dictation, if any, is cancelled.
    func removeClient(_ client: String) {
        triggers[client] = nil
        if utterance?.client == client { end(.lost) }
        if conversationClient == client { closeConversation(why: "client") }
        if owner == client, let next = triggers.keys.sorted().first { owner = next }
    }

    var clients: [String] { Array(triggers.keys) }

    /// The source is delivering audio. Turning it on opens the conversation
    /// window, so the first words need no trigger word; `reopened` (a stalled
    /// source back) leaves the window as it was.
    func sourceStarted(reopened: Bool = false) {
        guard !live else { return }
        live = true
        stalls += 1
        firstLevels = true
        levels = (0, 0, 0, -120)
        framer.reset()
        scorer.reset()
        listener.resume()
        if phase == .off { setPhase(.listening) }
        deps.log("listening for \(triggers.values.sorted().map { "\"\($0)\"" }.joined(separator: ", "))")
        deps.record("source", ["listening": true])
        if !reopened {
            emit(owner, .cue(.ready))
            openConversation(for: owner)
        }
        let heardBefore = heardSamples
        deafTimer?.cancel()
        deafTimer = deps.after(Self.deafAfterMs) { [weak self] in
            guard let self, self.live, self.heardSamples == heardBefore else { return }
            self.deps.log("no audio from the source in \(Int(Self.deafAfterMs / 1000))s of listening")
            self.deps.record("deaf", ["afterMs": Self.deafAfterMs])
        }
        publishState()
    }

    /// The source stopped delivering: turned off (`final`), or stalled. A
    /// dictation under way is lost. A stalled source keeps the window open for
    /// `conversationMs`, waiting for it.
    func sourceStopped(final: Bool) {
        guard live || final else { return }
        live = false
        deafTimer?.cancel()
        if utterance != nil { end(.lost) }
        shutdownWatch = nil
        if final {
            closeConversation(why: "source")
        } else if conversation {
            deps.log("the source stalled: the conversation window waits for it")
            stalls += 1
            let stall = stalls
            _ = deps.after(tuning.conversationMs) { [weak self] in
                guard let self, !self.live, self.stalls == stall else { return }
                self.closeConversation(why: "source")
            }
        }
        if phase == .listening { setPhase(.off) }
        deps.record("source", ["listening": false])
        publishState()
    }

    /// The source skipped audio (a stream resuming after a gap): speech in the
    /// gap is not to be acted on, so listening starts afresh, as after a cue.
    func gap() {
        framer.reset()
        listener.resume()
        shutdownWatch = nil
    }

    /// 16 kHz s16le mono, in arrival order.
    func push(_ pcm: [Int16]) {
        guard live else { return }
        heardSamples += pcm.count
        for frame in framer.frames(pcm) {
            let p: Float
            do {
                p = try scorer.score(frame)
            } catch {
                deps.log("speech detector failed (\(error)); using loudness")
                deps.record("detector", ["name": "loudness", "failed": "\(error)"])
                scorer = EnergyScorer()
                listener.resume()
                continue
            }
            noteLevels(frame, p: p)
            routeFrame(ScoredFrame(pcm: frame, p: p))
            publishState()
        }
    }

    private func noteLevels(_ frame: [Int16], p: Float) {
        let db = levelDb(frame)
        levels.frames += 1
        if p >= 0.5 { levels.speechFrames += 1 }
        levels.sumDb += db
        levels.maxDb = max(levels.maxDb, db)
        let seconds = Double(levels.frames) * HandsFreeAudio.frameMs
        guard seconds >= (firstLevels ? Self.firstLevelsMs : Self.levelsReportMs) else { return }
        let report: [String: Any] = [
            "detector": scorer.name, "seconds": Int(seconds / 1000),
            "speechPercent": 100 * levels.speechFrames / max(1, levels.frames),
            "meanDb": Int((levels.sumDb / Double(max(1, levels.frames))).rounded()), "maxDb": Int(levels.maxDb.rounded()),
            "phase": phase.rawValue,
        ]
        deps.record("levels", report)
        if levels.maxDb <= -119 {
            // Exact zeros: a microphone that is off (a closed lid) or muted, not a quiet room.
            deps.log("the source is sending only digital silence — a closed lid, or a muted input?")
            deps.record("silent-input", ["seconds": Int(seconds / 1000)])
        }
        if firstLevels {
            deps.log("first \(report["seconds"] ?? 0)s heard: \(report["speechPercent"] ?? 0)% speech, mean \(report["meanDb"] ?? 0) dB, "
                     + "peak \(report["maxDb"] ?? 0) dB (\(scorer.name))")
        }
        firstLevels = false
        levels = (0, 0, 0, -120)
    }

    /// How far the quiet has got towards ending the dictation (0…1), nil with none.
    var endSilence: Double? { utterance.map { $0.endpointer.silence() } }

    // MARK: - Frames

    private func routeFrame(_ frame: ScoredFrame) {
        let state = sourceState()
        trackPlayback(frame, speaking: state.clientSpeaking)
        tickConversation(state)
        if phase == .hearing, let utterance {
            utterance.dictation.append(frame.pcm)
            utterance.audio.append(contentsOf: frame.pcm)
            for event in utterance.endpointer.push([frame]) {
                switch event {
                case .ended(let reason): end(reason == .silence ? .silence : .tooLong)
                case .resumed: pauseOver()
                case .pause(let talkMs, let wakeWordOnly):
                    if wakeWordOnly {
                        // "Control." and a breath: the turn model would call that finished. Wait for the rest.
                        deps.log("pause after the trigger word alone: waiting for the rest, not asking the turn model")
                        deps.record("pause", ["talkMs": talkMs, "wakeWordOnly": true])
                    } else {
                        samplePause(talkMs: Double(talkMs))
                    }
                }
                if self.utterance == nil { break }
            }
            publishGauge()
            return
        }
        guard phase == .listening else { return }
        if let reason = state.deaf {
            // Deaf to the trigger word until this ends.
            if !stoodAside { deps.record("stood-aside", ["why": reason]) }
            stoodAside = true
            shutdownWatch = nil
            return
        }
        if stoodAside {
            stoodAside = false
            deps.record("listening-again", [:])
            listener.resume()
        }
        for candidate in listener.push([frame]) {
            // In the conversation window any words will do; otherwise they must start with a trigger word.
            let window = conversation
            deps.log("speech after \(candidate.noSpeechBeforeMs)ms without speech — checking its start "
                     + (window ? "for words" : "for a trigger word"))
            let overVoice = state.clientSpeaking || state.voiceOperatorSpeaking
            checking += 1
            candidatesChecking += 1
            deps.check(candidate.clip) { [weak self] answer in
                self?.checked(candidate, window: window, overVoice: overVoice, answer: answer)
            }
        }
        watchForShutdown()
    }

    private func checked(_ candidate: WakeCandidate, window: Bool, overVoice: Bool, answer: CheckAnswer) {
        checking -= 1
        candidatesChecking -= 1
        // Decided: the pending beep stops now, before a dictation's chirp or the sad tune.
        publishState()
        let heard: String
        switch answer {
        case .heard(let words): heard = words
        case .failed(let error):
            deps.log("cannot check the trigger word: \(error)")
            heard = ""
        }
        let verdict = HandsFreePhrases.judge(heard, triggers: Array(triggers.values))
        let client: String? = window
            ? (verdict.trigger.flatMap(clientFor) ?? conversationClient ?? owner)
            : verdict.trigger.flatMap(clientFor)
        let match = window ? verdict.words : client != nil
        deps.log(match
            ? (window ? "words, in the conversation window: dictating from its start"
                      : "it starts with \"\(verdict.trigger ?? "")\": dictating from its start")
            : (window ? "not words (a cough, filler, nothing)" : "not a trigger word"))
        deps.record("check", ["match": match, "mode": window ? "speech" : "wake-word",
                              "wakeWord": verdict.trigger != nil, "noSpeechBeforeMs": candidate.noSpeechBeforeMs,
                              "spokeMs": candidate.spokeMs, "overVoice": overVoice])
        if !match, !window, phase == .listening, live {
            if verdict.shutdown != nil {
                // Perhaps "let me turn this off", which needs no trigger word: wait for it to end, then check the whole of it.
                deps.log("it may be \"let me turn this off\": checking the whole of it once it ends")
                shutdownWatch = (start: candidate.start, frames: 0, quietFrames: 0)
            } else {
                emit(nil, .cue(.notWakeWord))
            }
        }
        guard match, let client, phase == .listening, live else {
            unduckIfDone()
            publishState()
            return
        }
        // Said over the client's voice: cut it off, dated to when they began.
        let state = sourceState()
        let interrupting = state.clientSpeaking || state.voiceOperatorSpeaking
        if interrupting {
            // From the first syllable, in audio heard — so a check that took a while costs none of it.
            let msAgo = Int(listener.msSince(candidate.start).rounded())
            deps.log("\(window ? "words" : "the trigger word") over the client's voice: cutting it off as of \(msAgo)ms ago")
            var detail: [String: Any] = ["mode": window ? "speech" : "wake-word", "cutInMsAgo": msAgo, "heard": heard]
            // How far into the reply they began: echo leaking through cancellation starts early, and the same each time.
            if let e = echo { detail["intoReplyMs"] = max(0, Int(Double(e.frames) * HandsFreeAudio.frameMs) - msAgo) }
            echo?.cutIns += 1
            deps.record("interrupt", detail)
            emit(client, .cutIn(msAgo: msAgo))
        }
        respond(candidate, client: client, trigger: verdict.trigger, interrupted: interrupting,
                wakeWordStart: verdict.trigger != nil)
    }

    private func clientFor(trigger: String) -> String? {
        triggers.first { $0.value == trigger }?.key
    }

    // MARK: - Dictation

    private func respond(_ candidate: WakeCandidate, client: String, trigger: String?, interrupted: Bool,
                         wakeWordStart: Bool) {
        setPhase(.hearing)
        shutdownWatch = nil
        emit(client, .cue(.dictationStart))
        openConversation(for: client)
        let backlog = listener.audioSince(candidate.start)
        let backlogMs = HandsFreeAudio.ms(samples: backlog.count)
        let dictation = deps.beginDictation(client, backlog)
        let endpointer = UtteranceEndpointer(tuning: tuning, alreadyMs: backlogMs,
                                             alreadySpokeMs: Double(candidate.spokeMs), wakeWordStart: wakeWordStart)
        let utterance = Utterance(client: client, trigger: trigger, dictation: dictation, endpointer: endpointer,
                                  interrupted: interrupted, audio: backlog)
        self.utterance = utterance
        utterance.backstop = deps.after(tuning.maxUtteranceMs + 10_000) { [weak self, weak utterance] in
            guard let self, let utterance, self.utterance === utterance else { return }
            self.end(.lost)
        }
        publishGauge()
    }

    private enum EndReason: String { case finished, silence, tooLong = "too-long", lost }

    private func end(_ reason: EndReason) {
        guard let utterance, !utterance.ended else { return }
        utterance.ended = true
        utterance.backstop?.cancel()
        stopSampling()
        self.utterance = nil
        emit(utterance.client, .cue(.dictationEnd))
        deps.record("ended", ["reason": reason.rawValue])
        if reason == .lost {
            deps.log("the source stopped mid-dictation")
            utterance.dictation.cancel()
            if utterance.interrupted { carryOn(utterance) }
            finishedDictation()
            return
        }
        setPhase(.sending)
        publishGauge(keepingTurn: utterance)
        utterance.dictation.finish { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text):
                let trigger = utterance.trigger ?? self.triggers[utterance.client]
                let shutdown = HandsFreePhrases.isShutdown(text, trigger: trigger)
                self.deps.log("\(text.count) chars to \(utterance.client) (ended on \(reason.rawValue)"
                              + (utterance.interrupted ? ", having cut it off)" : ")"))
                self.emit(utterance.client, .transcript(text: text, trigger: utterance.trigger,
                                                        interrupted: utterance.interrupted,
                                                        reason: reason.rawValue, shutdown: shutdown))
                if shutdown { self.sentAway(client: utterance.client, how: "dictated") }
            case .failure(let error):
                self.deps.log("dictation failed: \(error)")
                self.emit(utterance.client, .cue(.error))
                if utterance.interrupted { self.carryOn(utterance) }
            }
            self.finishedDictation()
        }
    }

    private func finishedDictation() {
        guard utterance == nil else { return }
        setPhase(live ? .listening : .off)
        listener.resume()
        publishGauge()
        publishState()
    }

    /// Cut off, then nothing caught: the client is told there are no words, so
    /// its voice can say it had not finished and carry on.
    private func carryOn(_ utterance: Utterance) {
        deps.log("cut the client's voice off, then caught nothing: it carries on")
        deps.record("empty-interruption", [:])
        emit(utterance.client, .transcript(text: "", trigger: utterance.trigger, interrupted: true,
                                           reason: "lost", shutdown: false))
    }

    /// A pause: ask the turn model every `turnSampleMs` for as long as it lasts,
    /// and end the first time it is sure enough they have finished. An answer
    /// arriving after they carried on is about a pause that is over, and dropped.
    private func samplePause(talkMs: Double) {
        pauseOver()
        guard let utterance else { return }
        let pause = pauseNumber
        utterance.sampling = true
        var sample = 0
        func ask() {
            guard pause == pauseNumber, let current = self.utterance, current === utterance else { return }
            sample += 1
            let asked = deps.now()
            let window = Array(utterance.audio.suffix(SmartTurnWindow.samples)).map { Float($0) / 32768 }
            deps.turn(window) { [weak self] p in
                guard let self else { return }
                let stillCurrent = pause == self.pauseNumber
                self.deps.log(String(format: "pause after %.1fs, sample %d: %@%@", talkMs / 1000, sample,
                                     p.map { String(format: "p(finished)=%.2f", $0) } ?? "no turn verdict",
                                     stillCurrent ? "" : ", but it is over"))
                let ends = stillCurrent && (p ?? 0) >= self.tuning.turnThreshold && p != nil
                self.deps.record("turn", ["talkMs": Int(talkMs), "sample": sample, "p": p ?? NSNull(),
                                          "threshold": self.tuning.turnThreshold, "ends": ends,
                                          "carriedOn": !stillCurrent])
                guard stillCurrent else { return }
                if let p { utterance.turn = p }
                self.publishGauge()
                if ends {
                    self.end(.finished)
                    return
                }
                let wait = max(0, Self.turnSampleMs - (self.deps.now() - asked))
                _ = self.deps.after(wait) { ask() }
            }
        }
        publishGauge()
        ask()
    }

    /// No more asking about this pause.
    private func stopSampling() {
        pauseNumber += 1
        utterance?.sampling = false
    }

    /// The pause is over — they carried on: any verdict on it is moot.
    private func pauseOver() {
        stopSampling()
        utterance?.turn = nil
    }

    // MARK: - The conversation window

    private func openConversation(for client: String) {
        silentFrames = 0
        closesAt = nil
        conversationClient = client
        guard !conversation else { return }
        conversation = true
        listener.setConversation(true)
        deps.log("conversation window open: no need for the trigger word until both sides have been quiet a while")
        deps.record("conversation", ["open": true])
    }

    /// `silence`: it ran out, with a cue. `shutdown`: a shutdown phrase, with
    /// its own. The source going (`source`) or the client leaving close it quietly.
    private func closeConversation(why: String) {
        guard conversation else { return }
        let client = conversationClient
        conversation = false
        conversationClient = nil
        listener.setConversation(false)
        silentFrames = 0
        closesAt = nil
        deps.log("conversation window closed (\(why)): the trigger word again from here")
        deps.record("conversation", ["open": false, "why": why])
        if why == "shutdown" { emit(client, .cue(.shutdown)) }
        else if why == "silence" { emit(client, .cue(.conversationClosed)) }
        publishState()
    }

    /// Each frame, while the window is open: anyone speaking — the user, or the
    /// client's voice — holds it open; once both are quiet, `conversationMs`
    /// of that closes it.
    private func tickConversation(_ state: SourceState) {
        guard conversation else { return }
        let someoneSpeaking = phase != .listening || listener.speaking || state.clientSpeaking
            || state.voiceOperatorSpeaking || state.deaf != nil
        silentFrames = someoneSpeaking ? 0 : silentFrames + 1
        let quietMs = Double(silentFrames) * HandsFreeAudio.frameMs
        if quietMs >= tuning.conversationMs {
            closeConversation(why: "silence")
            return
        }
        closesAt = someoneSpeaking ? nil : (closesAt ?? deps.now() + tuning.conversationMs - quietMs)
    }

    // MARK: - "Let me turn this off"

    /// A shutdown phrase heard: the conversation window closes (with the cue),
    /// or the cue alone if it was shut. `how`: `dictated` after the trigger
    /// word or in the window; `heard` without either.
    private func sentAway(client: String, how: String) {
        deps.log("conversation ended by voice (\(how))")
        deps.record("shutdown", ["how": how])
        if conversation { closeConversation(why: "shutdown") } else { emit(client, .cue(.shutdown)) }
    }

    /// Each frame while listening, for speech being watched for "let me turn
    /// this off": once it has been quiet for `shutdownEndFrames`, the whole of
    /// it is checked, and if it was the phrase and nothing else, the
    /// conversation ends. Speech that runs on is something longer, and let go.
    private func watchForShutdown() {
        guard var watch = shutdownWatch else { return }
        watch.frames += 1
        watch.quietFrames = listener.speaking ? 0 : watch.quietFrames + 1
        if watch.frames > Self.shutdownMaxFrames {
            shutdownWatch = nil
            deps.record("shutdown-check", ["verdict": "too-long"])
            emit(nil, .cue(.notWakeWord))
            return
        }
        guard watch.quietFrames >= Self.shutdownEndFrames else { shutdownWatch = watch; return }
        shutdownWatch = nil
        let clip = listener.audioSince(watch.start)
        checking += 1
        deps.check(clip) { [weak self] answer in
            guard let self else { return }
            self.checking -= 1
            var whole = false
            if case .heard(let heard) = answer { whole = HandsFreePhrases.wakeFreeShutdown(heard) == .whole }
            self.deps.record("shutdown-check", ["verdict": whole ? "whole" : "not-it",
                                                "ms": Int(HandsFreeAudio.ms(samples: clip.count))])
            if whole, self.phase == .listening, self.live {
                let client = self.conversationClient ?? self.owner
                self.emit(client, .transcript(text: HandsFreePhrases.letMeTurnThisOff.joined(separator: " "),
                                              trigger: nil, interrupted: false, reason: "heard", shutdown: true))
                self.sentAway(client: client, how: "heard")
            } else {
                self.deps.log("not \"let me turn this off\" after all")
                if self.phase == .listening, self.live { self.emit(nil, .cue(.notWakeWord)) }
                self.unduckIfDone()
            }
            self.publishState()
        }
    }

    // MARK: - The client's voice

    /// Every frame while the client's voice plays with echo cancellation:
    /// anyone speaking turns it down at once, and quiet brings it back once no
    /// check is pending.
    private func trackPlayback(_ frame: ScoredFrame, speaking: Bool) {
        guard speaking else {
            if let echo { recordEcho(echo) }
            echo = nil
            setDuck(false)
            speechRun = 0
            quietRun = 0
            return
        }
        if frame.p >= SpeechGate.start {
            speechRun += 1
            quietRun = 0
        } else {
            speechRun = 0
            if frame.p < SpeechGate.stop { quietRun += 1 }
        }
        if !ducked, speechRun >= SpeechGate.startFrames { setDuck(true) }
        unduckIfDone()
        noteEcho(frame)
    }

    /// What the source heard while the client's voice played through echo
    /// cancellation, one reply at a time: how much of it still sounded like
    /// speech, how loud, and how soon — the record that says whether
    /// interrupting by voice can work on this device, and why the client's
    /// voice was cut off when nobody spoke. Spaceterm's page kept it as
    /// `hands-free-echo` before hands-free moved here.
    private struct Echo {
        var frames = 0
        var speechFrames = 0
        var run = 0
        var longestRun = 0
        /// Frames into the reply when speech was first heard.
        var firstSpeechFrame: Int?
        var sumDb = 0.0
        var maxDb = -120.0
        var ducks = 0
        var cutIns = 0
    }
    private var echo: Echo?

    private func noteEcho(_ frame: ScoredFrame) {
        var e = echo ?? Echo()
        let db = levelDb(frame.pcm)
        e.frames += 1
        e.sumDb += db
        e.maxDb = max(e.maxDb, db)
        if frame.p >= SpeechGate.start {
            e.speechFrames += 1
            e.run += 1
            e.longestRun = max(e.longestRun, e.run)
            if e.firstSpeechFrame == nil { e.firstSpeechFrame = e.frames - 1 }
        } else {
            e.run = 0
        }
        echo = e
    }

    private func recordEcho(_ e: Echo) {
        let ms = { (frames: Int) in Int((Double(frames) * HandsFreeAudio.frameMs).rounded()) }
        var detail: [String: Any] = [
            "seconds": (Double(e.frames) * HandsFreeAudio.frameMs / 100).rounded() / 10,
            "speechPercent": 100 * e.speechFrames / max(1, e.frames),
            "longestSpeechMs": ms(e.longestRun),
            "micMeanDb": Int((e.sumDb / Double(max(1, e.frames))).rounded()),
            "micMaxDb": Int(e.maxDb.rounded()),
            "ducks": e.ducks, "cutIns": e.cutIns,
        ]
        if let first = e.firstSpeechFrame { detail["firstSpeechMs"] = ms(first) }
        deps.record("echo", detail)
        if e.speechFrames > 0 {
            deps.log("the client's voice played \(detail["seconds"] ?? 0)s through echo cancellation: "
                     + "\(detail["speechPercent"] ?? 0)% still sounded like speech, the first at "
                     + "\(detail["firstSpeechMs"] ?? 0)ms, peak \(detail["micMaxDb"] ?? 0) dB")
        }
    }

    private func setDuck(_ on: Bool) {
        guard ducked != on else { return }
        ducked = on
        if on { echo?.ducks += 1 }
        emit(conversationClient ?? owner, .duck(on))
        deps.record("duck", ["on": on])
    }

    /// Back up once they have been quiet a while — unless what they said is
    /// still being decided.
    private func unduckIfDone() {
        if ducked, quietRun >= Self.unduckFrames, checking == 0, shutdownWatch == nil { setDuck(false) }
    }

    // MARK: - Telling the clients

    private func setPhase(_ next: Phase) {
        guard phase != next else { return }
        deps.record("phase", ["from": phase.rawValue, "to": next.rawValue])
        phase = next
        publishState()
    }

    /// The state, sent only when it changed.
    private func publishState() {
        let pending = phase == .listening && live && !stoodAside && !conversation
            && (listener.undecided || candidatesChecking > 0)
        let state = Event.state(phase: phase, conversation: conversation, closesAt: closesAt,
                                checking: checking > 0, pending: pending)
        guard state != lastState else { return }
        lastState = state
        emit(nil, state)
    }

    /// The gauge, sent only when a data point changed: the quiet starting or
    /// ending, the patience moving by more than a frame's worth, a turn answer.
    private func publishGauge(keepingTurn ended: Utterance? = nil) {
        let gauge: Event
        if let utterance {
            let quiet = utterance.endpointer.quietMs
            let since = quiet > 0 ? (deps.now() - quiet).rounded() : nil
            gauge = .gauge(quietSince: since, patienceMs: utterance.endpointer.patienceMs.rounded(),
                           turn: utterance.turn, threshold: tuning.turnThreshold, sampling: utterance.sampling)
            if case .gauge(let lastSince, let lastPatience, let lastTurn, _, let lastSampling)? = lastGauge,
               (lastSince == nil) == (since == nil), lastTurn == utterance.turn, lastSampling == utterance.sampling,
               abs((lastPatience ?? 0) - utterance.endpointer.patienceMs) < HandsFreeAudio.frameMs * 4 {
                return
            }
        } else if let ended {
            // Sending: what ended it stays shown.
            gauge = .gauge(quietSince: nil, patienceMs: nil, turn: ended.turn, threshold: tuning.turnThreshold,
                           sampling: false)
        } else {
            gauge = .gauge(quietSince: nil, patienceMs: nil, turn: nil, threshold: tuning.turnThreshold, sampling: false)
        }
        guard gauge != lastGauge else { return }
        lastGauge = gauge
        emit(utterance?.client ?? ended?.client ?? owner, gauge)
    }

    private func emit(_ client: String?, _ event: Event) {
        deps.emit(Outgoing(client: client, event: event))
    }
}

/// The turn model hears the last eight seconds.
enum SmartTurnWindow {
    static let samples = 8 * HandsFreeAudio.sampleRate
}
