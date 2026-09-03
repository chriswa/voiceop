import AppKit
import AVFoundation

@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarController()
    private let arbiter = AudioArbiter()
    private let hotkey = HotkeyMonitor()
    private let speechService = SpeechHTTPService()
    private lazy var restart = RestartCoordinator(isBusy: { [unowned self] in self.arbiter.isDictating })
    private var currentStatus: OperatorStatus = .idle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.log("Voice Operator launching — \(BuildInfo.summary)")
        TerminationSignal.routeSIGTERMToGracefulQuit()
        LaunchAtLogin.enableByDefaultOnce()
        AVCaptureDevice.requestAccess(for: .audio) { granted in Log.log("mic access request → granted=\(granted)") }
        arbiter.onStatus = { [weak self] in self?.currentStatus = $0; self?.menuBar.update(status: $0) }
        arbiter.onTranscriptStyle = { [weak self] in self?.menuBar.update(style: $0) }
        arbiter.onStreamHealth = { [weak self] in self?.menuBar.update(streamHealth: $0) }
        arbiter.onHistoryChanged = { [weak self] in self?.menuBar.refreshHistory() }
        arbiter.onDictationBegan = { Task { await SpeechJobManager.shared.beginDictation() } }
        arbiter.onDictationEnded = { [weak self] in
            Task { await SpeechJobManager.shared.endDictation() }
            // A restart asked for mid-dictation has been waiting for exactly this.
            self?.restart.attempt()
        }
        speechService.snapshot = { [unowned self] in
            .init(status: currentStatus, dictating: arbiter.isDictating, restart: restart.state,
                  stream: arbiter.streamHealth)
        }
        speechService.requestRestart = { [unowned self] in restart.request(source: .http) }
        arbiter.onCommand = { [weak self] text, context in self?.routeCommand(text, context: context) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await SpeechJobManager.shared.configure(
                play: { [weak self] text, voice, onStart, onSynthesized in
                    await self?.arbiter.playSentence(text: text, voiceID: voice,
                                                     onStart: onStart, onSynthesized: onSynthesized) ?? false
                },
                prefetch: { [weak self] text, voice in await self?.arbiter.prefetchSentence(text: text, voiceID: voice) },
                halt: { [weak self] in Task { @MainActor in self?.arbiter.haltSpeech() } },
                onSpeechActivity: { [weak self] active in Task { @MainActor in self?.arbiter.setSpeechActive(active) } })
        }

        menuBar.sttHistoryProvider = { [weak self] in self?.arbiter.sttHistory ?? [] }
        menuBar.commandHistoryProvider = { [weak self] in self?.arbiter.commandHistory ?? [] }
        menuBar.onRetrySTT = { [weak self] in self?.arbiter.retrySTT(id: $0) }
        menuBar.onCopySTT = { [weak self] in self?.arbiter.copySTT(id: $0) }
        menuBar.onRetryCommand = { [weak self] in self?.arbiter.retryCommand(id: $0) }
        menuBar.onCopyCommand = { [weak self] in self?.arbiter.copyCommand(id: $0) }
        menuBar.onMenuOpenChanged = { [weak self] open in self?.hotkey.chordsSuppressed = open }
        menuBar.onSpeakClipboard = { [weak self] in self?.arbiter.speakClipboard() }
        menuBar.onSummarizeClipboard = { [weak self] in self?.arbiter.summarizeClipboard() }
        menuBar.onMuteSpeech = { muted in Task { await SpeechJobManager.shared.setMuted(muted) } }
        menuBar.onRestart = { [unowned self] in restart.request(source: .menu) }
        menuBar.launchAtLoginState = { LaunchAtLogin.isEnabled }
        menuBar.onToggleLaunchAtLogin = { LaunchAtLogin.toggle() }
        arbiter.wordOverlay.isEnabled = OverlayPreferences.wordOverlayEnabled
        menuBar.wordOverlayState = { OverlayPreferences.wordOverlayEnabled }
        menuBar.onToggleWordOverlay = { [weak self] in
            OverlayPreferences.wordOverlayEnabled.toggle()
            let on = OverlayPreferences.wordOverlayEnabled
            self?.arbiter.wordOverlay.isEnabled = on
            Log.log("word overlay: \(on ? "enabled" : "disabled")")
            return on
        }
        menuBar.tapToToggleState = { HotkeyPreferences.tapToToggle }
        menuBar.onToggleTapToToggle = { [weak self] in
            HotkeyPreferences.tapToToggle.toggle()
            let on = HotkeyPreferences.tapToToggle
            self?.hotkey.tapToToggle = on
            Log.log("hotkey mode: \(on ? "tap-to-toggle" : "hold / double-tap-lock")")
            return on
        }

        hotkey.onStart = { [weak self] mode, trace in self?.arbiter.beginDictation(mode: mode, trace: trace) }
        hotkey.onStop = { [weak self] in self?.arbiter.endDictation(context: Self.frontmostContext()) }
        hotkey.onCycleStyle = { [weak self] in self?.arbiter.cycleTranscriptStyle() }
        hotkey.onRepaste = { [weak self] in self?.arbiter.repasteLast() }
        hotkey.onToggleMute = { [weak self] in self?.menuBar.toggleNarrationMute() }
        hotkey.onSpeakClipboard = { [weak self] in self?.arbiter.speakClipboard() }
        hotkey.onSummarizeClipboard = { [weak self] in self?.arbiter.summarizeClipboard() }
        hotkey.tapToToggle = HotkeyPreferences.tapToToggle
        installHotkeyWhenTrusted()
        watchSecureInput()
        do { try speechService.start() } catch { Log.log("speech HTTP start failed: \(error)") }
        // Dial the Baseten connection and fetch the token/dictionary now, so the
        // first dictation of the session doesn't pay for any of it.
        arbiter.prewarm()
        menuBar.update(status: .idle)
    }

    /// Every way out of the process ends here — menu quit, the restart paths,
    /// and SIGTERM (see `TerminationSignal`) — so this is where the system output
    /// is unmuted and the discovery file stops pointing at a pid about to die.
    func applicationWillTerminate(_ notification: Notification) {
        arbiter.prepareForTermination()
        speechService.stop()
    }

    private func routeCommand(_ text: String, context: DictationContext) {
        Log.log("command: captured frontmost bundleID=\(context.bundleIdentifier ?? "(none)")")
        Log.log("command: forwarding \(text.count)-char transcript to Spaceterm")
        SpacetermSocket.voiceCommand(text) { ok in
            guard !ok else { return }
            Task { @MainActor in SoundEffect.unrecognized.play() }
        }
    }
    private static func frontmostContext() -> DictationContext {
        DictationContext(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    /// Watch secure event input and report every transition.
    ///
    /// While it is on, none of the ⌘⌃ chord shortcuts can reach us — see
    /// `SecureInput`. Nothing here can change that; what it can do is make the
    /// cause legible, in the log and in the menu, instead of leaving half the
    /// app mysteriously dead.
    private var secureInputTimer: Timer?
    private var secureInputWasEnabled: Bool?
    private func watchSecureInput() {
        func check() {
            let enabled = SecureInput.isEnabled
            guard enabled != secureInputWasEnabled else { return }
            secureInputWasEnabled = enabled
            Log.log(enabled
                ? "secure input: \(SecureInput.description) — ⌘⌃ shortcuts cannot reach Voice Operator until it is turned off (dictation is unaffected)"
                : "secure input: off — ⌘⌃ shortcuts are working again")
            menuBar.update(secureInputHolder: enabled ? SecureInput.holderName : nil)
        }
        check()
        secureInputTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { check() }
        }
    }

    private var trustPollTimer: Timer?
    private func installHotkeyWhenTrusted() {
        func ready() -> Bool { AXIsProcessTrusted() && HotkeyMonitor.inputMonitoringGranted() }
        func install() { Log.log(hotkey.start() ? "hotkey tap installed" : "hotkey tap failed") }
        if ready() { install(); return }
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        HotkeyMonitor.requestInputMonitoring()
        trustPollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, ready() else { return }
                self.trustPollTimer?.invalidate(); self.trustPollTimer = nil; install()
            }
        }
    }
}
