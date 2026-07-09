import AppKit
import AVFoundation

/// Top-level wiring. Owns the menu bar, the trigger-key monitor, the audio
/// arbiter, and the Claude transcript watcher. Coordination logic lives in
/// `AudioArbiter`; this class constructs the pieces and connects their callbacks.
@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarController()
    private let arbiter = AudioArbiter()
    private let hotkey = HotkeyMonitor()
    private let registry = NameVoiceRegistry()   // shared: assignment + directed-reply lookup
    private var watcher: TranscriptWatcher?
    private var permissionWatcher: PermissionWatcher?
    private var lastSpeaking: Utterance?

    /// Accepted transcriptions of the "focus" verb (raises a spaceterm surface).
    private static let focusVerbs: Set<String> = ["focus", "focuses", "focused"]
    /// Accepted transcriptions of the "repeat" verb (re-plays the cached audio).
    private static let repeatVerbs: Set<String> = ["repeat", "repeats", "repeated"]
    /// Accepted transcriptions of the "skip" verb (drops the clip that was
    /// playing when this command began, so playback advances to the next update).
    private static let skipVerbs: Set<String> = ["skip", "skips", "skipped"]
    /// Accepted transcriptions of the "ask" verb (question the low-context Haiku
    /// summarizer about an update; everything after the verb is the spoken
    /// message). Distinct from a future "send" verb that would push a message to
    /// the real Claude Code session — "ask" is read-only, "send" would mutate.
    private static let askVerbs: Set<String> = ["ask", "asks", "asked"]

    /// Every word that can BEGIN a command. Grammar is name-first
    /// ("[name] <command> [args]"), so a leading token that isn't one of these is
    /// treated as the call-sign to address.
    private static let commandHeads: Set<String> =
        focusVerbs.union(repeatVerbs).union(skipVerbs).union(askVerbs).union(["more"])

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.log("Voice Operator launching")
        LaunchAtLogin.enableByDefaultOnce()   // start at login (first run only)
        // Explicitly request microphone access so the TCC prompt reliably
        // appears (AVAudioEngine alone doesn't always trigger it).
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Log.log("mic access request → granted=\(granted)")
        }
        arbiter.onStatus = { [weak self] status in self?.menuBar.update(status: status) }
        arbiter.onUnreadChanged = { [weak self] count in self?.menuBar.setUnread(count) }
        menuBar.focusAgentProvider = { [weak self] in self?.arbiter.currentOrLastAgent() }
        menuBar.onFocusAgent = { [weak self] key in self?.focusSurface(key: key, source: "menu button") }
        arbiter.onSpeaking = { [weak self] utterance in
            if let utterance {
                self?.lastSpeaking = utterance
                SpacetermSocket.speakingStarted(utterance)
            } else {
                SpacetermSocket.speakingStopped(sessionKey: self?.lastSpeaking?.sessionKey)
                self?.lastSpeaking = nil
            }
        }
        menuBar.onToggleNarration = { [weak self] muted in self?.arbiter.setNarrationMuted(muted) }
        menuBar.onSkip = { [weak self] in self?.arbiter.skipCurrent() }
        menuBar.isPlayingProvider = { [weak self] in self?.arbiter.isPlaying ?? false }
        menuBar.onSpeakClipboard = { [weak self] in self?.arbiter.speakClipboardOrHalt() }
        menuBar.onSummarizeClipboard = { [weak self] in self?.arbiter.summarizeClipboard() }
        // While the menu is open its own key equivalents fire; suppress the tap's
        // copies of those chords so a shortcut never triggers twice.
        menuBar.onMenuOpenChanged = { [weak self] open in self?.hotkey.chordsSuppressed = open }
        // Announce pending questions/plans: the checkbox reflects (and drives) the
        // presence of our PermissionRequest hook in ~/.claude/settings.json.
        menuBar.announceBlocksState = { PermissionHook.isInstalled() }
        menuBar.onToggleAnnounceBlocks = { enable in
            do {
                if enable { try PermissionHook.install() } else { try PermissionHook.uninstall() }
            } catch {
                Log.log("permission-hook: toggle to \(enable) failed: \(error)")
            }
            let now = PermissionHook.isInstalled()
            Log.log("permission-hook: announce questions & plans → \(now)")
            return now
        }
        menuBar.onRestart = { Relauncher.restartAfterTermination() }
        menuBar.launchAtLoginState = { LaunchAtLogin.isEnabled }
        menuBar.onToggleLaunchAtLogin = { LaunchAtLogin.toggle() }
        menuBar.ttsHistoryProvider = { [weak self] in self?.arbiter.ttsHistory ?? [] }
        menuBar.ttsReplayStateProvider = { [weak self] id in self?.arbiter.replayState(forTTS: id) ?? .ready }
        menuBar.sttHistoryProvider = { [weak self] in self?.arbiter.sttHistory ?? [] }
        menuBar.onReplayTTS = { [weak self] id in self?.arbiter.replayTTS(id: id) }
        menuBar.onSurfaceTTS = { [weak self] id in
            guard let self,
                  let key = self.arbiter.ttsHistory.first(where: { $0.id == id })?.sessionKey else { return }
            self.focusSurface(key: key, source: "history")
        }
        menuBar.onMoreDetailsTTS = { [weak self] id in self?.arbiter.moreDetails(id: id) }
        menuBar.onRetrySTT = { [weak self] id in self?.arbiter.retrySTT(id: id) }
        menuBar.onCopySTT = { [weak self] id in self?.arbiter.copySTT(id: id) }
        menuBar.commandHistoryProvider = { [weak self] in self?.arbiter.commandHistory ?? [] }
        menuBar.onRetryCommand = { [weak self] id in self?.arbiter.retryCommand(id: id) }
        menuBar.onCopyCommand = { [weak self] id in self?.arbiter.copyCommand(id: id) }

        hotkey.onStart = { [weak self] mode in self?.arbiter.beginDictation(mode: mode) }
        hotkey.onStop = { [weak self] in self?.arbiter.endDictation() }
        hotkey.onRepaste = { [weak self] in self?.arbiter.repasteLast() }
        hotkey.onToggleMute = { [weak self] in self?.menuBar.toggleNarrationMute() }
        hotkey.onSpeakClipboard = { [weak self] in self?.arbiter.speakClipboardOrHalt() }
        hotkey.onSummarizeClipboard = { [weak self] in self?.arbiter.summarizeClipboard() }
        hotkey.onSkip = { [weak self] in self?.arbiter.skipCurrent() }
        hotkey.onFocusLast = { [weak self] in self?.focusLastAgent() }
        installHotkeyWhenTrusted()

        // Voice commands: a dictation that is a "<verb> [name]" command (rather
        // than text to paste) is handled here instead of being pasted.
        arbiter.directedReplyHandler = { [weak self] transcript in
            await self?.handleVoiceCommand(transcript) ?? false
        }

        // Claude Code narration. The watcher runs off-main and hops to main to
        // record + play each update (with its context, for "More details").
        let arbiter = self.arbiter
        // Shared "waiting on Claude" signal: both watchers turn the icon blue (and
        // sound the entry cue) around their Haiku summarization, matching the
        // on-demand clipboard summarizer.
        let onClaudeThinking: @Sendable (Bool) -> Void = { active in
            Task { @MainActor in active ? arbiter.beginSummarizing() : arbiter.endSummarizing() }
        }
        let watcher = TranscriptWatcher(registry: registry, onClaudeThinking: onClaudeThinking) { utterance, context in
            Task { @MainActor in arbiter.narrate(utterance, context: context) }
        }
        self.watcher = watcher
        // Broadcast the session→call-sign map to spaceterm. Setting the handler
        // emits the persisted map immediately (the startup/restart broadcast);
        // do it before the watcher's run loop so no early assignment is missed.
        let registry = self.registry
        Task {
            await registry.setOnChange { names in SpacetermSocket.sessionNames(names) }
            await watcher.start()
        }

        // Pending-block narration (questions & plans). The transcript never shows
        // a pending tool_use, so this is driven by our PermissionRequest hook,
        // which spools payloads for this watcher to tail. Always run it — the
        // spool is simply empty when the hook isn't installed. Only refresh the
        // hook SCRIPT if the feature is already enabled; never force-install.
        if PermissionHook.isInstalled() {
            do { try PermissionHook.ensureScriptInstalled() }
            catch { Log.log("permission-hook: could not refresh script: \(error)") }
        }
        let permissionWatcher = PermissionWatcher(registry: registry, spoolDir: PermissionHook.spoolDir,
                                                  onClaudeThinking: onClaudeThinking) { utterance, context in
            Task { @MainActor in arbiter.narrate(utterance, context: context) }
        }
        self.permissionWatcher = permissionWatcher
        Task { await permissionWatcher.start() }

        // Warm the custom-word dictionary cache. It no longer feeds the raw
        // /llm/asr prompt (that mis-biased Whisper — see WisprTranscriber); it's
        // kept ready for the flow-request `dictionary_context` path, Milestone C.
        Task { _ = await WisprDictionary.shared.contextWords() }

        menuBar.update(status: .idle)
    }

    // MARK: - Voice commands

    /// Parse a finished dictation as a "[name] <command> [args]" command. Returns
    /// true if it was a command (so it isn't pasted). Grammar (punctuation
    /// ignored) is name-FIRST — an optional leading call-sign, then the verb:
    ///   • [name] focus            → raise a surface
    ///   • [name] repeat           → replay the latest update
    ///   • [name] more detail(s)   → elaborate on an update
    ///   • [name] ask <message>    → question the summarizer about an update
    ///   • [name]                  → a bare call-sign is shorthand for "focus"
    ///   • skip                    → global; drops whatever is playing now
    /// Omitting the name targets the last-referenced update, so every command
    /// inherits the same last-target fallback.
    private func handleVoiceCommand(_ transcript: String) async -> Bool {
        let words = transcript.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard let first = words.first else { return false }

        // Peel an optional leading call-sign: present only when the first token
        // isn't itself a command word. The remainder is the command + its args.
        let name: String? = Self.commandHeads.contains(first) ? nil : first
        let rest = name == nil ? words : Array(words.dropFirst())
        guard let head = rest.first else {
            // A bare call-sign (name with no command word) is shorthand for "focus".
            if let name { await runSurface(name: name); return true }
            return false
        }

        // "[name] more detail(s)"
        if head == "more", rest.count >= 2, rest[1] == "detail" || rest[1] == "details" {
            guard rest.count == 2 else { return false }
            await runMoreDetails(name: name)
            return true
        }
        // "[name] focus"
        if Self.focusVerbs.contains(head) {
            guard rest.count == 1 else { return false }
            await runSurface(name: name)
            return true
        }
        // "[name] repeat"
        if Self.repeatVerbs.contains(head) {
            guard rest.count == 1 else { return false }
            await runRepeat(name: name)
            return true
        }
        // "[name] ask <message>" — a free-text payload, so it's sliced from the
        // ORIGINAL transcript (casing/punctuation preserved), not the tokens.
        if Self.askVerbs.contains(head) {
            let message = Self.askPayload(from: transcript)
            guard !message.isEmpty else { return false }   // bare "ask" isn't actionable
            await runAsk(name: name, message: message)
            return true
        }
        // "skip" — global; acts on whatever is playing, so any name is ignored.
        if Self.skipVerbs.contains(head) {
            guard rest.count == 1 else { return false }
            arbiter.skipQueued()
            return true
        }
        return false
    }

    /// The session a tool targets: the named call-sign, or the last-referenced
    /// session when no name is given.
    private func targetSessionKey(_ name: String?) async -> String? {
        if let name { return await registry.claudeSession(forName: name) }
        return arbiter.lastReferencedSessionKey
    }

    /// Raise a surface by call-sign, or the last-referenced session if no name.
    private func runSurface(name: String?) async {
        let label = name ?? "last-referenced"
        guard let key = await targetSessionKey(name) else { Log.log("surface: no target (\(label))"); return }
        focusSurface(key: key, source: "voice: \(label)")
    }

    /// Focus the surface of the last agent that spoke (⌘⌃J) — the same
    /// current/most-recent agent the menu's "Focus <name>" item offers, so it
    /// tracks whoever is speaking the moment narration starts.
    private func focusLastAgent() {
        guard let agent = arbiter.currentOrLastAgent() else { Log.log("focus (⌘⌃J): no agent yet"); return }
        focusSurface(key: agent.sessionKey, source: "⌘⌃J")
    }

    /// Raise the spaceterm surface hosting a session, noting it as the
    /// last-referenced target. Shared by the menu button, ⌘⌃J, the TTS-history
    /// Surface button, and the "focus" voice command (a surface has no playback,
    /// so we reference it explicitly). We hand spaceterm the claude session id and
    /// let it resolve the surface; whether one exists is spaceterm's to log.
    private func focusSurface(key: String, source: String) {
        arbiter.referenceSession(key)
        SpacetermSocket.focusClaudeSession(key)
        Log.log("focus (\(source)): session \(key.prefix(8))")
    }

    /// Replay a call-sign's latest update (free, from cache), or the
    /// last-referenced session if no name.
    private func runRepeat(name: String?) async {
        guard let key = await targetSessionKey(name),
              let entry = arbiter.lastTTSEntry(forSessionKey: key) else {
            Log.log("repeat: no target (\(name ?? "last-referenced"))"); return
        }
        arbiter.replayTTS(id: entry.id)   // updates last-referenced
    }

    /// Elaborate on a call-sign's latest update, or the last-referenced if no name.
    private func runMoreDetails(name: String?) async {
        if let name {
            guard let key = await registry.claudeSession(forName: name),
                  let entry = arbiter.lastTTSEntry(forSessionKey: key) else {
                Log.log("more-details: no update for name '\(name)'"); return
            }
            arbiter.moreDetails(id: entry.id)   // updates last-referenced
        } else {
            arbiter.moreDetails(id: nil)        // last-referenced session's latest
        }
    }

    /// Question the summarizer about a call-sign's latest update, or the
    /// last-referenced update if no name.
    private func runAsk(name: String?, message: String) async {
        if let name {
            guard let key = await registry.claudeSession(forName: name),
                  let entry = arbiter.lastTTSEntry(forSessionKey: key) else {
                Log.log("ask: no update for name '\(name)'"); return
            }
            arbiter.ask(id: entry.id, message: message)   // updates last-referenced
        } else {
            arbiter.ask(id: nil, message: message)        // last-referenced session's latest
        }
    }

    /// Return the free-text message after the "ask" verb, verbatim. Matches the
    /// FIRST "ask"/"asks"/"asked" (and any trailing separator like ":"), so an
    /// optional leading call-sign is skipped over naturally. Empty when nothing
    /// follows the verb.
    private static func askPayload(from transcript: String) -> String {
        let pattern = "\\bask(?:s|ed)?\\b[\\s:;,.\\-–—]*"
        let range = NSRange(transcript.startIndex..., in: transcript)
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = re.firstMatch(in: transcript, range: range),
              let matched = Range(match.range, in: transcript) else {
            return ""
        }
        return String(transcript[matched.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trustPollTimer: Timer?

    /// Install the Right-Shift event tap. A keyboard tap needs BOTH:
    ///   • Accessibility — to install the tap;
    ///   • Input Monitoring — to receive real keycodes (without it every event
    ///     arrives with keycode/flags zeroed, so nothing is ever recognized).
    /// Neither takes effect for a tap created before the grant, so we prompt for
    /// both and poll: the moment both land we install the tap — no relaunch.
    private func installHotkeyWhenTrusted() {
        func ready() -> Bool { AXIsProcessTrusted() && HotkeyMonitor.inputMonitoringGranted() }
        func install() {
            Log.log(hotkey.start() ? "hotkey tap installed — hold Fn to dictate"
                                   : "hotkey tap FAILED despite permissions")
        }
        if ready() { install(); return }

        Log.log("waiting on permissions — accessibility=\(AXIsProcessTrusted()) "
                + "inputMonitoring=\(HotkeyMonitor.inputMonitoringGranted())")
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        HotkeyMonitor.requestInputMonitoring()
        trustPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, ready() else { return }
                self.trustPollTimer?.invalidate()
                self.trustPollTimer = nil
                Log.log("permissions granted (accessibility + input monitoring)")
                install()
            }
        }
    }
}
