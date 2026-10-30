import Foundation

/// Claude Code's voice mode: hands-free locked to one Claude Code session, so
/// the user can talk with that one agent while the terminal is out of sight.
/// The Claude Code side is the `handsfree` plugin (`claude-plugin/handsfree`),
/// a mod whose hooks call `/v1/voice-mode/…` (DESIGN.md "Claude Code voice mode").
///
/// It is a hands-free client like Spaceterm, but one inside this app
/// (`HandsFreeService.registerLocal`), with the trigger word "claude" by
/// default. Attaching takes the Mac's microphone from whoever had it — Spaceterm,
/// usually — and Spaceterm taking it back detaches.
///
/// The conversation:
///
/// - **The agent works** (`setWorking`): a soft sonar, until its turn ends.
/// - **The agent's turn ends** (`turnEnded`): its answer is spoken, and the mod
///   waits on `next` for what the user says, which it submits as their prompt.
/// - **The user speaks** (a hands-free `transcript`): the words, trigger word
///   off, go to the poll waiting on `next`, or wait in `inbox` for one — or for
///   the mod's next tool result to hand them over mid-turn (`midTurn`).
/// - **The user talks over the reply**: hands-free cuts it off (`cut-in`),
///   and the agent is told how far they had heard.
///
/// It detaches when asked (`/handsfree off`, the agent's `stop` tool, the menu),
/// when the session ends (or its `claude` process is gone), when another session
/// attaches, when hands-free ends under it (Spaceterm takes the microphone,
/// "let me turn this off", incognito), but not when this app restarts: the
/// attachment is saved, and picked up again at launch.
@MainActor
final class VoiceMode {
    static let shared = VoiceMode()
    nonisolated static let clientName = "claude-code"
    nonisolated static let defaultTrigger = "claude"
    /// What the user says goes to Claude, off this Mac.
    static let incognitoActivity = Incognito.Activity.network("Claude Code voice mode")
    nonisolated static let stateURL = HistoryStore.supportDir.appendingPathComponent("voice-mode.json")

    struct Attachment: Codable, Equatable {
        var sessionID: String
        /// The session's `claude` process; 0 when the plugin could not find it.
        var claudePID: Int32
        var cwd: String
        var trigger: String
        var voice: String?
        var attachedAt: Date
        /// Counts the session's turns: a `Stop` hook waits for the user under
        /// its turn's number, so a later turn's hook replaces it.
        var generation: Int

