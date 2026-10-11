import AppKit
import AVFoundation

@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarController()
    private let arbiter = AudioArbiter()
    private let hotkey = HotkeyMonitor()
    private let speechService = SpeechHTTPService()
    /// Watches the default output device, for the "only when using AirPods" rule.
    private let outputWatcher = OutputDeviceWatcher()
    private lazy var restart = RestartCoordinator(
        isBusy: { [unowned self] in
            self.arbiter.isDictating || self.arbiter.isSpeaking
                || RemoteTranscriptionManager.shared.activity.active > 0
        })
    /// The local Kokoro server's launchd agent. Like a restart, anything that
    /// stops the server waits until nothing is being dictated or spoken.
    private lazy var kokoro = KokoroService(
        isBusy: { [unowned self] in self.arbiter.isDictating || self.arbiter.isSpeaking })
    private let kokoroSetup = KokoroSetupWindow()
    /// What the setup window last showed, so a later health change doesn't
    /// re-open a window the user closed.
    private var kokoroSetupShown: KokoroService.Phase?
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
        SubscriberSocket.dictation(active: false)
        arbiter.onDictationBegan = {
            SubscriberSocket.dictation(active: true)
            Task { await SpeechJobManager.shared.beginDictation() }
        }
        arbiter.onDictationEnded = { [weak self] in
            SubscriberSocket.dictation(active: false)
            Task { await SpeechJobManager.shared.endDictation() }
            // A restart asked for mid-dictation has been waiting for exactly this.
            self?.restart.attempt()
        }
        speechService.snapshot = { [unowned self] in
            .init(status: currentStatus, dictating: arbiter.isDictating,
                  speaking: arbiter.isSpeaking, restart: restart.state,
                  stream: arbiter.streamHealth,
                  remoteTranscriptions: RemoteTranscriptionManager.shared.activity.active,
                  provider: TranscriptionPreferences.primary, shadow: TranscriptionPreferences.shadow)
        }
        // The last remote transcription finishing is a third way to become idle.
        RemoteTranscriptionManager.shared.activity.onIdle = { [weak self] in
            Task { @MainActor in self?.restart.attempt() }
        }
        speechService.requestRestart = { [unowned self] in restart.request(source: .http) }
        arbiter.onCommand = { [weak self] text, context in self?.routeCommand(text, context: context) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await SpeechJobManager.shared.configure(
                play: { [weak self] request, onStart, onSynthesized in
                    await self?.arbiter.playSentence(request,
                                                     onStart: onStart, onSynthesized: onSynthesized) ?? .failed
                },
                prefetch: { [weak self] text, voice in await self?.arbiter.prefetchSentence(text: text, voiceID: voice) },
                halt: { [weak self] in await MainActor.run { self?.arbiter.haltSpeech() } },
                spokenPosition: { [weak self] in await MainActor.run { self?.arbiter.spokenPosition() } },
                onSpeechActivity: { [weak self] active in
                    Task { @MainActor in
                        self?.arbiter.setSpeechActive(active)
                        // Speech going quiet is one of the two ways the app becomes
                        // idle, so it is one of the two places a restart that has
                        // been waiting gets to fire.
                        if !active { self?.restart.attempt() }
                    }
                })
        }

        menuBar.sttHistoryProvider = { [weak self] in self?.arbiter.sttHistory ?? [] }
        menuBar.commandHistoryProvider = { [weak self] in self?.arbiter.commandHistory ?? [] }
        menuBar.onRetrySTT = { [weak self] in self?.arbiter.retrySTT(id: $0) }
        menuBar.onCopySTT = { [weak self] in self?.arbiter.copySTT(id: $0) }
        menuBar.onRetryCommand = { [weak self] in self?.arbiter.retryCommand(id: $0) }
        menuBar.onCopyCommand = { [weak self] in self?.arbiter.copyCommand(id: $0) }
        menuBar.transcriptionState = { (TranscriptionPreferences.primary, TranscriptionPreferences.shadow) }
        menuBar.lastShadow = { [weak self] in self?.arbiter.lastShadow }
        menuBar.onCopyLastShadow = { [weak self] in self?.arbiter.copyLastShadow() }
        menuBar.onCopyShadowSTT = { [weak self] in self?.arbiter.copyShadowSTT(id: $0) }
        menuBar.onCopyShadowCommand = { [weak self] in self?.arbiter.copyShadowCommand(id: $0) }
        menuBar.onSelectProvider = { [weak self] id in
            guard id != TranscriptionPreferences.primary else { return }
            Log.log("transcription: provider set to \(id.displayName)")
            TranscriptionPreferences.primary = id
            self?.arbiter.providersChanged()
        }
        menuBar.onSelectShadow = { [weak self] id in
            Log.log("transcription: shadow set to \(id?.displayName ?? "none")")
            TranscriptionPreferences.shadow = id
            self?.arbiter.providersChanged()
        }
        menuBar.onMenuOpenChanged = { [weak self] open in self?.hotkey.chordsSuppressed = open }
        menuBar.onSpeakClipboard = { [weak self] in self?.arbiter.speakClipboard() }
        menuBar.onSummarizeClipboard = { [weak self] in self?.arbiter.summarizeClipboard() }
        menuBar.onMuteSpeech = { [weak self] muted in
            if muted { self?.arbiter.haltSpeech() }
            Task { await SpeechJobManager.shared.setMuted(muted) }
        }
        arbiter.onSpeechIdle = { [weak self] in self?.restart.attempt() }
        menuBar.onRestart = { [unowned self] in restart.request(source: .menu) }
        wireTextToSpeechMenu()
        menuBar.launchAtLoginState = { LaunchAtLogin.isEnabled }
        menuBar.onToggleLaunchAtLogin = { LaunchAtLogin.toggle() }
        arbiter.wordOverlay.placement = OverlayPreferences.placement
        menuBar.wordOverlayPlacement = { OverlayPreferences.placement }
        menuBar.onSetWordOverlay = { [weak self] placement in
            OverlayPreferences.placement = placement
            self?.arbiter.wordOverlay.placement = placement
            self?.arbiter.wordOverlay.previewPlacement()
            Log.log("word overlay: \(placement.rawValue)")
        }
        arbiter.muter.isEnabled = AudioPreferences.muteSystemAudioWhileDictating
        menuBar.muteSystemAudioState = { AudioPreferences.muteSystemAudioWhileDictating }
        menuBar.onToggleMuteSystemAudio = { [weak self] in
            AudioPreferences.muteSystemAudioWhileDictating.toggle()
            let on = AudioPreferences.muteSystemAudioWhileDictating
            self?.arbiter.muter.isEnabled = on
            Log.log("mute system audio while dictating: \(on ? "enabled" : "disabled")")
            return on
        }
        menuBar.typeInsteadOfPasteState = { PastePreferences.technique == .keystrokes }
        menuBar.onToggleTypeInsteadOfPaste = {
            let typing = PastePreferences.technique != .keystrokes
            PastePreferences.technique = typing ? .keystrokes : .clipboard
            Log.log("paste technique: \(PastePreferences.technique.rawValue)")
            return typing
        }
        menuBar.keepMicOpenState = { [unowned self] in shouldKeepMicrophoneOpen }
        menuBar.onToggleKeepMicOpen = { [unowned self] in
            AudioPreferences.keepMicrophoneOpen.toggle()
            applyMicrophonePolicy(reason: "menu")
            return shouldKeepMicrophoneOpen
        }
        menuBar.keepMicOpenForWirelessState = { AudioPreferences.keepMicrophoneOpenForWireless }
        menuBar.onToggleKeepMicOpenForWireless = { [unowned self] in
            AudioPreferences.keepMicrophoneOpenForWireless.toggle()
            applyMicrophonePolicy(reason: "menu")
            return AudioPreferences.keepMicrophoneOpenForWireless
        }
        // AirPods arriving or leaving is what drives the rule; recompute on every
        // output change rather than sampling it at dictation time, so the headset
        // is already in the profile it will stay in before the key is pressed.
        outputWatcher.onChange = { [weak self] in
            MainActor.assumeIsolated {
                self?.applyMicrophonePolicy(reason: "output device changed")
                self?.arbiter.outputDeviceChanged()
            }
        }
        outputWatcher.start()
        applyMicrophonePolicy(reason: "launch")
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
        hotkey.onRepaste = { [weak self] in self?.arbiter.repasteLast(using: .clipboard) }
        hotkey.onRetype = { [weak self] in self?.arbiter.repasteLast(using: .keystrokes) }
        hotkey.onToggleMute = { [weak self] in self?.menuBar.toggleNarrationMute() }
        hotkey.onSpeakClipboard = { [weak self] in self?.arbiter.speakClipboard() }
        hotkey.onSummarizeClipboard = { [weak self] in self?.arbiter.summarizeClipboard() }
        hotkey.onCycleOverlayPlacement = { [weak self] in self?.menuBar.cycleWordOverlay() }
        hotkey.onFasterSpeech = { [weak self] in self?.arbiter.adjustSpeechRate(by: 0.2) }
        hotkey.onSlowerSpeech = { [weak self] in self?.arbiter.adjustSpeechRate(by: -0.2) }
        hotkey.onRewindSpeech = { [weak self] in self?.arbiter.rewindSpeech(seconds: 3) }
        hotkey.onForwardSpeech = { [weak self] in self?.arbiter.skipSpeechAhead(seconds: 3) }
        menuBar.onFasterSpeech = hotkey.onFasterSpeech
        menuBar.onSlowerSpeech = hotkey.onSlowerSpeech
        menuBar.onRewindSpeech = hotkey.onRewindSpeech
        menuBar.onForwardSpeech = hotkey.onForwardSpeech
        arbiter.onPlaybackControlsChanged = { [weak self] in
            guard let self else { return }
            self.arbiter.wordOverlay.playbackRate = self.arbiter.speechRate
            self.hotkey.setPlaybackControls(canAdjust: self.arbiter.canAdjustSpeech,
                                           canRewind: self.arbiter.canRewindSpeech)
            self.menuBar.updatePlayback(rate: self.arbiter.speechRate,
                                        canAdjust: self.arbiter.canAdjustSpeech,
                                        canRewind: self.arbiter.canRewindSpeech)
        }
        arbiter.onPlaybackControlsChanged?()
        hotkey.tapToToggle = HotkeyPreferences.tapToToggle
        installHotkeyWhenTrusted()
        watchSecureInput()
        do { try speechService.start() } catch { Log.log("speech HTTP start failed: \(error)") }
        // Dial the Baseten connection and fetch the token/dictionary now, so the
        // first dictation of the session doesn't pay for any of it.
        arbiter.prewarm()
        menuBar.update(status: .idle)
        // The mirror of the restart cue: after a cooperative restart the two play
        // back to back, so the gap between "going down" and "back up" is audible
        // rather than something you have to check the menu for.
        SoundEffect.launched.play()
    }

    /// The Text to Speech submenu: provider choice plus the Kokoro service.
    private func wireTextToSpeechMenu() {
        kokoro.onChange = { [weak self] in
            self?.menuBar.refreshTTSMenu()
            self?.updateKokoroSetupWindow()
        }
        kokoroSetup.onCancel = { [unowned self] in kokoro.cancel() }
        kokoroSetup.onShowLog = { [unowned self] in menuBar.onShowKokoroLog?() }
        kokoroSetup.detailProvider = { [unowned self] in kokoro.lastLogLine() }
        menuBar.ttsMenuState = { [unowned self] in
            TTSMenuState.make(provider: Config.ttsProvider, phase: kokoro.phase,
                              installed: kokoro.isInstalled,
                              updateAvailable: kokoro.updateAvailable, canCancel: kokoro.canCancel,
                              health: kokoro.health)
        }
        menuBar.onTTSMenuOpened = { [unowned self] in
            Task { await kokoro.refreshHealth(); menuBar.refreshTTSMenu() }
        }
        menuBar.onSelectLocalTTS = { [unowned self] in
            setTTSProvider(.kokoroLocal)
            kokoro.autoStart(provider: .kokoroLocal)
        }
        menuBar.onChooseCustomTTS = { [unowned self] in
            let current: String? = if case .custom(let url) = Config.ttsProvider { url } else { Config.load().tts?.url }
            guard let url = TTSDialogs.customServerURL(current: current) else { return }
            setTTSProvider(.custom(url: url))
        }
        menuBar.onInstallKokoro = { [unowned self] in kokoro.install() }
        menuBar.onCancelKokoroInstall = { [unowned self] in kokoro.cancel() }
        menuBar.onUpdateKokoro = { [unowned self] in kokoro.update() }
        menuBar.onRestartKokoro = { [unowned self] in kokoro.restart() }
        menuBar.onUninstallKokoro = { [unowned self] in
            guard TTSDialogs.confirmUninstall() else { return }
            kokoro.uninstall()
        }
        menuBar.onShowKokoroLog = { [unowned self] in
            let log = kokoro.paths.log
            guard FileManager.default.fileExists(atPath: log.path) else {
                TTSDialogs.showError("No Kokoro log yet", detail: "\(log.path) appears once Kokoro is installed.")
                return
            }
            NSWorkspace.shared.open(log)
        }
        // No prompt: install (or update) on its own, with the setup window up.
        kokoro.autoStart(provider: Config.ttsProvider)
    }

    /// The setup window follows installs only; the menu's status line covers
    /// the quick actions (restart, update, uninstall).
    private func updateKokoroSetupWindow() {
        guard kokoro.action == .install else { return }
        if case .working = kokoro.phase {} else if kokoro.phase == kokoroSetupShown { return }
        kokoroSetupShown = kokoro.phase
        switch kokoro.phase {
        case .working(let step):
            kokoroSetup.show(.working(step: step, progress: kokoro.progress ?? 0, cancellable: kokoro.canCancel))
        case .idle:
            kokoroSetup.show(.done)
        case .failed(let reason):
            kokoroSetup.show(.failed(reason))
        }
    }

    private func setTTSProvider(_ provider: TTSProvider) {
        do { try Config.setTTSProvider(provider) } catch {
            Log.log("tts: could not save the provider choice: \(error)")
            TTSDialogs.showError("Couldn't save the Text to Speech choice", detail: "\(Config.fileURL.path): \(error.localizedDescription)")
        }
        menuBar.refreshTTSMenu()
    }

    /// Whether the microphone should be held open right now: the AirPods rule's
    /// answer when that rule is on, the manual checkbox's otherwise. One place
    /// decides, so the menu's checkmark and the recorder can never disagree.
    private var shouldKeepMicrophoneOpen: Bool {
        AudioPreferences.keepMicrophoneOpenForWireless
            ? OutputDevice.isWireless
            : AudioPreferences.keepMicrophoneOpen
    }

    /// Push that decision into the recorder. Cheap and idempotent — `setAlwaysOn`
    /// ignores a value it is already at — so every input that can change the
    /// answer (either checkbox, an output-device change, launch) just calls this.
    private func applyMicrophonePolicy(reason: String) {
        let wanted = shouldKeepMicrophoneOpen
        guard wanted != arbiter.microphoneAlwaysOn else { return }
        Log.log("microphone: \(wanted ? "holding open" : "releasing between dictations") "
                + "— \(reason), output \(OutputDevice.summary)")
        arbiter.microphoneAlwaysOn = wanted
    }

    /// Every way out of the process ends here — menu quit, the restart paths,
    /// and SIGTERM (see `TerminationSignal`) — so this is where the system output
    /// is unmuted and the discovery file stops pointing at a pid about to die.
    func applicationWillTerminate(_ notification: Notification) {
        outputWatcher.stop()
        arbiter.prepareForTermination()
        speechService.stop()
        Log.log("quit: teardown finished")
    }

    private func routeCommand(_ text: String, context: DictationContext) {
        Log.log("command: captured frontmost bundleID=\(context.bundleIdentifier ?? "(none)")")
        SubscriberSocket.voiceCommand(text) { delivered, route in
            Log.log(route.map { "command: \(text.count)-char transcript to \($0) — \(delivered ? "delivered" : "unreachable")" }
                    ?? "command: no subscriber takes commands (PUT /v1/subscribers/<name>)")
            guard !delivered else { return }
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
