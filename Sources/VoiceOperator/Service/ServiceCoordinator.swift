import Foundation

/// Service mode (`--service --home <dir>`, see `ServiceMode` and DESIGN.md
/// "Service mode"): the speech engine without the app around it, for another
/// program to run as its own private instance.
///
/// What runs: the loopback HTTP API (status, speech on a device, remote
/// transcription), the hands-free socket (streams and speaker devices), on-device
/// Parakeet, and a Kokoro server of its own as a child process. What does not:
/// the menu bar, hotkeys, the Mac's microphone and speakers (no cues, no
/// playback, no permission prompts), Wispr, clean-up, voice mode, subscribers,
/// launch at login and the restart machinery. SIGTERM or SIGINT stops it cleanly.
@MainActor
final class ServiceCoordinator {
    private let speechService = SpeechHTTPService()
    private lazy var kokoro = KokoroService(isBusy: { DeviceSpeech.shared.isSpeaking || HandsFreeService.shared.isBusy })
    private var signals: [DispatchSourceSignal] = []

    func start() {
        Log.log("Voice Operator service starting — \(BuildInfo.summary), home \(ServiceMode.home?.path ?? "?"), Kokoro port \(KokoroService.port)")
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.stop(signal: sig) } }
            source.resume()
            signals.append(source)
        }
        speechService.snapshot = { [unowned self] in
            .init(status: .idle, dictating: false, speaking: DeviceSpeech.shared.isSpeaking, restart: .none,
                  stream: .streaming, remoteTranscriptions: RemoteTranscriptionManager.shared.activity.active,
                  provider: .parakeet, shadow: nil, incognito: false, kokoro: kokoroState())
        }
        // Kokoro's progress, in the log (the menu shows it in the app).
        var lastPhase: KokoroService.Phase?
        kokoro.onChange = { [unowned self] in
            guard kokoro.phase != lastPhase else { return }
            lastPhase = kokoro.phase
            Log.log("service: kokoro \(kokoroState().state)\(kokoroState().detail.map { " — \($0)" } ?? "")")
        }
        let handsFree = HandsFreeService.shared
        handsFree.host.speakers = false
        do { try handsFree.start() } catch { Log.log("service: hands-free could not start: \(error)") }
        do { try speechService.start() } catch { Log.log("service: speech HTTP could not start: \(error)") }
        // Load Parakeet now (the first run downloads its model), not at the first words.
        Task { if let problem = await TranscriptionProviders.primary.prewarm() { Log.log("service: Parakeet: \(problem)") } }
        kokoro.autoStart()
        // Health is otherwise only asked after an action; a server that died and came back shows here.
        healthTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.kokoro.isWorking else { return }
                Task { await self.kokoro.refreshHealth() }
            }
        }
    }
    private var healthTimer: Timer?

    /// The main run loop, for good: the service ends by `exit` from its signal handler.
    nonisolated static func runForever() -> Never {
        while true { RunLoop.main.run() }
    }

    /// Kokoro as `/v1/status` reports it.
    private func kokoroState() -> (state: String, detail: String?) {
        switch kokoro.phase {
        case .working(let step): return (kokoro.action == .install ? "installing" : "starting", step)
        case .failed(let why): return ("failed", why)
        case .idle:
            if kokoro.health != nil { return ("ready", nil) }
            return kokoro.isInstalled ? ("starting", nil) : ("missing", kokoro.paths.bundled == nil ? "no bundled server" : nil)
        }
    }

    private func stop(signal sig: Int32) {
        Log.log("service: \(sig == SIGTERM ? "SIGTERM" : "SIGINT") — stopping")
        HandsFreeService.shared.stop()
        speechService.stop()
        kokoro.stopChild()
        Log.log("service: stopped")
        exit(0)
    }
}
