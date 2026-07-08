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
        menuBar.onFocusAgent = { [weak self] key in
            guard let self else { return }
            self.arbiter.referenceSession(key)
            if let surface = SpacetermSurfaceResolver.surfaceId(forClaudeSession: key) {
                SpacetermSocket.focusSurface(surfaceId: surface)
            }
        }
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
            self.arbiter.referenceSession(key)   // clicking Surface references that agent
            if let surface = SpacetermSurfaceResolver.surfaceId(forClaudeSession: key) {
                SpacetermSocket.focusSurface(surfaceId: surface)
                Log.log("surface (from history): session \(key.prefix(8)) → \(surface.prefix(8))")
            } else {
                Log.log("surface (from history): no live surface for session \(key.prefix(8))")
            }
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

    /// Parse a finished dictation as a "<verb> [name]" command. Returns true if it
    /// was a command (so it isn't pasted). Grammar (punctuation ignored):
    ///   • raise/surface [name]   → raise a surface
    ///   • more detail(s) [name]  → elaborate on an update
    /// A verb with no name targets the last-played update (generalized so future
    /// voice tools inherit the same last-target fallback).
    private func handleVoiceCommand(_ transcript: String) async -> Bool {
        let words = transcript.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard let verb = words.first else { return false }

        // "more detail(s) [name]"
        if verb == "more", words.count >= 2, words[1] == "detail" || words[1] == "details" {
            guard words.count <= 3 else { return false }        // verb (+ one name) only
            await runMoreDetails(name: words.count == 3 ? words[2] : nil)
            return true
        }
        // "focus [name]"
        if Self.focusVerbs.contains(verb) {
            guard words.count <= 2 else { return false }
            await runSurface(name: words.count == 2 ? words[1] : nil)
            return true
        }
        // "repeat [name]"
        if Self.repeatVerbs.contains(verb) {
            guard words.count <= 2 else { return false }
            await runRepeat(name: words.count == 2 ? words[1] : nil)
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
        arbiter.referenceSession(key)   // surface has no playback, so note it explicitly
        if let surface = SpacetermSurfaceResolver.surfaceId(forClaudeSession: key) {
            SpacetermSocket.focusSurface(surfaceId: surface)
            Log.log("surface: \(label) → \(surface.prefix(8))")
        } else {
            Log.log("surface: no live surface for \(label)")
        }
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
