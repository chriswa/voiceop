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
/// It ends at a pause, when the turn model (turn-1-mini, `TurnOneMini`) says the
/// speaker has finished and the quiet holds (`checkMiniEnding`), or when a pause
/// outlasts a patience that grows with how long they have been talking
/// (`UtteranceEndpointer`). The transcript goes to the client
/// whose trigger word it was, trigger word and all; the client strips it.
///
/// After the trigger word, and as hands-free is turned on, a conversation window
/// opens: speech starts a dictation without the trigger word — the check is only
/// that it was words, not a cough or filler. It stays open while either side is
/// speaking and closes once neither has for `conversationMs`. "Let me turn this
/// off", or "<trigger>, shutdown", closes it at once; so does "stop listening",
/// as if it had run out, and hands-free stays on.
///
/// Speech outside the window that does not start with the trigger word gets the
/// `notWakeWord` cue, but only `notWakeWordLimit` times in a row, and never
/// after "stop listening": then nothing until the trigger word opens the window.
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
        /// The conversation window ran out, or "stop listening": the trigger word is needed again.
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
        /// for a repeating "deciding" beep. `standingAside`: listening, but not
        /// to the microphone, and why.
        case state(phase: Phase, conversation: Bool, closesAt: Double?, checking: Bool, pending: Bool,
                   standingAside: StandAside? = nil)
        /// The end-of-dictation gauge, as data points the client animates from.
        case gauge(Gauge)
        case cue(Cue)
        /// Turn the client's voice down for someone talking over it, or back up.
        case duck(Bool)
        /// Speech that needed the trigger word did not start with it: what Apple's
        /// model heard, for a client that shows it. `throughEcho`: heard while our
        /// own voice played (`SourceState.throughEcho`), so most likely that voice;
        /// `echo`: it matched what that voice just said. Sent whether or not the
        /// `notWakeWord` cue is.
        case notTrigger(heard: String, throughEcho: Bool, echo: Bool)
        /// The user cut the client's voice off: they began talking `msAgo`
        /// milliseconds ago, which is as far as they heard it.
        case cutIn(msAgo: Int)
        /// What was dictated, trigger word included. Empty when nothing was
        /// caught. `interrupted`: it cut the client's voice off. `shutdown`:
        /// it was a phrase that ends the conversation.
        case transcript(text: String, trigger: String?, interrupted: Bool, reason: String, shutdown: Bool)
    }

    /// Why hands-free is not listening to its source while it says it is:
    /// `speech`, our own voice playing where the microphone hears it (Voice
    /// Operator on the Mac's speakers, the client's voice on the phone's);
    /// `sound`, the client's other sound (a cue); `dictation`, a Fn dictation
    /// has the Mac's microphone.
    enum StandAside: String, Sendable { case speech, sound, dictation }

    /// What may end the dictation, as the client draws it: quiet since
    /// `quietSince` (wall ms; nil while they talk) ends it at `patienceMs`;
    /// `mini` is turn-1-mini's latest answer, `miniPeak` its highest since
    /// this pause began (nil while they talk), and `miniThreshold` the answer
    /// that ends the dictation.
    struct Gauge: Equatable, Sendable {
        var quietSince: Double?
        var patienceMs: Double?
        var mini: Double?
        var miniPeak: Double?
        var miniThreshold: Double = TurnOneMini.threshold
    }

    /// A streaming end-of-turn model, fed every sample of a dictation in order:
    /// P(end of turn) per 20 ms frame. turn-1-mini (`TurnOneMini.Stream`).
    protocol ContinuousTurn: AnyObject {
        func push(_ pcm: [Int16]) throws -> [Float]
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
        /// Run `block` on the engine's queue after `ms`.
        var after: (_ ms: Double, _ block: @escaping () -> Void) -> Timer
        /// Wall clock, ms since 1970: for the gauge and window data points.
        var now: () -> Double
        var emit: (Outgoing) -> Void
        /// For the decision record: what was heard and decided.
        var record: (_ kind: String, _ detail: [String: Any]) -> Void
        var log: (String) -> Void
        /// A fresh turn-1-mini stream for a dictation, or nil while it is unavailable.
        var continuousTurn: () -> ContinuousTurn? = { nil }
        /// Whether what was heard through our own voice is that voice: words it just said (`RecentSpeech`).
        var isEcho: (_ heard: String) -> Bool = { _ in false }
    }

    struct Deaf {
        var why: String
        var cause: StandAside
    }

    /// What the host knows that the audio does not say, read every frame.
    struct SourceState {
        /// Not listening: Voice Operator's own voice is playing on speakers, the
        /// client is playing without echo cancellation, or a Fn dictation has
        /// the microphone. The reason, for the record, and for the client.
        var deaf: Deaf?
        /// The client's voice playing on the source's device, with echo
        /// cancellation: it is turned down for anyone speaking, and can be cut off.
        var clientSpeaking = false
        /// Voice Operator speaking for a client (on the Mac): cut off by the
        /// trigger word too, and holding the window open.
        var voiceOperatorSpeaking = false
        /// The echo experiment (`EchoExperiment`): our own voice is playing, or
        /// ringing out, where the microphone hears it, and is listened through
        /// rather than stood aside for. Only the trigger word counts then, even
        /// in the conversation window; what matches what was just said is
        /// echo; nothing heard gets a cue.
        var throughEcho = false
    }

    // MARK: - Tunables beyond `HandsFreeTuning`

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
    /// Times in a row speech without the trigger word gets the `notWakeWord`
    /// cue before it goes quiet until the trigger word is said again.
    static let notWakeWordLimit = 3

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
    /// Why the listener stands aside, while it does.
    private var standingAside: StandAside?
    /// Listening through our own voice (`SourceState.throughEcho`), as of the last frame.
    private var throughEcho = false
    private var ducked = false
    private var speechRun = 0
    private var quietRun = 0
    private var shutdownWatch: (start: Int, frames: Int, quietFrames: Int)?
    /// `notWakeWord` cues due since the window last opened; past
    /// `notWakeWordLimit`, they are not played.
    private var notWakeWordRun = 0
    /// The dictation under way.
    private var utterance: Utterance?
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

    /// One pause in a dictation, as the record keeps it: what turn-1-mini made
    /// of it, and what came of it — they carried on (`resumed`), or it ended
    /// the dictation (`mini`, `silence`, …). The data that says where its
    /// threshold belongs on this user's speech.
    private struct PauseRecord {
        let talkMs: Int
        let wakeWordOnly: Bool
        /// Dictation audio when the pause was reported, in samples.
        let at: Int
        var miniAtPause: Double?
        var miniPeak: Double?
        /// When the peak was reached, ms into the pause.
        var miniPeakMs: Int?
        /// When turn-1-mini first reached its threshold, ms into the pause: when it would have ended the turn.
        var miniCrossedMs: Int?
    }

    private final class Utterance {
        let client: String
        let trigger: String?
        let dictation: Dictation
        let endpointer: UtteranceEndpointer
        let interrupted: Bool
        /// Samples dictated so far, the backlog included: where in the dictation a pause or an ending is.
        var samples: Int
        /// Wall ms of the first syllable (the backlog's start, not the check's answer).
        var startedAt: Double = 0
        var backstop: Timer?
        var ended = false
        /// turn-1-mini on this dictation, its latest answer, and its highest since the pause began.
        var mini: ContinuousTurn?
        var miniLatest: Double?
        var miniPeak: Double?
        /// The pause under way, for its line in the record once it ends.
        var pause: PauseRecord?
        /// turn-1-mini crossed its threshold in this silence: where (dictation audio, in samples), at
        /// what answer, how far into the quiet. The dictation ends `miniHoldMs` later unless they speak.
        var miniEnding: (at: Int, p: Double, quietMs: Double)?
        /// Endings cancelled by speech, in this dictation.
        var miniCancels = 0
        init(client: String, trigger: String?, dictation: Dictation, endpointer: UtteranceEndpointer,
             interrupted: Bool, samples: Int) {
            self.client = client
            self.trigger = trigger
            self.dictation = dictation
            self.endpointer = endpointer
            self.interrupted = interrupted
            self.samples = samples
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

    /// The client is talking to the user — its reply is starting — so the
    /// user may answer without the trigger word: the conversation window opens
    /// for it (or stays open), and closes as usual once both sides are quiet.
    func openConversation(by client: String) {
        guard live, triggers[client] != nil else { return }
        openConversation(for: client)
        publishState()
    }

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
        throughEcho = state.throughEcho
        trackPlayback(frame, speaking: state.clientSpeaking, echoing: state.throughEcho)
        tickConversation(state)
        if phase == .hearing, let utterance {
            utterance.dictation.append(frame.pcm)
            utterance.samples += frame.pcm.count
            feedMini(utterance, frame.pcm)
            for event in utterance.endpointer.push([frame]) {
                switch event {
                case .ended(let reason): end(reason == .silence ? .silence : .tooLong)
                case .resumed:
                    closePause(utterance, outcome: "resumed")
                    utterance.miniPeak = nil
                case .pause(let talkMs, let wakeWordOnly):
                    // The pause's line: what turn-1-mini says from here on.
                    utterance.pause = PauseRecord(talkMs: talkMs, wakeWordOnly: wakeWordOnly, at: utterance.samples,
                                                  miniAtPause: utterance.miniLatest, miniPeak: utterance.miniLatest,
                                                  miniPeakMs: utterance.miniLatest == nil ? nil : Int(tuning.pauseCheckMs))
                    utterance.miniPeak = utterance.miniLatest
                    if wakeWordOnly {
                        // "Control." and a breath: the turn model would call that finished. Wait for the rest.
                        deps.log("pause after the trigger word alone: waiting for the rest")
                    }
                }
                if self.utterance == nil { break }
            }
            if let utterance = self.utterance { checkMiniEnding(utterance) }
            publishGauge()
            return
        }
        guard phase == .listening else { return }
        if let deaf = state.deaf {
            // Deaf to the trigger word until this ends.
            if standingAside == nil { deps.record("stood-aside", ["why": deaf.why]) }
            standingAside = deaf.cause
            shutdownWatch = nil
            return
        }
        if standingAside != nil {
            standingAside = nil
            deps.record("listening-again", [:])
            listener.resume()
        }
        for candidate in listener.push([frame]) {
            // In the conversation window any words will do; otherwise they must start with a trigger word.
            // Through our own voice, only the trigger word: what leaks through is words too.
            let window = conversation && !state.throughEcho
            let throughEcho = state.throughEcho
            deps.log("speech after \(candidate.noSpeechBeforeMs)ms without speech — checking its start "
                     + (window ? "for words" : "for a trigger word"))
            let overVoice = state.clientSpeaking || state.voiceOperatorSpeaking
            checking += 1
            candidatesChecking += 1
            deps.check(candidate.clip) { [weak self] answer in
                self?.checked(candidate, window: window, overVoice: overVoice, throughEcho: throughEcho, answer: answer)
            }
        }
        watchForShutdown()
    }

    private func checked(_ candidate: WakeCandidate, window: Bool, overVoice: Bool, throughEcho: Bool = false,
                         answer: CheckAnswer) {
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
        var match = window ? verdict.words : client != nil
        var echoRejected = false
        if match, throughEcho, deps.isEcho(heard) {
            echoRejected = true
            deps.log("\"\(heard)\" is what our own voice just said: echo, not the user")
            deps.record("echo-rejected", ["heard": heard])
            match = false
        }
        deps.log(match
            ? (window ? "words, in the conversation window: dictating from its start"
                      : "it starts with \"\(verdict.trigger ?? "")\": dictating from its start")
            : (window ? "not words (a cough, filler, nothing)" : "not a trigger word"))
        var checkDetail: [String: Any] = ["match": match, "mode": window ? "speech" : "wake-word",
                                          "wakeWord": verdict.trigger != nil, "noSpeechBeforeMs": candidate.noSpeechBeforeMs,
                                          "spokeMs": candidate.spokeMs, "overVoice": overVoice]
        if throughEcho { checkDetail["throughEcho"] = true }
        deps.record("check", checkDetail)
        if !match, !window, phase == .listening, live {
            emit(nil, .notTrigger(heard: heard, throughEcho: throughEcho, echo: echoRejected))
        }
        // Through our own voice, nothing that was not for the client gets a cue: it was most likely that voice.
        if !match, !window, phase == .listening, live, !throughEcho {
            if verdict.shutdown != nil {
                // Perhaps "let me turn this off", which needs no trigger word: wait for it to end, then check the whole of it.
                deps.log("it may be \"let me turn this off\": checking the whole of it once it ends")
                shutdownWatch = (start: candidate.start, frames: 0, quietFrames: 0)
            } else {
                notAddressed()
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
            if throughEcho { detail["throughEcho"] = true }
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
                                  interrupted: interrupted, samples: backlog.count)
        utterance.startedAt = deps.now() - backlogMs
        recordStart(utterance)
        utterance.mini = deps.continuousTurn()
        feedMini(utterance, backlog)
        self.utterance = utterance
        utterance.backstop = deps.after(tuning.maxUtteranceMs + 10_000) { [weak self, weak utterance] in
            guard let self, let utterance, self.utterance === utterance else { return }
            self.end(.lost)
        }
        publishGauge()
    }

    /// `mini`: turn-1-mini said they had finished, and they stayed quiet `miniHoldMs`.
    private enum EndReason: String { case mini, silence, tooLong = "too-long", lost }

    /// After turn-1-mini first reaches its threshold in a silence, how long the
    /// quiet must go on before the dictation ends: speech in it cancels the ending.
    static let miniHoldMs: Double = 500

    private func end(_ reason: EndReason) {
        guard let utterance, !utterance.ended else { return }
        utterance.ended = true
        utterance.backstop?.cancel()
        closePause(utterance, outcome: reason.rawValue)
        self.utterance = nil
        emit(utterance.client, .cue(.dictationEnd))
        // When the speech itself ended: the quiet that ended it is not part of it.
        let speechEndedAt = deps.now() - utterance.endpointer.quietMs
        deps.record("ended", ["reason": reason.rawValue, "client": utterance.client,
                              "startedAt": Self.iso(utterance.startedAt), "speechEndedAt": Self.iso(speechEndedAt),
                              "speechMs": Int(speechEndedAt - utterance.startedAt)])
        lastDictation = (speechEndedAt, reason.rawValue)
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
                if HandsFreePhrases.isStopListening(text, trigger: trigger) {
                    self.stopListening(utterance, reason: reason)
                    self.finishedDictation()
                    return
                }
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

    /// Feed turn-1-mini the dictation's audio; keep its latest answer, and its
    /// highest since the pause began. A model that fails is dropped for the
    /// rest of the dictation.
    private func feedMini(_ utterance: Utterance, _ pcm: [Int16]) {
        guard let mini = utterance.mini, !pcm.isEmpty else { return }
        let probs: [Float]
        do { probs = try mini.push(pcm) } catch {
            deps.log("turn-1-mini failed: \(error)")
            utterance.mini = nil
            return
        }
        guard let last = probs.last else { return }
        utterance.miniLatest = Double(last)
        // The first frame at or over its threshold in this pause, timed to its own 20 ms frame.
        if var pause = utterance.pause, pause.miniCrossedMs == nil,
           let i = probs.firstIndex(where: { Double($0) >= TurnOneMini.threshold }) {
            let endMs = HandsFreeAudio.ms(samples: utterance.samples - pause.at) + tuning.pauseCheckMs
            pause.miniCrossedMs = max(0, Int(endMs) - (probs.count - 1 - i) * 20)
            utterance.pause = pause
        }
        if utterance.pause != nil, let top = probs.max().map(Double.init), top > (utterance.miniPeak ?? -1) {
            utterance.miniPeak = top
            if var pause = utterance.pause {
                pause.miniPeak = top
                pause.miniPeakMs = Int(HandsFreeAudio.ms(samples: utterance.samples - pause.at)) + Int(tuning.pauseCheckMs)
                utterance.pause = pause
            }
        }
    }

    /// The last dictation's end, for the next one's `started` line.
    private var lastDictation: (speechEndedAt: Double, endedBy: String)?

    /// A dictation's first syllable, and how soon after the last one's speech
    /// ended — a gap of a second or two after one turn-1-mini ended (`mini`)
    /// says it ended the turn too early: they had not finished.
    private func recordStart(_ utterance: Utterance) {
        var detail: [String: Any] = ["client": utterance.client, "startedAt": Self.iso(utterance.startedAt),
                                     "backlogMs": Int(HandsFreeAudio.ms(samples: utterance.samples))]
        if let last = lastDictation {
            detail["gapFromPreviousMs"] = Int(utterance.startedAt - last.speechEndedAt)
            detail["previousEndedBy"] = last.endedBy
        }
        deps.record("started", detail)
    }

    private static func iso(_ ms: Double) -> String {
        ISO8601DateFormatter.withFractions.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    /// turn-1-mini decides when the dictation ends: the first time in a silence
    /// its answer reaches its threshold (`TurnOneMini.threshold`; 0.5 on trial
    /// for now), the dictation ends `miniHoldMs` later — unless speech comes back
    /// first, which cancels the ending and listening goes on. After the trigger
    /// word alone the ending waits: "Control." and a breath is not the end.
    /// The silence timeout stays the fallback. Every crossing, ending and
    /// cancellation is recorded (`mini-ending`).
    private func checkMiniEnding(_ utterance: Utterance) {
        let quiet = utterance.endpointer.quietMs
        if let ending = utterance.miniEnding {
            let heldMs = HandsFreeAudio.ms(samples: utterance.samples - ending.at)
            if quiet == 0 {
                utterance.miniEnding = nil
                utterance.miniCancels += 1
                deps.log(String(format: "turn-1-mini's ending cancelled: speech again %.0f ms after it crossed", heldMs))
                deps.record("mini-ending", ["outcome": "cancelled", "p": ending.p, "crossedAtQuietMs": Int(ending.quietMs),
                                            "afterMs": Int(heldMs)])
            } else if heldMs >= Self.miniHoldMs {
                if utterance.pause?.wakeWordOnly == true { return }
                deps.log(String(format: "turn-1-mini: finished (%.2f at %.0f ms of quiet, held %.0f ms)",
                                ending.p, ending.quietMs, heldMs))
                deps.record("mini-ending", ["outcome": "ended", "p": ending.p, "crossedAtQuietMs": Int(ending.quietMs),
                                            "afterMs": Int(heldMs), "cancelledBefore": utterance.miniCancels])
                end(.mini)
            }
        } else if quiet > 0, let p = utterance.miniLatest, p >= TurnOneMini.threshold {
            utterance.miniEnding = (utterance.samples, p, quiet)
            deps.log(String(format: "turn-1-mini crossed %.2f (%.2f) %.0f ms into the quiet: ending in %.0f ms unless they speak",
                            TurnOneMini.threshold, p, quiet, Self.miniHoldMs))
            deps.record("mini-ending", ["outcome": "crossed", "p": p, "crossedAtQuietMs": Int(quiet)])
        }
    }

    /// The pause is over — they carried on, or the dictation ended: its line in the record.
    private func closePause(_ utterance: Utterance, outcome: String) {
        guard let pause = utterance.pause else { return }
        utterance.pause = nil
        var detail: [String: Any] = [
            "talkMs": pause.talkMs, "outcome": outcome, "wakeWordOnly": pause.wakeWordOnly,
            "silenceMs": Int(HandsFreeAudio.ms(samples: utterance.samples - pause.at)) + Int(tuning.pauseCheckMs),
            "miniThreshold": TurnOneMini.threshold,
        ]
        if let p = pause.miniAtPause { detail["miniAtPause"] = p }
        if let p = pause.miniPeak { detail["miniPeak"] = p }
        if let ms = pause.miniPeakMs { detail["miniPeakMs"] = ms }
        if let ms = pause.miniCrossedMs { detail["miniCrossedMs"] = ms }
        deps.record("pause", detail)
    }

    // MARK: - The conversation window

    private func openConversation(for client: String) {
        notWakeWordRun = 0
        silentFrames = 0
        closesAt = nil
        conversationClient = client
        guard !conversation else { return }
        conversation = true
        listener.setConversation(true)
        deps.log("conversation window open: no need for the trigger word until both sides have been quiet a while")
        deps.record("conversation", ["open": true])
    }

    /// `silence`: it ran out, and `stop-listening`: as if it had, with a cue.
    /// `shutdown`: a shutdown phrase, with its own. The source going (`source`)
    /// or the client leaving close it quietly.
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
        else if why == "silence" || why == "stop-listening" { emit(client, .cue(.conversationClosed)) }
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

    /// "Stop listening", dictated: the window closes as if it had run out, and
    /// speech without the trigger word gets no cue at all until it is said again.
    /// The client gets no words — it waits for a dictation's, so it is told there
    /// were none — and a voice it cut off stays cut off.
    private func stopListening(_ utterance: Utterance, reason: EndReason) {
        deps.log("\"stop listening\": the trigger word again from here, and no cue for speech without it")
        deps.record("stop-listening", ["client": utterance.client])
        emit(utterance.client, .transcript(text: "", trigger: utterance.trigger, interrupted: false,
                                           reason: reason.rawValue, shutdown: false))
        if conversation { closeConversation(why: "stop-listening") } else { emit(utterance.client, .cue(.conversationClosed)) }
        notWakeWordRun = Self.notWakeWordLimit
    }

    /// Speech that needed the trigger word did not start with it: the cue, the
    /// first `notWakeWordLimit` times in a row.
    private func notAddressed() {
        notWakeWordRun += 1
        deps.record("not-wake-word", ["run": notWakeWordRun, "cued": notWakeWordRun <= Self.notWakeWordLimit])
        guard notWakeWordRun <= Self.notWakeWordLimit else { return }
        if notWakeWordRun == Self.notWakeWordLimit {
            deps.log("\(Self.notWakeWordLimit) in a row without the trigger word: no cue for more until it is said")
        }
        emit(nil, .cue(.notWakeWord))
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
            notAddressed()
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
                if self.phase == .listening, self.live { self.notAddressed() }
                self.unduckIfDone()
            }
            self.publishState()
        }
    }

    // MARK: - The client's voice

    /// Every frame while the client's voice plays with echo cancellation:
    /// anyone speaking turns it down at once, and quiet brings it back once no
    /// check is pending. `echoing`: listening through our own voice
    /// (`SourceState.throughEcho`) — recorded as a reply's echo, and turned down
    /// only if it is the client's (`speaking`).
    private func trackPlayback(_ frame: ScoredFrame, speaking: Bool, echoing: Bool = false) {
        guard speaking || echoing else {
            if let echo { recordEcho(echo) }
            echo = nil
            setDuck(false)
            speechRun = 0
            quietRun = 0
            return
        }
        if echoing, echo == nil { echo = Echo(throughEcho: true) }
        guard speaking else {
            setDuck(false)
            speechRun = 0
            quietRun = 0
            noteEcho(frame)
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
        /// Heard through the echo experiment, not a headset's or the phone's own cancellation alone.
        var throughEcho = false
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
        if e.throughEcho { detail["throughEcho"] = true }
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
        let pending = phase == .listening && live && standingAside == nil && !conversation && !throughEcho
            && (listener.undecided || candidatesChecking > 0)
        let state = Event.state(phase: phase, conversation: conversation, closesAt: closesAt,
                                checking: checking > 0, pending: pending,
                                standingAside: phase == .listening && live ? standingAside : nil)
        guard state != lastState else { return }
        lastState = state
        emit(nil, state)
    }

    /// The gauge, sent only when a data point changed: the quiet starting or
    /// ending, the patience moving by more than a frame's worth, a turn answer.
    private func publishGauge(keepingTurn ended: Utterance? = nil) {
        /// To two places: the client draws it, it need not hear every flicker.
        func round(_ p: Double?) -> Double? { p.map { ($0 * 100).rounded() / 100 } }
        var gauge = Gauge()
        if let utterance {
            let quiet = utterance.endpointer.quietMs
            gauge.quietSince = quiet > 0 ? (deps.now() - quiet).rounded() : nil
            gauge.patienceMs = utterance.endpointer.patienceMs.rounded()
            gauge.mini = round(utterance.miniLatest)
            gauge.miniPeak = round(utterance.miniPeak)
            if case .gauge(let last)? = lastGauge,
               (last.quietSince == nil) == (gauge.quietSince == nil),
               last.mini == gauge.mini, last.miniPeak == gauge.miniPeak,
               abs((last.patienceMs ?? 0) - (gauge.patienceMs ?? 0)) < HandsFreeAudio.frameMs * 4 {
                return
            }
        } else if let ended {
            // Sending: what ended it stays shown.
            gauge.mini = round(ended.miniLatest)
            gauge.miniPeak = round(ended.miniPeak)
        }
        let event = Event.gauge(gauge)
        guard event != lastGauge else { return }
        lastGauge = event
        emit(utterance?.client ?? ended?.client ?? owner, event)
    }

    private func emit(_ client: String?, _ event: Event) {
        deps.emit(Outgoing(client: client, event: event))
    }
}
