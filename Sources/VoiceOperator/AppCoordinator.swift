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

    /// The three reserved single-word commands. A lone one of these (after an
    /// optional call-sign) is that command; ANY other words are a free-text aside.
    /// Each keeps its ‑s/‑ed transcription variants to absorb STT wobble.
    private static let focusVerbs: Set<String> = ["focus", "focuses", "focused"]
    private static let repeatVerbs: Set<String> = ["repeat", "repeats", "repeated"]
    /// "skip" drops the clip that was playing when this command began, so playback
    /// advances to the next update. "skeptics" is a synonym — a common STT mishearing
    /// of "skip" that we accept rather than fight.
    private static let skipVerbs: Set<String> = ["skip", "skips", "skipped", "skeptics"]

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
        // record + play each update (with its context, so an "aside" can question it).
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

    /// Parse a finished command-mode dictation. Returns true if it resolved to an
    /// action (false plays the "unrecognized" cue). Grammar (punctuation ignored),
    /// name-FIRST — an optional leading call-sign, then either a reserved word or
    /// free text:
    ///   • [name]                 → focus that agent's surface (bare call-sign)
    ///   • [name] focus           → the same, said explicitly
    ///   • [name] repeat          → replay the agent's latest update
    ///   • [name] <anything else> → an aside: question the summarizer about it
    ///   • skip                   → global; drops whatever is playing now
    /// The leading token is a call-sign ONLY if it's a currently-active agent name
    /// (resolved via the registry, homophones included); otherwise there is no name
    /// and the whole utterance — a lone message with no reserved word — becomes an
    /// aside to the last-referenced agent.
    private func handleVoiceCommand(_ transcript: String) async -> Bool {
        let words = transcript.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard let first = words.first else { return false }

        // Name-first: the leading token addresses an agent only if it's a known,
        // active call-sign. Otherwise there's no name and the entire utterance
        // targets the last-referenced agent (so free text falls through to aside).
        let named = await registry.claudeSession(forName: first) != nil
        let name: String? = named ? first : nil
        let rest = named ? Array(words.dropFirst()) : words

        // Bare call-sign (name with nothing after it) → focus.
        guard let verb = rest.first else { return await runSurface(name: name) }

        // A LONE reserved word is that command; anything else is a free-text aside.
        if rest.count == 1 {
            if Self.focusVerbs.contains(verb) { return await runSurface(name: name) }
            if Self.repeatVerbs.contains(verb) { return await runRepeat(name: name) }
            if Self.skipVerbs.contains(verb) { arbiter.skipQueued(); return true }
        }

        // Everything else → an aside. The message is the ORIGINAL transcript
        // (casing/punctuation preserved) with the leading call-sign, if any, dropped.
        let message = Self.asideMessage(from: transcript, droppingLeadingName: name)
        guard !message.isEmpty else { return false }
        return await runAside(name: name, message: message)
    }

    /// The session a tool targets: the named call-sign, or the last-referenced
    /// session when no name is given.
    private func targetSessionKey(_ name: String?) async -> String? {
        if let name { return await registry.claudeSession(forName: name) }
        return arbiter.lastReferencedSessionKey
    }

    /// Raise a surface by call-sign, or the last-referenced session if no name.
    /// Returns false (→ "unrecognized" cue) when there's no such target.
    private func runSurface(name: String?) async -> Bool {
        let label = name ?? "last-referenced"
        guard let key = await targetSessionKey(name) else { Log.log("surface: no target (\(label))"); return false }
        focusSurface(key: key, source: "voice: \(label)")
        return true
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
    /// last-referenced session if no name. Returns false when there's no update.
    private func runRepeat(name: String?) async -> Bool {
        guard let key = await targetSessionKey(name),
              let entry = arbiter.lastTTSEntry(forSessionKey: key) else {
            Log.log("repeat: no target (\(name ?? "last-referenced"))"); return false
        }
        arbiter.replayTTS(id: entry.id)   // updates last-referenced
        return true
    }

    /// Question the summarizer about a call-sign's latest update, or the
    /// last-referenced update if no name. Returns false when there's no update to
    /// question (unknown name, or nothing referenced yet).
    private func runAside(name: String?, message: String) async -> Bool {
        guard let key = await targetSessionKey(name),
              let entry = arbiter.lastTTSEntry(forSessionKey: key) else {
            Log.log("aside: no target (\(name ?? "last-referenced"))"); return false
        }
        arbiter.ask(id: entry.id, message: message)   // updates last-referenced
        return true
    }

    /// The free-text aside message, taken from the ORIGINAL transcript so casing
    /// and punctuation survive. When a call-sign led the utterance it's dropped
    /// (along with the separator it left, e.g. "Apollo, …"); otherwise the whole
    /// transcript is the message.
    private static func asideMessage(from transcript: String, droppingLeadingName name: String?) -> String {
        var text = transcript
        if let name, let r = text.range(of: name, options: [.caseInsensitive]) {
            text = String(text[r.upperBound...])   // drop the leading call-sign
        }
        // Strip whatever separator/whitespace the name left in front of the message.
        let leading = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":;,.-–—"))
        while let c = text.unicodeScalars.first, leading.contains(c) { text.unicodeScalars.removeFirst() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
