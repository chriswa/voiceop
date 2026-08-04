import AppKit
import AVFoundation

@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarController()
    private let arbiter = AudioArbiter()
    private let hotkey = HotkeyMonitor()
    private let speechService = SpeechHTTPService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.log("Voice Operator launching")
        LaunchAtLogin.enableByDefaultOnce()
        AVCaptureDevice.requestAccess(for: .audio) { granted in Log.log("mic access request → granted=\(granted)") }
        arbiter.onStatus = { [weak self] in self?.menuBar.update(status: $0) }
        arbiter.onHistoryChanged = { [weak self] in self?.menuBar.refreshHistory() }
        arbiter.onDictationBegan = { Task { await SpeechJobManager.shared.beginDictation() } }
        arbiter.onDictationEnded = { Task { await SpeechJobManager.shared.endDictation() } }
        arbiter.onCommand = { [weak self] text, context in self?.routeCommand(text, context: context) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await SpeechJobManager.shared.configure(
                play: { [weak self] text, voice, onStart in
                    await self?.arbiter.playSentence(text: text, voiceID: voice, onStart: onStart) ?? false
                },
                prefetch: { [weak self] text, voice in Task { @MainActor in self?.arbiter.prefetchSentence(text: text, voiceID: voice) } },
                halt: { [weak self] in Task { @MainActor in self?.arbiter.haltSpeech() } })
        }

        menuBar.sttHistoryProvider = { [weak self] in self?.arbiter.sttHistory ?? [] }
        menuBar.commandHistoryProvider = { [weak self] in self?.arbiter.commandHistory ?? [] }
        menuBar.onRetrySTT = { [weak self] in self?.arbiter.retrySTT(id: $0) }
        menuBar.onCopySTT = { [weak self] in self?.arbiter.copySTT(id: $0) }
        menuBar.onRetryCommand = { [weak self] in self?.arbiter.retryCommand(id: $0) }
        menuBar.onCopyCommand = { [weak self] in self?.arbiter.copyCommand(id: $0) }
        menuBar.onSpeakClipboard = { [weak self] in self?.arbiter.speakClipboard() }
        menuBar.onSummarizeClipboard = { [weak self] in self?.arbiter.summarizeClipboard() }
        menuBar.onMuteSpeech = { muted in Task { await SpeechJobManager.shared.setMuted(muted) } }
        menuBar.onRestart = { Relauncher.restartAfterTermination() }
        menuBar.launchAtLoginState = { LaunchAtLogin.isEnabled }
        menuBar.onToggleLaunchAtLogin = { LaunchAtLogin.toggle() }

        hotkey.onStart = { [weak self] mode, trace in self?.arbiter.beginDictation(mode: mode, trace: trace) }
        hotkey.onStop = { [weak self] in self?.arbiter.endDictation(context: Self.frontmostContext()) }
        hotkey.onRepaste = { [weak self] in self?.arbiter.repasteLast() }
        hotkey.onSpeakClipboard = { [weak self] in self?.arbiter.speakClipboard() }
        hotkey.onSummarizeClipboard = { [weak self] in self?.arbiter.summarizeClipboard() }
        installHotkeyWhenTrusted()
        do { try speechService.start() } catch { Log.log("speech HTTP start failed: \(error)") }
        // Dial the Baseten connection and fetch the token/dictionary now, so the
        // first dictation of the session doesn't pay for any of it.
        arbiter.prewarm()
        menuBar.update(status: .idle)
    }

    func applicationWillTerminate(_ notification: Notification) { speechService.stop() }

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