        var project: String { URL(fileURLWithPath: cwd).lastPathComponent }

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id", claudePID = "claude_pid", cwd, trigger, voice
            case attachedAt = "attached_at", generation
        }
    }

    /// Why it detached, for the log, the menu, and the session's next prompt.
    enum Detach: Equatable {
        /// `/handsfree off`, the agent's `stop` tool: the session knows already.
        case asked
        case menu
        case sessionEnded
        case replaced(by: String)
        case taken(by: String)
        case shutdown
        case incognito
        case handsFree(String)

        var description: String {
            switch self {
            case .asked: return "asked to"
            case .menu: return "turned off from Voice Operator's menu"
            case .sessionEnded: return "the session ended"
            case .replaced(let project): return "another Claude Code session (\(project)) took voice mode"
            case .taken(let by): return by == "spaceterm" ? "Spaceterm took hands-free back" : "\(by) took hands-free"
            case .shutdown: return "the user turned it off by voice"
            case .incognito: return "incognito mode turned on"
            case .handsFree(let why): return "hands-free ended (\(why))"
            }
        }
    }

    /// What it uses of the rest of the app, replaced in the tests.
    @MainActor
    struct Deps {
        var registerHandsFree: (_ trigger: String, _ link: HandsFreeClientLink) -> HandsFreeService.Refusal?
        var setHandsFree: (_ on: Bool) -> Void
        var unregisterHandsFree: () -> Void
        /// Our voice is about to speak: the user may answer without the trigger word.
        var openConversation: () -> Void = {}
        /// Speak `text` in `voice`; the speech job's id, or nil.
        var speak: (_ text: String, _ voice: String) async -> String?
        /// Stop job `id`, heard until then; how far into its text it got (UTF-16).
        var cancelSpeech: (_ id: String, _ heardUntil: Date?) async -> Int?
        var playCue: (SoundEffect) -> Void
        /// Voice Operator is speaking (anyone's speech): the sonar holds off.
        var isSpeaking: () -> Bool = { false }
        var stopCue: (SoundEffect) -> Void
        var pidAlive: (Int32) -> Bool
        var save: (Attachment?) -> Void
        var now: () -> Date = Date.init

        static var live: Deps { Deps(
            registerHandsFree: { trigger, link in
                HandsFreeService.shared.registerLocal(VoiceMode.clientName, trigger: trigger, link: link)
            },
            setHandsFree: { HandsFreeService.shared.setLocal(VoiceMode.clientName, on: $0) },
            unregisterHandsFree: { HandsFreeService.shared.unregisterLocal(VoiceMode.clientName) },
            openConversation: { HandsFreeService.shared.openConversationLocal(VoiceMode.clientName) },
            speak: { text, voice in
                guard let result = await SpeechJobManager.shared.enqueue(parts: [.init(text: text, voice: voice)]),
                      result.error == nil else { return nil }
                return result.id
            },
            cancelSpeech: { id, heardUntil in
                await SpeechJobManager.shared.cancel(id: id, heardUntil: heardUntil)?.characterOffset
            },
            playCue: { $0.play() },
            isSpeaking: { HandsFreeService.shared.host.speaking },
            stopCue: { $0.stop() },
            pidAlive: { pid in kill(pid, 0) == 0 || errno == EPERM },
            save: { attachment in
                if let attachment, let data = try? VoiceMode.encoder.encode(attachment) {
                    try? data.write(to: VoiceMode.stateURL, options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: VoiceMode.stateURL)
                }
            }) }
    }

    private(set) var attachment: Attachment?
    /// Hands-free as it last said: for `/v1/status`, the menu, and the pending beep.
    private(set) var phase = "off"
    /// The conversation window is open: the user may talk without the trigger word.
    private(set) var conversation = false
    /// Why hands-free is not listening just now (`speech`, `sound`, `dictation`), or nil.
    private(set) var standingAside: String?
    /// Goes up whenever what `status` says of the conversation changes: `watch` waits on it.
    private(set) var version = 0
    private(set) var route: String?
    /// What the user said that no hook has taken yet, oldest first.
    private(set) var inbox: [Heard] = []

    struct Heard: Equatable {
        /// Their words, trigger word off; empty when they talked over the reply and nothing was caught.
        var said: String
        var interrupted: Bool
        /// How far they had heard the reply they talked over.
        var heard: String?

        func message(whileWorking: Bool) -> String {
            whileWorking ? VoiceModeText.midTurn(said: said, interrupted: interrupted, heard: heard)
                : VoiceModeText.prompt(said: said, interrupted: interrupted, heard: heard)
        }
    }
    /// Why a session was detached under it, for its next prompt: it may still think it is being heard.
    private var notices: [String: String] = [:]
    /// The replies spoken lately, oldest first: their jobs and words, for a cut-in.
    private var speaking: [(job: String, text: String)] = []
    /// What the user had heard of the reply they last cut off.
    private var heardBeforeCutIn: String?
    private var cutInPending = false
    private var pendingBeep: Task<Void, Never>?
    /// The sonar, while the session's main thread works (`setWorking`).
    private var sonar: Task<Void, Never>?
    /// Spaceterm's thinking cue: the first echo after 1.5 s, then one every 2.5 s.
    var sonarTiming: (delay: Duration, every: Duration) = (.milliseconds(1_500), .milliseconds(2_500))
    private var watch: Task<Void, Never>?
    private let link = Link()
    var deps: Deps
    /// Called on the main actor whenever the attachment changes: the menu.
    var onChange: (() -> Void)?

    nonisolated(unsafe) static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    init(deps: Deps? = nil) {
        self.deps = deps ?? .live
        link.deliver = { [weak self] message in self?.handsFree(message) }
    }

    // MARK: - Attach and detach

    enum AttachError: Error, Equatable {
        case incognito(String)
        case refused(HandsFreeService.Refusal)
    }

    /// Lock hands-free to session `sessionID`, taking it from whatever had it.
    /// The same session attaching again keeps its place (a new trigger word or
    /// voice takes effect); another session replaces it.
    func attach(sessionID: String, claudePID: Int32, cwd: String, trigger: String?, voice: String?) throws -> Attachment {
        if let blocked = Incognito.refusal(Self.incognitoActivity) { throw AttachError.incognito(blocked.description) }
        let trigger = trigger.map { HandsFreePhrases.spokenWords($0).joined(separator: " ") }
            .flatMap { $0.isEmpty ? nil : $0 } ?? attachment?.trigger ?? Self.defaultTrigger
        if let current = attachment, current.sessionID != sessionID {
            detach(.replaced(by: URL(fileURLWithPath: cwd).lastPathComponent))
        }
        if let current = attachment, current.trigger == trigger {
            attachment?.voice = voice ?? current.voice
            attachment?.claudePID = claudePID
            deps.save(attachment)
            deps.setHandsFree(true)   // Spaceterm may have it: take it back.
            return attachment!
        }
        deps.unregisterHandsFree()
        if let refusal = deps.registerHandsFree(trigger, link) { throw AttachError.refused(refusal) }
        let generation = attachment?.generation ?? 0
        attachment = Attachment(sessionID: sessionID, claudePID: claudePID, cwd: cwd, trigger: trigger,
                                voice: voice ?? attachment?.voice, attachedAt: deps.now(), generation: generation)
        notices[sessionID] = nil
        inbox = []
        deps.save(attachment)
        deps.setHandsFree(true)
        Log.log("voice mode: attached to \(attachment!.project) (session \(sessionID), pid \(claudePID)), trigger \"\(trigger)\"")
        watchSession()
        version += 1
        onChange?()
        return attachment!
    }

    /// Let go: hands-free off, and the trigger word with it.
    func detach(_ why: Detach) {
        guard let current = attachment else { return }
        attachment = nil
        inbox = []
        phase = "off"
        conversation = false
        standingAside = nil
        setPendingBeep(false)
        setWorking(false)
        watch?.cancel()
        watch = nil
        switch why {
        case .asked, .sessionEnded: break
        default: notices[current.sessionID] = "[Hands-free] Hands-free was turned off: \(why.description). "
            + "Your replies are no longer spoken; answer in text as usual."
        }
        speaking = []
        deps.unregisterHandsFree()
        deps.save(nil)
        Log.log("voice mode: detached from \(current.project) — \(why.description)")
        version += 1
        onChange?()
    }

    /// Picked up again after this app restarts, if the session is still there.
    func restore(_ saved: Attachment?) {
        guard let saved, attachment == nil else { return }
        guard saved.claudePID == 0 || deps.pidAlive(saved.claudePID) else {
            Log.log("voice mode: \(saved.project)'s session ended while Voice Operator was away")
            deps.save(nil)
            return
        }
        do {
            let restored = try attach(sessionID: saved.sessionID, claudePID: saved.claudePID, cwd: saved.cwd,
                                      trigger: saved.trigger, voice: saved.voice)
            attachment?.generation = saved.generation
            attachment?.attachedAt = saved.attachedAt
            deps.save(attachment)
            Log.log("voice mode: picked up \(restored.project) again after the restart")
        } catch {
            Log.log("voice mode: could not pick up \(saved.project) again: \(error)")
            deps.save(nil)
        }
    }

    nonisolated static func loadSaved() -> Attachment? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Attachment.self, from: data)
    }

    /// Detaches once the session's `claude` process is gone: a crash, or a
    /// terminal closed, sends no `SessionEnd`.
    private func watchSession() {
        watch?.cancel()
        guard let pid = attachment?.claudePID, pid > 0 else { return }
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled, self.attachment?.claudePID == pid else { return }
                if !self.deps.pidAlive(pid) { self.detach(.sessionEnded); return }
            }
        }
    }

    func isAttached(_ sessionID: String?) -> Bool {
        sessionID != nil && attachment?.sessionID == sessionID
    }

    // MARK: - Hooks

    /// `Stop`: speak the reply, and begin turn `generation` — the number the
    /// hook waits for the user under. Nil when this session is not attached.
    func turnEnded(_ input: VoiceModeHookInput) async -> Int? {
        guard isAttached(input.sessionID) else { return nil }
        setWorking(false)
        attachment?.generation += 1
        let generation = attachment!.generation
        deps.save(attachment)
        var reply = input.lastAssistantMessage
        if reply == nil, let path = input.transcriptPath, let transcript = try? String(contentsOfFile: path, encoding: .utf8) {
            reply = VoiceModeHookInput.lastAssistantText(transcript: transcript)
        }
        if let reply { await speak(reply) }
        return generation
    }

    enum Next: Equatable {
        case message(String)
        case nothingYet
        /// Stop waiting: detached, another session's, or a later turn's hook waits now.
        case gone(String)
    }

    /// What the user said next, for the `Stop` hook of turn `generation`:
    /// at once if something is waiting, or the first thing said within `wait`.
    func next(sessionID: String, generation: Int, wait: Duration) async -> Next {
        let deadline = ContinuousClock.now + wait
        while true {
            guard let current = attachment, current.sessionID == sessionID else { return .gone("not_attached") }
            guard current.generation == generation else { return .gone("superseded") }
            if let message = takeInbox(whileWorking: false) { return .message(message) }
            if ContinuousClock.now >= deadline { return .nothingYet }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Mid-turn (the mod's `tool.call` hook): what the user said while the agent works, in a `PostToolUse` hook's shape.
    func midTurn(_ input: VoiceModeHookInput) -> [String: Any]? {
        guard isAttached(input.sessionID), let message = takeInbox(whileWorking: true) else { return nil }
        return ["hookSpecificOutput": ["hookEventName": "PostToolUse", "additionalContext": message]]
    }

    /// `UserPromptSubmit`: they typed. Anything said meanwhile, or that voice
    /// mode was turned off under the session, goes with what they typed.
    func promptSubmitted(_ input: VoiceModeHookInput) -> String? {
        guard let session = input.sessionID else { return nil }
        if let notice = notices.removeValue(forKey: session) { return notice }
        guard isAttached(session) else { return nil }
        return takeInbox(whileWorking: false)
    }

    /// `SessionStart` after a compaction, a resume or `/clear`: whether this
    /// session is (still) attached, so the plugin hands the agent its voice-mode
    /// instructions again. `/clear` starts a new session id in the same process:
    /// the attachment follows it.
    func sessionStarted(_ input: VoiceModeHookInput) -> Attachment? {
        guard let session = input.sessionID, let current = attachment else { return nil }
        if current.sessionID != session, input.source == "clear", let pid = input.claudePID,
           current.claudePID != 0, pid == current.claudePID {
            Log.log("voice mode: /clear in \(current.project) — following the new session \(session)")
            attachment?.sessionID = session
            deps.save(attachment)
            version += 1
        onChange?()
        }
        return isAttached(session) ? attachment : nil
    }

    /// `SessionEnd`. `/clear` ends a session only to start another in the same
    /// process, which `sessionStarted` follows.
    func sessionEnded(_ input: VoiceModeHookInput) {
        guard isAttached(input.sessionID), input.reason != "clear" else { return }
        detach(.sessionEnded)
    }

    /// `Notification`: Claude Code wants the user at the terminal — a permission
    /// prompt — which they cannot see. Said aloud.
    func notified(_ input: VoiceModeHookInput) async {
        guard isAttached(input.sessionID), let message = input.message, !message.isEmpty,
              input.notificationType != "idle_prompt" else { return }
        await speak("\(attachment?.project ?? "Claude") needs you at the terminal. \(message)")
    }

    /// The session's main thread started (true) or finished (false) a turn: a
    /// soft sonar plays while it works, so the user knows it heard them and is
    /// on it. It holds off while anyone speaks and while the user talks, and
    /// stops at the turn's end (`turnEnded`) or on detach.
    func setWorking(sessionID: String, _ on: Bool) -> Bool {
        guard isAttached(sessionID) else { return false }
        setWorking(on)
        return true
    }

    private func setWorking(_ on: Bool) {
        guard on != (sonar != nil) else { return }
        version += 1
        sonar?.cancel()
        sonar = nil
        guard on else { deps.stopCue(.handsFreeSonar); return }
        let timing = sonarTiming
        sonar = Task { [weak self] in
            try? await Task.sleep(for: timing.delay)
            while !Task.isCancelled {
                guard let self else { return }
                // Not reported as `playing`: hands-free listens through it, even on speakers,
                // since its speech detector does not take a tone for speech.
                if self.phase == "listening", !self.deps.isSpeaking() {
                    self.deps.playCue(.handsFreeSonar)
                }
                try? await Task.sleep(for: timing.every)
            }
        }
    }

    var isWorking: Bool { sonar != nil }

    /// The agent's `say` tool: a word now, mid-turn, without waiting for the turn to end.
    func say(sessionID: String, text: String) async -> Bool {
        guard isAttached(sessionID) else { return false }
        await speak(text)
        return true
    }

    /// A transcript as if hands-free had heard it — for testing the plugin end
    /// to end without speaking (`POST /v1/voice-mode/simulate`). Only for the
    /// session the test attached: if the user's own session took hands-free
    /// meanwhile, a test's words must not land there.
    func simulate(sessionID: String, _ text: String) -> Bool {
        guard isAttached(sessionID) else { return false }
        heard(text: text, trigger: nil, interrupted: false)
        return true
    }

    // MARK: - Speech

    private func speak(_ markdown: String) async {
        let text = VoiceModeText.spoken(markdown)
        guard !text.isEmpty else { return }
        let voice = attachment?.voice ?? KokoroSynthesizer.defaultVoiceID
        // The agent took longer than the window lasts, most turns: its answer opens it again.
        deps.openConversation()
        guard let job = await deps.speak(text, voice) else {
            Log.log("voice mode: the reply could not be spoken (muted, or speech unavailable)")
            return
        }
        speaking = Array((speaking + [(job, text)]).suffix(3))
    }

    /// The user talked over our voice from `at`: every reply of ours still
    /// playing or queued stops, and the one they were hearing says how far they got.
    private func cutIn(at: Date) {
        guard !speaking.isEmpty else { return }
        let jobs = speaking
        speaking = []
        cutInPending = true
        Task {
            var heard: String?
            for (job, text) in jobs {
                let length = (text as NSString).length
                guard let offset = await deps.cancelSpeech(job, at) else { continue }
                if heard == nil, offset < length { heard = (text as NSString).substring(to: max(0, offset)) }
            }
            heardBeforeCutIn = heard.map { VoiceModeText.tail($0) }
            cutInPending = false
        }
    }

    // MARK: - Hands-free

    private func takeInbox(whileWorking: Bool) -> String? {
        guard !inbox.isEmpty else { return nil }
        if Incognito.refusal(Self.incognitoActivity) != nil {
            inbox = []
            return nil
        }
        defer { inbox = [] }
        return inbox.map { $0.message(whileWorking: whileWorking) }.joined(separator: "\n\n")
    }

    private func heard(text: String, trigger: String?, interrupted: Bool) {
        let said = VoiceModeText.withoutTrigger(text, trigger: trigger ?? attachment?.trigger)
        let heard = interrupted ? heardBeforeCutIn : nil
        if interrupted { heardBeforeCutIn = nil }
        guard !said.isEmpty || interrupted else { return }
        inbox.append(Heard(said: said, interrupted: interrupted, heard: heard))
        Log.log("voice mode: heard \(said.count) chars\(interrupted ? " (over the reply)" : "") for \(attachment?.project ?? "?")")
    }

    /// One of hands-free's messages to this client (DESIGN.md "Hands-free", protocol).
    func handsFree(_ message: [String: Any]) {
        guard attachment != nil else { return }
        switch message["type"] as? String {
        case "state":
            let before = (phase, conversation, standingAside)
            phase = message["phase"] as? String ?? "off"
            conversation = message["conversation"] as? Bool == true
            standingAside = message["standingAside"] as? String
            if before != (phase, conversation, standingAside) { version += 1 }
            setPendingBeep(message["pending"] as? Bool == true)
        case "cue":
            setPendingBeep(false)
            if let effect = (message["name"] as? String).flatMap(Self.cue) {
                link.played(effect.duration)
                deps.playCue(effect)
            }
        case "cut-in":
            let at = (message["at"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            cutIn(at: at ?? deps.now())
        case "transcript":
            let text = message["text"] as? String ?? ""
            let interrupted = message["interrupted"] as? Bool == true
            if message["shutdown"] as? Bool == true { return }   // session-ended {shutdown} follows
            if interrupted, cutInPending {
                // The cut-in's answer is not back yet: let it land first.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    self.heard(text: text, trigger: message["trigger"] as? String, interrupted: true)
                }
                return
            }
            heard(text: text, trigger: message["trigger"] as? String, interrupted: interrupted)
        case "setup":
            route = message["route"] as? String
        case "session-ended":
            let why = message["why"] as? String ?? "off"
            switch why {
            case "restarting", "off": return   // this app quitting; or asked by us
            case "taken": detach(.taken(by: message["by"] as? String ?? "another app"))
            case "shutdown": detach(.shutdown)
            case "incognito": detach(.incognito)
            default: detach(.handsFree(why))
            }
        default:
            break   // `session`, `gauge`, `duck`: nothing to do here
        }
    }

    static func cue(_ name: String) -> SoundEffect? {
        switch name {
        case "ready": return .handsFreeReady
        case "dictationStart": return .handsFreeDictationStart
        case "dictationEnd": return .handsFreeDictationEnd
        case "notWakeWord": return .handsFreeNotWakeWord
        case "conversationClosed": return .handsFreeConversationClosed
        case "shutdown": return .handsFreeShutdown
        case "error": return .transcriptionFailed
        default: return nil
        }
    }

    /// The "deciding" beep, repeated while speech that needs the trigger word is undecided.
    private func setPendingBeep(_ on: Bool) {
        guard on != (pendingBeep != nil) else { return }
        pendingBeep?.cancel()
        pendingBeep = nil
        guard on else { deps.stopCue(.handsFreePending); return }
        pendingBeep = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.link.played(SoundEffect.handsFreePending.duration)
                self.deps.playCue(.handsFreePending)
                try? await Task.sleep(for: .seconds(SoundEffect.handsFreePending.duration))
            }
        }
    }

    // MARK: - Status

    var status: [String: Any] {
        guard let a = attachment else { return ["attached": false, "version": version] }
        var o: [String: Any] = ["attached": true, "version": version, "conversation": conversation,
                                "session_id": a.sessionID, "project": a.project, "cwd": a.cwd,
                                "trigger": a.trigger, "claude_pid": Int(a.claudePID), "phase": phase,
                                "attached_at": ISO8601DateFormatter().string(from: a.attachedAt),
                                "waiting_messages": inbox.count, "generation": a.generation, "working": isWorking]
        if let route { o["route"] = route }
        if let voice = a.voice { o["voice"] = voice }
        if let standingAside { o["standing_aside"] = standingAside }
        return o
    }

    /// `status` once it differs from version `since`, or after `wait` regardless:
    /// what the plugin's band above the prompt draws from.
    func watch(since: Int, wait: Duration) async -> [String: Any] {
        let deadline = ContinuousClock.now + wait
        while version == since, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return status
    }

    /// For the menu: what it is attached to, or nil.
    var menuTitle: String? {
        attachment.map { "Claude Hands-Free: \($0.project) — say “\($0.trigger.capitalized)”" }
    }

    /// The link hands-free sends this client's messages through, on its queue.
    final class Link: HandsFreeClientLink, @unchecked Sendable {
        private let lock = NSLock()
        private var playingUntil = Date.distantPast
        /// Set once, before hands-free knows of this link.
        var deliver: (@MainActor ([String: Any]) -> Void)?

        func send(_ message: [String: Any]) {
            // JSON-shaped values only, so it crosses to the main actor as data.
            guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated {
                    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
                    deliver?(object)
                }
            }
        }

        /// A cue of `seconds` starts now: hands-free does not listen through it on speakers.
        func played(_ seconds: Double) {
            lock.withLock { playingUntil = max(playingUntil, Date().addingTimeInterval(seconds)) }
        }

        func isPlaying(tailMs: Double) -> Bool {
            lock.withLock { Date().timeIntervalSince(playingUntil) * 1000 < tailMs }
        }
    }
}
