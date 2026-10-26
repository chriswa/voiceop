#if os(iOS)
import AVFoundation
import AudioToolbox
import CallKit
import UIKit

/// What the engine talks to in place of the page it was written for: what it
/// sent the page goes here, and the host carries it on (Spaceterm's
/// NativeMicrophone.swift turns each into the same `window.spacetermNativeMicrophone`
/// call as before). "The page" in the comments below is the host.
@MainActor public protocol VoiceAudioEngineHost: AnyObject {
    /// Captured audio, 16 kHz s16le mono, about a tenth of a second at a time.
    /// Back-pressure — a host that is not taking it — is the host's to handle.
    func engine(_ e: VoiceAudioEngine, captured pcm16k: Data)
    /// The engine's state, on every change and every 2 s.
    func engine(_ e: VoiceAudioEngine, state: [String: Any])
    /// A sentence of speech `started`, `finished` or `failed`: `{id, index, event, outputDb?}`.
    func engine(_ e: VoiceAudioEngine, speech: [String: Any])
    /// A line for the host's log (also NSLog'd, `[native-mic] …`).
    func engine(_ e: VoiceAudioEngine, log: String)
    /// One event for the host's audio and lifecycle record.
    func engine(_ e: VoiceAudioEngine, record kind: String, detail: [String: Any])
    /// The host's own (e.g. WebKit's) microphone is closed. While it is open the engine
    /// starts nothing (see `pageMicrophoneOpen`); call `pageMicrophoneClosed()` when it closes.
    var pageMicrophoneCaptureIdle: Bool { get }
    /// The host's microphone's state for the record: `none`, `active`, `muted`, or `no page`.
    var pageMicrophoneState: String { get }
}

public extension VoiceAudioEngineHost {
    var pageMicrophoneState: String { pageMicrophoneCaptureIdle ? "none" : "active" }
}

/// Moved from Spaceterm's `src/mobile/ios/SpacetermMobile/NativeMicrophone.swift`
/// (2026-10-24), which is now an adapter between it and the page. What follows
/// is that file's own account, unchanged.
///
/// The microphone, held by the app rather than the page — what hands-free mode
/// listens to (src/mobile/native-microphone.ts, hands-free.ts).
///
/// The page cannot do this itself: WebKit holds a microphone only in
/// play-and-record, whose default route is the earpiece, so Control's answers
/// would come out as a whisper; and it opens one only inside a tap. Here the
/// session is play-and-record *defaulting to the speaker*, and *mixing* with
/// the page's own audio — without `mixWithOthers` the page's sound interrupted
/// the recording for good (spike/native-audio-test, October 2026). The
/// background audio mode keeps it recording with the screen locked.
///
/// While it runs, nothing on the page may open its own microphone: iOS lets
/// one recorder win, and this one never got the microphone back.
///
/// Audio goes to the page as 16 kHz signed 16-bit mono, base64, a tenth of a
/// second at a time. Nothing is kept here.
///
/// It also plays Control's voice, while it runs (`speech-play`), through the
/// same engine with Apple's voice processing on — the echo cancellation a
/// speakerphone call uses. Echo cancellation can only take out what it knows
/// is being played, and audio the page plays goes through WebKit's own
/// process, out of its sight; played here, Control's voice is subtracted from
/// what the microphone hears, so hands-free can listen through it and the
/// user can interrupt with "Control". Each sentence's start and end go back
/// to the page, which tells the server how far the listener got.
///
/// And it keeps the app awake while this phone holds Control (`stay-awake`).
/// iOS suspends an app in the background unless its audio is running, and
/// with the app goes the page and its connection to the server, so Control
/// fell silent the moment the phone was locked or put away. Without the
/// microphone the engine runs to play alone (`Mode.speaker`): silence, and
/// Control's voice when it has something to say.
@MainActor
public final class VoiceAudioEngine {
    /// Where everything the page was told goes now.
    public weak var host: VoiceAudioEngineHost?
    /// Captured audio for a second listener beside the host — `HandsFreeSession`'s.
    public var captureObserver: ((Data) -> Void)?
    /// What the player is playing has changed: see `playback`. `HandsFreeSession`'s.
    public var onPlaybackChange: (() -> Void)?
    /// Each sentence of speech `started`, `finished` or `failed`, as the host is told it,
    /// for a second listener beside the host — `SpeakerSession`'s.
    public var speechObserver: ((_ id: String, _ index: Int, _ event: String) -> Void)?
    /// The `UserDefaults` key an open AirPods incident is kept under across launches; nil keeps none.
    private let badStateDefaultsKey: String?

    /// A new engine for every bring-up: one kept across an AirPods route change
    /// kept its old format and delivered nothing.
    private var engine = AVAudioEngine()
    private let capture = Converter()
    /// The page wants the microphone: hands-free.
    private var wanted = false
    /// The page wants the app kept running in the background: this phone holds Control.
    private var stayAwake = false
    /// What the engine is up for: listening (and playing), only playing, or nothing.
    private enum Mode: String { case off, speaker, microphone }
    /// What the engine should be up for. The microphone, when wanted, plays Control's voice too.
    /// Kept up after a dictation without Control held too, to keep other audio down for `duckHoldSeconds`.
    private var mode: Mode { wanted ? .microphone : stayAwake || duckingAfterDictation ? .speaker : .off }
    /// What the engine is up for now.
    private var up = Mode.off
    /// The microphone is running — what the page means by `running`.
    private var running: Bool { up == .microphone }
    private var timer: Timer?
    private var pendingRestart: DispatchWorkItem?
    private var lastBringUp = Date.distantPast
    private var lastError: String?
    private var observers: [NSObjectProtocol] = []
    private var tick = 0
    /// Control's voice, playing through the engine: see `SpeechQueue`.
    private var player: AVAudioPlayerNode?
    private var speech = SpeechQueue()
    /// Bumped whenever scheduled buffers are thrown away, so their late completions are ignored.
    private var speechGeneration = 0
    /// Whether this bring-up got voice processing (echo cancellation); false where it would not turn on.
    private var voiceProcessing = false
    /**
     * Whether to ask for voice processing at all. Turning it on reconfigures
     * the audio hardware, and iOS announces that as a configuration change;
     * answered with a new engine, that is a loop (October 2026: a restart
     * every 1.5 s, and no audio ever reached the page). Changes are answered
     * in place now; if they loop anyway, this goes false for the rest of the
     * app's run, and the microphone carries on without echo cancellation.
     */
    private var voiceProcessingAllowed = true
    /// Recent configuration changes, for telling a loop from a one-off.
    private var configChanges: [Date] = []
    private static let configLoopWindow: TimeInterval = 10
    private static let configLoopLimit = 3
    /// When the engine last started, and which start that was, for the audio check after it.
    private var lastStart = Date.distantPast
    private var startNumber = 0
    /// When `recover` last tried, so an engine that will not start is not hammered.
    private var lastRecovery = Date.distantPast
    private let calls = CXCallObserver()

    private static let sendInterval: TimeInterval = 0.1
    /// No taps, or nothing but digital silence, for this long: start again.
    private static let stallSeconds: Double = 2
    private static let minSecondsBetweenRebuilds: TimeInterval = 3
    /// Restarts for one stall: how many so far, and when the last was. Cleared once sound flows again.
    private var stallRestarts = 0
    private var lastStallRestart = Date.distantPast
    /// The stall now, if any, as last recorded.
    private var currentStall: Converter.Stall?
    /// Microphone starts that failed in a row, for the delay before the next.
    private var failedStarts = 0
    /// Hands-free starts refused in a row for coming up on the AirPods' 48 kHz link.
    private var wideStarts = 0
    /// An interruption with no end heard by then is taken to have none coming.
    private static let interruptionGraceSeconds: TimeInterval = 1

    public init(badStateDefaultsKey: String? = nil) {
        self.badStateDefaultsKey = badStateDefaultsKey
        observe()
    }

    /// The microphone is wanted (`start` since the last `stop`).
    public var microphoneWanted: Bool { wanted }

    // MARK: - From the page

    /// One message from the page, by its `action`, with the rest of its body.
    public func handle(command action: String, body: [String: Any]) {
        switch action {
        // `mute`: a dictation's microphone, which turns other audio down while it is open (`forDictation`);
        // hands-free's held one does not. The key's name is from when it stopped it.
        // (`duck` is what a page from before October 13 2026 sends for the same.)
        // (`highQuality`, from a page of October 12 2026, is ignored: see `Plan`.)
        case "start": start(
            forDictation: (body["mute"] ?? body["duck"]) as? Bool ?? false
        )
        case "stop": stop()
        // Control is thinking or speaking aloud here: other apps' audio — music — turned down meanwhile.
        case "duck-others": setDuckForControl(body["on"] as? Bool ?? false)
        // Hands-free is taking a dictation down: other audio turned down meanwhile (`voiceDucking`).
        case "hands-free-dictating": setDuckForHandsFree(body["on"] as? Bool ?? false)
        // A page that has just loaded wants the state now — for the output badge — not at the next change.
        case "state": sendState()
        case "stay-awake": setStayAwake(body["on"] as? Bool ?? false)
        // The microphone's states, felt rather than heard: see `playHaptic`.
        case "haptic": playHaptic(body["pattern"] as? String ?? "tap")
        case "speech-play": playSpeech(body)
        case "speech-stop": stopSpeech(id: body["id"] as? String ?? "")
        // Someone started talking over Control: quieter until it is known whether they said "Control".
        case "speech-duck": duckSpeech(body["on"] as? Bool ?? false)
        // A tone of hands-free's, played here so the Ring/Silent switch does not silence it: see `playCue`.
        case "cue": playCue(body)
        // Hands-free's beep while it decides about what may be speech, or Control's thinking sonar, repeated until told to stop: see `startPendingTone`.
        case "pending-tone":
            if body["on"] as? Bool == true { startPendingTone(body) } else { stopPendingTone() }
        default: log("unknown action \(action)")
        }
    }

    private func start(forDictation: Bool) {
        wanted = true
        self.forDictation = forDictation
        if !forDictation { noteHeadphones() }
        // A new attempt: the page waits for running or an error, and an old error would answer it.
        lastError = nil
        if running {
            // A reloaded page asking again: it needs to hear the state.
            sendState()
            return
        }
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in
                guard self.wanted else { return }
                if granted { self.bringUp(why: "asked by the page") } else { self.fail("microphone permission refused") }
            }
        }
    }

    private func stop() {
        wanted = false
        // Other audio stays stopped a little longer: Control is about to think, and music swelling in the gap was jarring.
        if forDictation { holdDucking() }
        forDictation = false
        let was = up
        record("native-mic-stopped")
        if was == .microphone { log("stopped") }
        // Still holding Control, or holding other audio stopped a moment longer: on without the microphone.
        if mode == .speaker {
            if was != .speaker { bringUp(why: "the microphone was turned off") }
        } else {
            tearDown(why: "the microphone was turned off")
        }
    }

    private func setStayAwake(_ on: Bool) {
        guard on != stayAwake else { return }
        stayAwake = on
        record("native-stay-awake", ["on": on, "mode": mode.rawValue])
        log(on ? "this phone holds Control: staying awake in the background" : "this phone no longer holds Control")
        // The microphone keeps the app awake already; only a bare engine comes and goes.
        if wanted { return }
        // Off may leave it up for a moment yet: the hold on other audio after a dictation.
        if on { bringUp(why: "this phone holds Control") } else { reconcileNow("this phone no longer holds Control") }
    }

    /// Everything off, the audio session given back.
    private func tearDown(why: String) {
        guard !transitioning else {
            queue(why)
            return
        }
        pendingRestart?.cancel()
        pendingRestart = nil
        timer?.invalidate()
        timer = nil
        // No engine, no voice: whatever was still to be said will not be.
        failSpeech(why: why)
        player = nil
        cuesPlaying = []
        let old = engine, hadTap = up == .microphone
        up = .off
        transitioning = true
        sendState()
        audioQueue.async {
            old.stop()
            if hadTap { old.inputNode.removeTap(onBus: 0) }
            // Others are told they may play again: music this app turned down comes back up.
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.sessionOthers = nil
                    self.sessionOnHeadphones = false
                    self.finishTransition()
                }
            }
        }
    }

    // MARK: - Engine

    /**
     * Activating the audio session and starting the engine block until the
     * audio hardware is ready: one to two seconds while AirPods change
     * profile. On the main thread that froze the screen for as long after
     * every dictation, when the engine kept for staying awake started again
     * (October 2026, "[frames] none for 1981ms" exactly spanning
     * `restartInPlace`). So they run on this queue, one change at a time. The
     * main thread plans each change and takes in its result; while one runs
     * (`transitioning`) it touches no engine, and any change asked for
     * meanwhile waits for it (`queue`).
     */
    private let audioQueue = DispatchQueue(label: "spaceterm.native-audio", qos: .userInitiated)
    private var transitioning = false
    /// Asked for during a change: why, and whether any of it needed a new engine.
    private var queued: (why: String, newEngine: Bool)?

    /// Whether the engine is running, without waiting on one mid-change.
    private var engineRunning: Bool { !transitioning && engine.isRunning }

    private func queue(_ why: String, newEngine: Bool = false) {
        queued = (why, newEngine || queued?.newEngine == true)
    }

    private func finishTransition() {
        transitioning = false
        guard let next = queued else { return }
        queued = nil
        reconcile(why: next.why, newEngine: next.newEngine)
    }

    /// After a change, whatever was asked for meanwhile: the engine made to match what is wanted now.
    private func reconcile(why: String, newEngine: Bool) {
        if mode == .off {
            if up != .off || sessionOthers != nil { tearDown(why: why) }
        } else if newEngine || up != mode || sessionOthers != others {
            bringUp(why: why)
        } else if !engine.isRunning {
            restartInPlace(why: why)
        }
    }

    /**
     * What this app's session does to other apps' audio — music: plays
     * alongside it, or turns it down. Down while a dictation's microphone is
     * open and for `duckHoldSeconds` after, and while Control thinks and
     * speaks aloud here (`duck-others`); leaving that deactivates the session
     * with `notifyOthersOnDeactivation`, which lets music back up.
     *
     * Never stopped. iOS has no way for one app to mute another: the only
     * "stop" is a non-mixable session, which interrupts it, and Spotify takes
     * an interruption as a pause. That was the dictation's "mute" from
     * October 12 to 13 2026 — a pause, resumed by the notification after.
     * Hands-free's held microphone leaves the session alone throughout and
     * turns music down through voice processing instead: see `others`.
     */
    private enum Others: String { case mix, duck }
    private var others: Others {
        // Hands-free's held microphone is never brought up again for other audio's sake. Each change
        // deactivates the session between, which dropped the AirPods out of their microphone link
        // (a blip of music each time), left the microphone delivering nothing for ten seconds or
        // more, and — with the screen locked — lost it for good: iOS will not let an app in the
        // background start recording again (October 2026, every hands-free turn).
        // On headphones hands-free runs as a dictation does — no voice processing, music turned down for
        // the whole session — since voice processing is what paused Spotify (`headphones`).
        if wanted { return forDictation || holdOnHeadphones ? .duck : .mix }
        if duckingAfterDictation { return .duck }
        return duckForControl ? .duck : .mix
    }
    /// What the active session was activated with; nil while it is not active. iOS applies it only on activation.
    private var sessionOthers: Others?
    private var forDictation = false
    private var duckForControl = false
    /**
     * Hands-free is on headphones: decided when it starts, and again only
     * when a headset comes or goes — not read off the route each time, which
     * flickers to the earpiece while the link changes and would bring the
     * engine up again for nothing. See `Plan.headphones`.
     */
    private var holdOnHeadphones = false
    /// The running engine came up for hands-free on headphones, without voice processing.
    private var sessionOnHeadphones = false

    private func noteHeadphones() {
        let session = AVAudioSession.sharedInstance()
        holdOnHeadphones = Self.headphones(session.currentRoute)
            || (session.availableInputs ?? []).contains { Self.isBluetooth($0) || $0.portType == .headsetMic }
    }
    /// A dictation has just ended: other audio stays down until `duckHold` runs out.
    private var duckingAfterDictation = false
    private var duckHold: DispatchWorkItem?
    private static let duckHoldSeconds: TimeInterval = 2

    private func holdDucking() {
        duckingAfterDictation = true
        duckHold?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.duckHold = nil
                self.duckingAfterDictation = false
                self.record("native-duck-hold-ended", ["up": self.up.rawValue, "others": self.others.rawValue])
                self.reconcileNow("the hold on other audio ran out")
            }
        }
        duckHold = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duckHoldSeconds, execute: work)
    }

    private func setDuckForControl(_ on: Bool) {
        guard on != duckForControl else { return }
        duckForControl = on
        record("native-duck-others", ["on": on, "for": "control", "up": up.rawValue, "others": others.rawValue, "otherAudioPlaying": AVAudioSession.sharedInstance().isOtherAudioPlaying])
        // Control starting to think mid-dictation, or in the hold after: still stopped, nothing to change.
        guard !transitioning else {
            queue("other audio's treatment changed")
            return
        }
        applyVoiceDucking()
        guard mode != .off, up != .off, sessionOthers != others else { return }
        bringUp(why: others == .duck ? "turning other audio down" : "letting other audio back up")
    }

    /**
     * Music under hands-free. Its held microphone's session is never changed
     * for other audio (`others`), but voice processing ducks other audio
     * itself, by a level that can be changed on the running engine — no
     * session change, no restart, the AirPods' link untouched, and so in the
     * background too. Down only while hands-free takes a dictation down, at
     * its least otherwise: down for Control's turns too, the music was down
     * nearly the whole of a conversation (October 13).
     */
    private var duckForHandsFree = false
    private var voiceDucking: Bool { wanted && !forDictation && duckForHandsFree }
    /// The level last set on the running engine's voice processing; nil when none is set.
    private var appliedVoiceDucking: Bool?

    private func setDuckForHandsFree(_ on: Bool) {
        guard on != duckForHandsFree else { return }
        duckForHandsFree = on
        record("native-duck-others", ["on": on, "for": "hands-free", "up": up.rawValue, "otherAudioPlaying": AVAudioSession.sharedInstance().isOtherAudioPlaying])
        applyVoiceDucking()
    }

    /// Set voice processing's ducking of other audio on the running engine, if it has voice processing.
    /// Mid-change, the engine coming up takes it from its plan.
    private func applyVoiceDucking() {
        guard #available(iOS 17.0, *), !transitioning, up == .microphone, voiceProcessing else { return }
        let on = voiceDucking
        guard on != appliedVoiceDucking else { return }
        appliedVoiceDucking = on
        let input = engine.inputNode
        audioQueue.async {
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: on ? .max : .min)
        }
        record("native-voice-ducking", ["on": on, "otherAudioPlaying": AVAudioSession.sharedInstance().isOtherAudioPlaying])
    }

    /// The engine made to match what is wanted now, or once the change running has finished.
    private func reconcileNow(_ why: String) {
        if transitioning { queue(why) } else { reconcile(why: why, newEngine: false) }
    }

    private func bringUp(why: String) {
        guard !transitioning else {
            queue(why, newEngine: true)
            return
        }
        let mode = self.mode
        guard mode != .off else { return }
        lastBringUp = Date()
        noteOtherAudio()
        let old = engine, oldUp = up, hadTap = up == .microphone
        /**
         * Switching the active session between playback and play-and-record
         * pauses Spotify, and it stays paused until a deactivation lets it
         * carry on (October 13, 01:30: the music cut out for the tone and
         * Control's voice after a dictation, and was gone for the next).
         * Leaving the microphone, the session is given up first. Going to
         * hands-free's microphone from the engine kept up for Control, it is
         * given up too, with `releasePause` before the microphone — given up
         * and the microphone at once was what brought the AirPods up dead.
         * Not for a dictation, which must start at once: from that engine it
         * still switches in place, and pauses Spotify.
         */
        let leavingMicrophone = oldUp == .microphone && mode == .speaker
        let releaseBeforeHandsFree = oldUp == .speaker && mode == .microphone && !forDictation
            && UIApplication.shared.applicationState == .active
        // Its player goes with it; the new engine's comes back in `broughtUp`.
        player = nil
        cuesPlaying = []
        // Made here so a configuration change it announces while starting is known to be its own.
        let engine = AVAudioEngine()
        self.engine = engine
        up = .off
        transitioning = true
        let plan = Plan(
            microphone: mode == .microphone, others: others,
            /**
             * A change to what other audio gets applies only with a deactivation between, which lets music
             * back up — but never just before the microphone comes up. A deactivation followed at once by
             * play-and-record brought the AirPods' microphone link up at 48 kHz sending only zeros, every
             * time it happened (October 12–13: 23:30, 00:02, 00:03, and both 00:26 and 00:29 hands-free
             * starts, after which the AirPods needed the iPhone restarting); started without one, it came
             * up at 24 kHz and heard. So a microphone keeps the treatment the session was activated with
             * until its next activation, and music is only let back up when the microphone goes.
             */
            deactivateFirst: (mode != .microphone && sessionOthers != nil && (sessionOthers != others || leavingMicrophone))
                || releaseBeforeHandsFree,
            releasePause: releaseBeforeHandsFree ? Self.releasePauseSeconds : 0,
            voiceDucking: voiceDucking,
            // Echo cancellation is for hands-free, which listens through Control's voice. A dictation
            // stops Control first, so it goes without, and without voice processing's ways with the route.
            voiceProcessingAllowed: voiceProcessingAllowed && !(mode == .microphone && forDictation),
            headphones: mode == .microphone && !forDictation && holdOnHeadphones,
            dictation: mode == .microphone && forDictation
        )
        let capture = self.capture
        audioQueue.async {
            let result = Result { try Self.start(engine, plan, stopping: old, hadTap: hadTap, capture: capture) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.broughtUp(engine, mode: mode, plan: plan, result: result, why: why) }
            }
        }
    }

    private struct Plan {
        let microphone: Bool
        let others: Others
        let deactivateFirst: Bool
        /// Seconds between giving the session up and taking it again: see `bringUp`.
        let releasePause: TimeInterval
        /// Voice processing's ducking of other audio, at its most rather than its least (`voiceDucking`).
        let voiceDucking: Bool
        let voiceProcessingAllowed: Bool
        /**
         * Hands-free on headphones goes without voice processing, as a
         * dictation does. Its voice-chat mode is what paused Spotify for the
         * whole of hands-free (October 13: a dictation, without it, had
         * Spotify play on, turned down, for a minute and a half), and in an
         * ear nothing played leaks into the microphone for it to cancel —
         * Control's voice included, so hands-free still listens through it
         * (`echoFree`, sent to the page). On the phone's own speaker it stays.
         */
        let headphones: Bool
        /// A tap's dictation: no voice processing, and asks for high-quality recording on AirPods (see `start`).
        let dictation: Bool
    }

    private struct Started {
        let player: AVAudioPlayerNode
        let voiceProcessing: Bool
        let voiceProcessingError: String?
        let sampleRate: Double
        /// How long the blocking part took, from the old engine stopping to the new one running.
        let ms: Int
        /// Whether high-quality recording was asked for, refused, supported by the input, and on.
        var highQuality: [String: Any] = [:]
        /// Quick re-activations of a start that came up on the AirPods' 48 kHz link, each with what it got.
        var rateTries: [[String: Any]] = []
    }

    /// The blocking part of a bring-up, on `audioQueue`: the old engine stopped, the session set and activated, `engine` started.
    nonisolated private static func start(_ engine: AVAudioEngine, _ plan: Plan, stopping old: AVAudioEngine, hadTap: Bool, capture: Converter) throws -> Started {
        let began = Date()
        let ms = { Int(Date().timeIntervalSince(began) * 1000) }
        old.stop()
        // The input node is made on first use: touched on an engine that never recorded, it would make one.
        if hadTap { old.inputNode.removeTap(onBus: 0) }
        let session = AVAudioSession.sharedInstance()
        if plan.deactivateFirst {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            if plan.releasePause > 0 { Thread.sleep(forTimeInterval: plan.releasePause) }
        }
        // Always `mixWithOthers`: without it, activating the session would interrupt — pause — other audio.
        var options: AVAudioSession.CategoryOptions
        switch plan.others {
        case .mix: options = [.mixWithOthers]
        case .duck: options = [.mixWithOthers, .duckOthers]
        }
        if !plan.microphone {
            // Playback alone, which records nothing and so shows no microphone in use.
            try session.setCategory(.playback, mode: .default, options: options)
            try session.setActive(true)
            let player = attachPlayer(to: engine)
            engine.prepare()
            try engine.start()
            return Started(player: player, voiceProcessing: false, voiceProcessingError: nil, sampleRate: 0, ms: ms())
        }
        options.formUnion([.defaultToSpeaker, .allowBluetooth])
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        // iOS silences haptics while recording unless told otherwise; hands-free's cue is one.
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        // The rate voice processing has worked at over AirPods, and that hands-free's best sessions ran at.
        try? session.setPreferredSampleRate(Self.voiceProcessingRate)
        try session.setActive(true)
        /**
         * Hands-free never runs on the AirPods' 48 kHz link. Even when it hears
         * (with high-quality recording asked for), it is a link that knocks out
         * Spotify, which hands-free plays under; and it comes up on its own
         * often (October 25: nine of fifteen starts). The 24 kHz link has heard
         * every time. A start that comes up wide is activated again straight
         * away — every retry on October 25 that came after one, with the AirPods
         * already switched over by it, landed on 24 kHz — a few times, each
         * recorded with whether other audio was playing either side of it, since
         * too many deactivations may be what leaves Spotify paused. Still wide,
         * the start is refused (`WideBluetooth`), and `broughtUp` tries again
         * shortly. Each re-activation takes the AirPods back to their music
         * link and out again — about 2.3 s, Spotify flipping in and out — so
         * this is for hands-free, which is worth waiting for. A dictation takes
         * whichever link comes up (see the category above).
         */
        var rateTries: [[String: Any]] = []
        if plan.microphone, !plan.dictation, isBluetooth(session.currentRoute.inputs.first) {
            while session.sampleRate > Self.voiceProcessingRate, rateTries.count < Self.quickRateRetries {
                let rate = session.sampleRate
                let otherBefore = session.isOtherAudioPlaying
                let hintBefore = session.secondaryAudioShouldBeSilencedHint
                // No `notifyOthersOnDeactivation`: the session is taken straight back, and telling
                // other apps it was let go is what invites them to stop or resume.
                try? session.setActive(false)
                Thread.sleep(forTimeInterval: Self.quickRateRetryPause)
                try session.setActive(true)
                rateTries.append([
                    "try": rateTries.count + 1, "rateBefore": rate, "rateAfter": session.sampleRate,
                    "otherAudioBefore": otherBefore, "otherAudioAfter": session.isOtherAudioPlaying,
                    "silenceHintBefore": hintBefore, "silenceHintAfter": session.secondaryAudioShouldBeSilencedHint,
                    "route": describeRoute(session.currentRoute),
                ])
            }
            if session.sampleRate > Self.voiceProcessingRate {
                throw WideBluetooth(rate: session.sampleRate, tries: rateTries)
            }
        }
        /**
         * A dictation come up at more than 24 kHz on AirPods: ask for iOS 26's
         * AirPods high-quality recording, on the active session. On the 48 kHz
         * link the microphone sent only exact zeros unless this had been asked
         * for — every such start (October 12–13; and every dictation on October
         * 13, 15, 23 and nine of fifteen on October 25, each costing the
         * two-second wait for sound and a retry) — while every 48 kHz start that
         * asked for it heard. Hands-free asked too, until it stopped taking that
         * link at all (above); a dictation takes it, since nobody listens to
         * music through one.
         */
        var highQuality: [String: Any] = ["asked": false, "rateAtActivation": session.sampleRate]
        if #available(iOS 26.0, *), let port = session.currentRoute.inputs.first, let bluetooth = port.bluetoothMicrophoneExtension {
            highQuality["supportedAtActivation"] = bluetooth.highQualityRecording.isSupported
            highQuality["enabledAtActivation"] = bluetooth.highQualityRecording.isEnabled
        }
        /**
         * A dictation that came up on the AirPods' 48 kHz link asks for their
         * high-quality recording, without which that link sends only exact
         * zeros (every such start, October 13–25). Only then: asked for up
         * front, every start paid for it — 3.2–4.2 s against about 1 s for a
         * plain one, at 24 kHz or 48 (October 25) — and about half come up at
         * 24 kHz without it. Re-activating for 24 kHz instead costs about
         * 2.3 s a try, flipping Spotify in and out (three tries: 11 s,
         * 19:02:39); that is hands-free's way, not a tap's.
         */
        if plan.dictation, #available(iOS 26.0, *), session.sampleRate > Self.voiceProcessingRate,
           isBluetooth(session.currentRoute.inputs.first) {
            highQuality["asked"] = true
            highQuality["rateBefore"] = session.sampleRate
            let asked = Date()
            do {
                try session.setCategory(.playAndRecord, mode: .default, options: options.union(.bluetoothHighQualityRecording))
                try session.setActive(true)
            } catch {
                highQuality["refused"] = error.localizedDescription
            }
            highQuality["ms"] = Int(Date().timeIntervalSince(asked) * 1000)
            if let port = session.currentRoute.inputs.first, let bluetooth = port.bluetoothMicrophoneExtension {
                highQuality["supported"] = bluetooth.highQualityRecording.isSupported
                highQuality["enabled"] = bluetooth.highQualityRecording.isEnabled
            }
            highQuality["rateAfter"] = session.sampleRate
        }
        let input = engine.inputNode
        /**
         * Voice processing over a Bluetooth route faster than 24 kHz sent only
         * exact zeros, every time (October 12–13 2026: the AirPods' route came
         * up at 48 kHz and every voice-processed start was silent, while 24 kHz
         * ones heard, and 48 kHz ones without voice processing heard too). So
         * there it is left off, and said so: no echo cancellation, and no
         * ducking of music through it, but a microphone that hears.
         */
        let sessionRate = session.sampleRate
        let wideBluetooth = sessionRate > Self.voiceProcessingRate && isBluetooth(session.currentRoute.inputs.first)

        // Echo cancellation, against what the player plays. Set before anything is connected.
        var voiceProcessing = false
        var voiceProcessingError: String?
        if plan.voiceProcessingAllowed, !wideBluetooth, !plan.headphones {
            do {
                try input.setVoiceProcessingEnabled(true)
                voiceProcessing = true
                // Its default turns every other app's audio — and the page's cues — right down.
                if #available(iOS 17.0, *) {
                    input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: plan.voiceDucking ? .max : .min)
                }
            } catch {
                voiceProcessingError = error.localizedDescription
            }
        } else if plan.voiceProcessingAllowed, wideBluetooth {
            voiceProcessingError = "left off: a Bluetooth route at \(Int(sessionRate)) Hz, where it hears only silence"
        }
        let player = attachPlayer(to: engine)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw Failure("the input has no format (sample rate 0)") }
        capture.reset(converter: AVAudioConverter(from: format, to: Converter.outFormat))
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in capture.handle(buffer) }
        engine.prepare()
        try engine.start()
        return Started(player: player, voiceProcessing: voiceProcessing, voiceProcessingError: voiceProcessingError, sampleRate: format.sampleRate, ms: ms(), highQuality: highQuality, rateTries: rateTries)
    }

    /// Hands-free's start came up on the AirPods' 48 kHz link and stayed there through the quick re-activations.
    private struct WideBluetooth: LocalizedError {
        let rate: Double
        let tries: [[String: Any]]
        var errorDescription: String? { "the AirPods' microphone came up at \(Int(rate)) Hz; hands-free waits for 24 kHz" }
    }

    /// Quick re-activations of a start that came up wide, and the pause in each.
    private static let quickRateRetries = 3
    private static let quickRateRetryPause: TimeInterval = 0.15
    /// After a start still refused as wide: tried again this soon, then less often, to this.
    private static let wideRetryFirst: TimeInterval = 0.5
    private static let wideRetryMax: TimeInterval = 8

    /// The player Control's voice goes through, on a new engine.
    nonisolated private static func attachPlayer(to engine: AVAudioEngine) -> AVAudioPlayerNode {
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: SpeechQueue.format)
        return player
    }

    /// A bring-up has finished, on `audioQueue`: take in what it made, or why it failed.
    private func broughtUp(_ engine: AVAudioEngine, mode: Mode, plan: Plan, result: Result<Started, Error>, why: String) {
        transitioning = false
        let session = AVAudioSession.sharedInstance()
        switch result {
        case .success(let started):
            player = started.player
            started.player.volume = speechVolume(voiceProcessing: started.voiceProcessing)
            voiceProcessing = started.voiceProcessing
            if let error = started.voiceProcessingError { record("voice-processing-failed", ["error": error]) }
            sessionOthers = plan.others
            sessionOnHeadphones = plan.headphones
            appliedVoiceDucking = started.voiceProcessing ? plan.voiceDucking : nil
            failedStarts = 0
            if !started.rateTries.isEmpty || wideStarts > 0 {
                record("native-mic-rate", ["outcome": started.sampleRate > Self.voiceProcessingRate ? "48 kHz, high quality (a dictation)" : "24 kHz",
                                           "dictation": plan.dictation, "quickTries": started.rateTries, "refusedStartsBefore": wideStarts])
            }
            wideStarts = 0
            up = mode
            lastError = nil
            if mode == .microphone {
                noteMicrophoneStart(started, plan: plan, why: why)
                expectAudio(why)
                log("running on \(inputName()) at \(Int(started.sampleRate)) Hz, echo cancellation \(voiceProcessing ? "on" : "OFF") (\(why))")
                record("native-mic-running", ["why": why, "sampleRate": started.sampleRate, "voiceProcessing": voiceProcessing, "others": plan.others.rawValue, "ms": started.ms, "headphones": plan.headphones, "highQuality": started.highQuality, "released": plan.deactivateFirst, "route": Self.describeRoute(session.currentRoute)])
            } else {
                log("awake, playing to \(outputName()) (\(why))")
                record("native-awake-running", ["why": why, "others": plan.others.rawValue, "ms": started.ms, "released": plan.deactivateFirst, "route": Self.describeRoute(session.currentRoute)])
            }
            // A new engine: anything still to be said starts again on it, from the sentence it was in.
            rescheduleSpeech()
            sendState()
            startTimer()
            // Asked for while it came up.
            applyVoiceDucking()
            noteOtherAudio()
        case .failure(let error as WideBluetooth):
            // Not a failure of the engine: a link hands-free will not take. Again shortly, and again.
            player = nil
            voiceProcessing = false
            sessionOthers = nil
            sessionOnHeadphones = false
            wideStarts += 1
            let delay = min(Self.wideRetryMax, Self.wideRetryFirst * pow(2, Double(wideStarts - 1)))
            log("\(error.localizedDescription) — trying again in \(delay)s (refused \(wideStarts) so far)")
            record("native-mic-rate", ["outcome": "refused", "rate": error.rate, "quickTries": error.tries, "refusedStarts": wideStarts,
                                       "inSeconds": delay, "otherAudioPlaying": session.isOtherAudioPlaying,
                                       "silenceHint": session.secondaryAudioShouldBeSilencedHint, "why": why])
            scheduleRestart("the AirPods came up at \(Int(error.rate)) Hz", after: delay)
        case .failure(let error):
            player = nil
            voiceProcessing = false
            sessionOthers = nil
            sessionOnHeadphones = false
            failSpeech(why: "the audio engine would not start")
            let nsError = error as NSError
            record("native-mic-failed", ["mode": mode.rawValue, "why": why, "error": error.localizedDescription, "domain": nsError.domain, "code": nsError.code, "appState": UIApplication.shared.applicationState == .background ? "background" : "foreground"])
            fail("could not start (\(why)): \(error.localizedDescription)")
            // Tried again from here, the microphone too: the page opens it once and leaves it to this
            // (held-microphone.ts `installNativeHold`).
            // Less and less often: 2, 4, 8, 16 s, then every 30.
            failedStarts += 1
            let delay = mode == .speaker ? 5 : min(30, 2 * pow(2, Double(failedStarts - 1)))
            record("native-mic-retry", ["mode": mode.rawValue, "inSeconds": delay, "failedStarts": failedStarts])
            scheduleRestart(mode == .speaker ? "staying awake would not start" : "the microphone would not start", after: delay)
        }
        finishTransition()
    }

    /**
     * The same engine, started again after a configuration change stopped it:
     * the tap put back at whatever the input's format is now, the player and
     * whatever it was saying kept. Unlike a new engine, it does not set up
     * voice processing again — which is what announced the next change. A new
     * engine is still the answer when this will not start, and for a headset
     * coming or going (`bringUp`), which needed one.
     */
    private func restartInPlace(why: String) {
        guard !transitioning else {
            queue(why)
            return
        }
        guard mode != .off else { return }
        // Up for something else since — or not up at all: a new engine, for what is wanted now.
        // Or other audio to be treated differently since: only a new activation changes that.
        guard up == mode, sessionOthers == others else {
            bringUp(why: why)
            return
        }
        let engine = self.engine, microphone = up == .microphone, capture = self.capture
        transitioning = true
        audioQueue.async {
            let result = Result { () throws -> Double in
                var sampleRate: Double = 0
                // Stopped by iOS already, after a configuration change; running but silent, after a stall.
                engine.stop()
                if microphone {
                    let input = engine.inputNode
                    input.removeTap(onBus: 0)
                    let format = input.outputFormat(forBus: 0)
                    guard format.sampleRate > 0 else { throw NoInputFormat() }
                    sampleRate = format.sampleRate
                    capture.reset(converter: AVAudioConverter(from: format, to: Converter.outFormat))
                    input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in capture.handle(buffer) }
                }
                try AVAudioSession.sharedInstance().setActive(true)
                engine.prepare()
                try engine.start()
                return sampleRate
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.restartedInPlace(result: result, why: why) }
            }
        }
    }

    private struct NoInputFormat: Error {}

    private func restartedInPlace(result: Result<Double, Error>, why: String) {
        transitioning = false
        switch result {
        case .success(let sampleRate):
            record("native-mic-restarted-in-place", ["mode": up.rawValue, "why": why, "sampleRate": sampleRate, "voiceProcessing": voiceProcessing])
            if up == .microphone, !forDictation, sampleRate > Self.voiceProcessingRate,
               Self.isBluetooth(AVAudioSession.sharedInstance().currentRoute.inputs.first) {
                // Moved onto the 48 kHz link under a running engine: a new one, which refuses it.
                record("native-mic-rate", ["outcome": "wide in place", "rate": sampleRate, "why": why])
                finishTransition()
                bringUp(why: "the AirPods moved to \(Int(sampleRate)) Hz")
                return
            }
            if up == .microphone { expectAudio(why) }
            rescheduleSpeech()
            sendState()
            finishTransition()
        case .failure(let error) where error is NoInputFormat:
            record("native-mic-restart-in-place-failed", ["why": why, "error": "the input has no format"])
            queue("\(why), and the input had no format", newEngine: true)
            finishTransition()
        case .failure(let error):
            record("native-mic-restart-in-place-failed", ["why": why, "error": error.localizedDescription])
            queue("\(why), and it would not start in place", newEngine: true)
            finishTransition()
        }
    }

    /// A second after each start: did audio arrive? A start that delivers nothing is otherwise silent until the page gives up on it.
    private func expectAudio(_ why: String) {
        startNumber += 1
        lastStart = Date()
        let start = startNumber
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, start == self.startNumber, self.running else { return }
                let firstAudioMs = self.capture.firstAudioMs()
                self.record("native-mic-audio", [
                    "arrived": firstAudioMs != nil, "firstAudioMs": firstAudioMs ?? -1,
                    "engineRunning": self.engineRunning, "voiceProcessing": self.voiceProcessing, "why": why,
                ])
                if firstAudioMs == nil { self.log("no audio a second after starting (\(why))") }
            }
        }
    }

    /**
     * iOS changed the audio configuration, which stops the engine. Once:
     * start it again in place. Over and over with echo cancellation on: give
     * up on echo cancellation (see `voiceProcessingAllowed`).
     */
    private func configurationChanged() {
        let now = Date()
        configChanges = configChanges.filter { now.timeIntervalSince($0) < Self.configLoopWindow } + [now]
        record("audio-engine-config-change", [
            "engineRunning": engineRunning, "sinceStartMs": Int(now.timeIntervalSince(lastStart) * 1000),
            "voiceProcessing": voiceProcessing, "recentChanges": configChanges.count,
        ])
        if voiceProcessing, configChanges.count > Self.configLoopLimit {
            voiceProcessingAllowed = false
            configChanges = []
            record("voice-processing-abandoned", ["why": "configuration changes looped", "within": Self.configLoopWindow])
            log("the audio configuration keeps changing with echo cancellation on — carrying on without it until the app restarts")
            scheduleRestart("echo cancellation abandoned", after: 0.3)
            return
        }
        scheduleRestart("the audio configuration changed", after: 0.3, inPlace: true)
    }

    /// Route changes come in bursts — AirPods flap between themselves and the
    /// speaker for a second or two — so start again once, after it settles.
    /// `inPlace`: the same engine (`restartInPlace`), rather than a new one.
    private func scheduleRestart(_ why: String, after delay: TimeInterval = 0.8, inPlace: Bool = false) {
        guard mode != .off else { return }
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingRestart = nil
                // `pageMicrophoneClosed` starts it once the page is done.
                if self.pageMicrophoneOpen {
                    self.record("native-restart-deferred", ["why": why, "until": "the page's microphone closes"])
                    return
                }
                if inPlace { self.restartInPlace(why: why) } else { self.bringUp(why: why) }
            }
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /**
     * The microphone has delivered nothing, or only exact zeros, for
     * `stallSeconds`. Started again — in place first, the same session, so
     * the AirPods keep their microphone link; a new engine the second time —
     * and then less and less often (`stallBackoff`), never more than once a
     * minute. A restart did not fix it before: on October 12 the AirPods'
     * microphone sent zeros for minutes (they had gone to the Mac), and a new
     * engine every two seconds flipped the route between the earpiece and the
     * AirPods the whole time, and failed with no input format each time.
     * Zeros are told to the page (`silentInput`), which can say so.
     */
    private func noteStall(_ stall: Converter.Stall?) {
        if stall != currentStall {
            let was = currentStall
            currentStall = stall
            if let stall {
                log("the microphone is stalled: \(stall.rawValue) for \(Int(Self.stallSeconds)) s, on \(inputName())")
                let session = AVAudioSession.sharedInstance()
                let detail: [String: Any] = ["why": stall.rawValue, "input": inputName(), "sampleRate": session.sampleRate, "voiceProcessing": voiceProcessing, "available": Self.describeInputs(session), "route": Self.describeRoute(session.currentRoute)]
                record("native-mic-stalled", detail)
                if stall == .digitalSilence, Self.isBluetooth(session.currentRoute.inputs.first) {
                    openBadState("a Bluetooth microphone sending only digital silence", detail)
                }
            } else {
                log("the microphone has sound again, after \(stallRestarts) restart(s)")
                record("native-mic-sound-again", ["after": was?.rawValue ?? "", "restarts": stallRestarts, "input": inputName()])
                stallRestarts = 0
            }
            sendState()
        }
        guard let stall, pendingRestart == nil, !transitioning,
              Date().timeIntervalSince(lastBringUp) > Self.minSecondsBetweenRebuilds,
              Date().timeIntervalSince(lastStallRestart) > Self.stallBackoff(stallRestarts) else { return }
        // Zeros from the input: in place only. A new engine on a dead Bluetooth link took nine seconds
        // and left it worse; it is for an engine that delivers nothing at all.
        let inPlace = stall == .digitalSilence || stallRestarts != 1
        stallRestarts += 1
        lastStallRestart = Date()
        record("native-mic-stall-restart", ["why": stall.rawValue, "attempt": stallRestarts, "inPlace": inPlace])
        scheduleRestart("a stalled microphone (\(stall.rawValue))", after: 0, inPlace: inPlace)
    }

    // MARK: - AirPods incidents

    /**
     * The record of the AirPods going bad, for telling good starts from bad
     * ones and what came before each (src/mobile/README.md, "AirPods
     * incidents"). A start on Bluetooth at more than 24 kHz, and a Bluetooth
     * microphone sending only zeros, open an incident (`airpods-bad-state`);
     * sound from it closes it (`airpods-recovered`). One still open is kept
     * across launches (`badStateDefaultsKey`; Spaceterm's `NativeEvents.lastBadStateKey`), so an iPhone restart
     * after it is recorded as one (`iphone-restarted`, NativeEvents.swift).
     */
    private var badState: [String: Any]?
    private var lastHeadsetCameAt: Date?
    private var lastMicrophoneRate: Double?
    private let launchedAt = Date()

    private func noteMicrophoneStart(_ started: Started, plan: Plan, why: String) {
        let session = AVAudioSession.sharedInstance()
        let input = session.currentRoute.inputs.first
        var detail: [String: Any] = [
            "why": why, "sampleRate": started.sampleRate, "previousRate": lastMicrophoneRate ?? 0,
            "sinceLaunchS": Int(Date().timeIntervalSince(launchedAt)),
            "sinceHeadsetCameS": lastHeadsetCameAt.map { Int(Date().timeIntervalSince($0)) } ?? -1,
            "released": plan.deactivateFirst, "forDictation": forDictation, "headphones": plan.headphones,
            "highQuality": started.highQuality, "options": session.categoryOptions.rawValue,
            "available": Self.describeInputs(session), "input": input.map { "\($0.portName) (\($0.portType.rawValue))" } ?? "none",
        ]
        if #available(iOS 17.0, *) { detail["inputMuted"] = AVAudioApplication.shared.isInputMuted }
        lastMicrophoneRate = started.sampleRate
        record("native-mic-start", detail)
        if Self.isBluetooth(input), session.sampleRate > Self.voiceProcessingRate,
           (started.highQuality["enabled"] as? Bool) != true {
            openBadState("a Bluetooth microphone came up at \(Int(session.sampleRate)) Hz", detail)
        }
    }

    private func openBadState(_ reason: String, _ detail: [String: Any]) {
        guard badState == nil else { return }
        let at = ISO8601DateFormatter().string(from: Date())
        badState = ["reason": reason, "at": at]
        if let badStateDefaultsKey { UserDefaults.standard.set(["reason": reason, "at": at], forKey: badStateDefaultsKey) }
        var record = detail
        record["reason"] = reason
        self.record("airpods-bad-state", record)
    }

    private func closeBadState(_ how: String) {
        guard let open = badState else { return }
        badState = nil
        if let badStateDefaultsKey { UserDefaults.standard.removeObject(forKey: badStateDefaultsKey) }
        record("airpods-recovered", ["how": how, "badState": open, "input": inputName(), "sampleRate": AVAudioSession.sharedInstance().sampleRate])
    }

    /// Every input iOS offers now: whether the AirPods are there at all, beside what the route says.
    private static func describeInputs(_ session: AVAudioSession) -> [String] {
        (session.availableInputs ?? []).map { "\($0.portName) (\($0.portType.rawValue))" }
    }

    /// Between giving the session up and hands-free's microphone: see `bringUp`.
    private static let releasePauseSeconds: TimeInterval = 0.5

    /// Asked for, and the most voice processing is given over Bluetooth: see `start`.
    nonisolated private static let voiceProcessingRate: Double = 24_000

    /// Sound goes into an ear, not the room: AirPods or any Bluetooth or wired headphones.
    nonisolated private static func headphones(_ route: AVAudioSessionRouteDescription) -> Bool {
        route.outputs.contains { [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .headphones].contains($0.portType) }
    }

    nonisolated private static func isBluetooth(_ port: AVAudioSessionPortDescription?) -> Bool {
        guard let type = port?.portType else { return false }
        return type == .bluetoothHFP || type == .bluetoothLE || type == .bluetoothA2DP
    }

    /// How long after the last restart for a stall before the next: 3 s, 3 s, then 10, 30, 60.
    private static func stallBackoff(_ restarts: Int) -> TimeInterval {
        [3, 3, 10, 30][min(restarts, 3)] + (restarts > 3 ? 30 : 0)
    }

    /**
     * Whether other audio plays, recorded each time it changes, with what
     * this app's audio is doing then: which of this app's moves, if any,
     * paused Spotify — or let it carry on. iOS says nothing to another app
     * when that app pauses itself, so this is sampled. Beware: the page's
     * own sounds, the sonar and the cues, play through WebKit's process and
     * count as other audio here too.
     */
    private var otherAudioPlaying: Bool?
    /// `secondaryAudioShouldBeSilencedHint`: another app's own, non-mixable audio playing — Spotify, not the
    /// page's sounds, which mix — when last looked at.
    private var otherAppPlaying: Bool?

    private func noteOtherAudio() {
        let session = AVAudioSession.sharedInstance()
        let playing = session.isOtherAudioPlaying
        let appPlaying = session.secondaryAudioShouldBeSilencedHint
        guard playing != otherAudioPlaying || appPlaying != otherAppPlaying else { return }
        let was = otherAudioPlaying
        otherAudioPlaying = playing
        otherAppPlaying = appPlaying
        guard was != nil else { return }
        record("other-audio", [
            "playing": playing, "otherApp": appPlaying, "appState": UIApplication.shared.applicationState == .active ? "active" : "not active",
            "up": up.rawValue, "others": sessionOthers?.rawValue ?? "inactive",
            "voiceDucking": appliedVoiceDucking ?? false, "voiceProcessing": voiceProcessing,
            "category": session.category.rawValue, "mode": session.mode.rawValue,
            "route": Self.describeRoute(session.currentRoute),
        ])
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.sendInterval, repeats: true) { _ in
            MainActor.assumeIsolated { self.onTick() }
        }
    }

    private func onTick() {
        tick += 1
        // Every 2 s, in case the page reloaded and missed the last change.
        // Once a second: other audio — Spotify — starting or stopping, beside what this app was doing.
        if tick % 10 == 0 { noteOtherAudio() }
        if tick % 20 == 0 {
            sendState()
            recover("the engine was found stopped")
        }
        notePlayback()
        guard running else { return }
        let (pcm, stall, heard) = capture.drain(stallSeconds: Self.stallSeconds)
        // Only real sound ends a stall: a restart resets the clock, which is not the same.
        if stall != nil || heard { noteStall(stall) }
        if heard, stall == nil, badState != nil { closeBadState("sound from the microphone") }
        guard !pcm.isEmpty else { return }
        // A host that is not taking it (a suspended page) is the host's to drop: see its adapter.
        let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        captureObserver?(data)
        host?.engine(self, captured: data)
    }

    /**
     * The page's own microphone (WebKit's, for a held dictation) has closed.
     * Opening it interrupts the engine kept up to stay awake, and iOS says
     * nothing when it is done — no interruption end — so the engine is
     * started again here, or it stays stopped for good.
     */
    public func pageMicrophoneClosed() {
        guard mode != .off, !engineRunning else { return }
        scheduleRestart("the page's microphone closed", after: 0.3, inPlace: true)
    }

    /**
     * The page's own microphone (WebKit's) is open. Starting the engine then
     * takes the microphone from it, and its dictation hears nothing — so no
     * restart happens meanwhile; `pageMicrophoneClosed` does it afterwards.
     */
    private var pageMicrophoneOpen: Bool {
        guard let host else { return false }
        return !host.pageMicrophoneCaptureIdle
    }

    /**
     * Whatever stopped the engine, start it again if it should be running and
     * nothing else is about to. Each cause used to need its own restart, and
     * those without one left it stopped for good: an interruption iOS never
     * ends — the page's own sound starting is one, and the commonest — left
     * the engine that keeps the app awake stopped, and with it the app
     * suspended as soon as it went to the background, the page and its
     * connection to the server too (October 2026: stopped for minutes at a
     * time, over a hundred interruptions and three ends). Called after an
     * interruption, on coming back to the foreground, and every two seconds.
     */
    func recover(_ why: String) {
        guard mode != .off, pendingRestart == nil, !transitioning, !(up == mode && engineRunning) else { return }
        // `pageMicrophoneClosed` does it; and nothing can start during a call.
        guard !pageMicrophoneOpen, !calls.calls.contains(where: { !$0.hasEnded }) else { return }
        guard Date().timeIntervalSince(lastRecovery) > Self.minSecondsBetweenRebuilds else { return }
        lastRecovery = Date()
        record("native-engine-recovering", [
            "why": why, "wanted": mode.rawValue, "up": up.rawValue, "engineRunning": engineRunning,
            "appState": UIApplication.shared.applicationState == .background ? "background" : "foreground",
        ])
        log("the engine had stopped — starting it again (\(why))")
        scheduleRestart(why, after: 0, inPlace: true)
    }

    // MARK: - To the page

    private func sendState() {
        // `speech`: this app plays Control's voice itself, while running — an older one does not.
        // `awake`: the engine is up without the microphone, and plays it all the same.
        // Whether the engine *is* running, not what it was brought up for: iOS stops it under the app, and
        // a page told "awake" by an app whose engine had stopped sent it Control's voice to play into nothing.
        // `haptics`: 2 — this app plays a whole pattern from one message, in the background too (`playHaptic`).
        // `pendingTone`: it repeats a tone until told to stop (`startPendingTone`).
        // `noteGains`: a note may carry its own gain, a third number (`toneBuffer`).
        var state: [String: Any] = ["running": running, "awake": up == .speaker && engineRunning, "speech": true, "voiceProcessing": voiceProcessing, "haptics": 2, "cues": true, "pendingTone": true, "noteGains": true]
        if running {
            state["input"] = inputName()
            // The microphone link's rate, for hands-free's badge (HandsFreeButton.tsx). Read only.
            state["sampleRate"] = Int(AVAudioSession.sharedInstance().sampleRate)
            // Running, but the input sends only zeros: AirPods whose microphone is elsewhere, say.
            if currentStall == .digitalSilence { state["silentInput"] = true }
            // Nothing played leaks into the microphone: Control's voice can play through the engine with
            // hands-free listening through it, voice processing or not.
            if voiceProcessing || sessionOnHeadphones { state["echoFree"] = true }
        }
        // Where sound goes now, whatever the microphone is doing: the badge on the page's microphone button.
        if let output = AVAudioSession.sharedInstance().currentRoute.outputs.first {
            state["output"] = output.portName
            state["outputType"] = output.portType.rawValue
        }
        if let lastError, !running { state["error"] = lastError }
        host?.engine(self, state: state)
        notePlayback()
    }

    // MARK: - Haptics

    /// `tap`, `double` or `triple` taps (src/mobile/native-microphone.ts says what each means).
    ///
    /// In the foreground, UIKit's impact generator: crisp, short taps. It plays
    /// nothing once the app is in the background or the screen is locked, and
    /// neither does Core Haptics — iOS keeps both to the app on screen. What
    /// does reach a pocket is a system vibration, `kSystemSoundID_Vibrate`,
    /// played while this app's audio session is active under the `audio`
    /// background mode (hands-free holds the microphone, or the app stays
    /// awake for Control) and allowed during recording
    /// (`setAllowHapticsAndSystemSoundsDuringRecording`). It is one long buzz,
    /// about 0.4 s, with no strength to choose, so a pattern is buzzes chained
    /// on each one's completion. The phone's Sounds & Haptics settings decide
    /// whether it plays at all (e.g. no haptics in silent mode).
    private func playHaptic(_ pattern: String) {
        let count = pattern == "triple" ? 3 : pattern == "double" ? 2 : 1
        let foreground = UIApplication.shared.applicationState == .active
        record("native-haptic", ["pattern": pattern, "how": foreground ? "impact" : "vibrate", "sessionActive": engineRunning])
        if foreground {
            let generator = UIImpactFeedbackGenerator(style: .heavy)
            generator.prepare()
            for i in 0..<count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14 * Double(i)) { generator.impactOccurred() }
            }
        } else {
            vibrate(times: count)
        }
    }

    private func vibrate(times: Int) {
        guard times > 0 else { return }
        AudioServicesPlaySystemSoundWithCompletion(kSystemSoundID_Vibrate) {
            // A gap after each buzz, so two read as two and not one long one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.vibrate(times: times - 1) }
        }
    }

    private func fail(_ message: String) {
        lastError = message
        log(message)
        sendState()
    }

    // MARK: - Control's voice

    /// One sentence from the page: s16le mono PCM at its own rate, base64.
    private func playSpeech(_ body: [String: Any]) {
        guard let id = body["id"] as? String, let index = body["index"] as? Int, let count = body["count"] as? Int,
              let rate = body["sampleRate"] as? Double, let pcm = (body["pcm"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
            log("speech-play without id, index, count, sampleRate and pcm")
            return
        }
        guard let sentence = SpeechQueue.Sentence(id: id, index: index, count: count, pcm: pcm, sampleRate: rate) else {
            sendSpeech(id: id, index: index, event: "failed")
            return
        }
        // The engine is coming up for a reason that keeps it up: it plays this once started (`rescheduleSpeech`).
        if transitioning, mode != .off {
            speech.append(sentence)
            return
        }
        guard up != .off, engineRunning, let player else {
            sendSpeech(id: id, index: index, event: "failed")
            return
        }
        stopPendingTone()
        let idle = speech.current == nil
        speech.append(sentence)
        schedule(sentence, on: player)
        if !player.isPlaying { player.play() }
        if idle { begin(sentence) }
    }

    // MARK: - Hands-free's tones

    /**
     * One of hands-free's tones (src/mobile/cues.ts `playHandsFreeCue`):
     * dictation starting, dictation ending, the conversation window running
     * out. Played here, not by the page, because the page's sound is
     * WebKit's ambient type, which the Ring/Silent switch silences; this
     * engine's session is not. `segments`: (frequency Hz, seconds) pairs,
     * frequency 0 a rest; `gain` 0–1.
     *
     * Through the player Control's voice goes through, queued with it: a
     * second player node on the engine was the one change in the build after
     * which Spotify went unheard under every microphone (October 13), so
     * there is only the one. A tone is cut off with Control's voice when that
     * is stopped or started again.
     */
    private func playCue(_ body: [String: Any]) {
        let name = body["name"] as? String ?? "?"
        guard let segments = body["segments"] as? [[Double]], let gain = body["gain"] as? Double else {
            log("cue without segments and gain")
            return
        }
        guard !transitioning, up != .off, engineRunning, let player, let buffer = Self.toneBuffer(segments, gain: toneGain(gain)) else {
            record("native-cue-dropped", ["cue": name, "why": transitioning ? "the engine is coming up" : "no engine running"])
            return
        }
        // The cue is what the pending tone was waiting for: it ends there, not after the cue.
        stopPendingTone()
        cueNumber += 1
        let cue = cueNumber
        cuesPlaying.insert(cue)
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.cuesPlaying.remove(cue) != nil else { return }
                    self.notePlayback()
                }
            }
        }
        if !player.isPlaying { player.play() }
        notePlayback()
        record("native-cue", ["cue": name, "ms": Int(Double(buffer.frameLength) / SpeechQueue.format.sampleRate * 1000), "gain": gain])
    }

    /// Shares the player with Control's voice, which is a quarter as loud through echo cancellation:
    /// a tone makes up for that, so it sounds as it does elsewhere.
    private func toneGain(_ gain: Double) -> Double {
        voiceProcessing ? min(0.9, gain / Double(Self.echoCancelledSpeechVolume)) : gain
    }

    /// The player the pending tone is looping on, if it is; a new engine's player, or one stopped, is not.
    private var pendingTonePlayer: AVAudioPlayerNode?

    /**
     * Hands-free's pending tone (src/mobile/cues.ts `playPendingTone`): a beep
     * and a rest, looped, while it decides whether what it hears is words —
     * until the page says stop, a cue (the chirp it was waiting for), or
     * Control's voice. The thinking sonar loops here the same way
     * (`playThinkingSonar`), one tone at a time, the page deciding which. Looped on the one player (see `playCue`), so only while
     * that has no voice to play: a loop would hold back whatever is queued
     * behind it, and stopping it, which is the player stopping, would cut that
     * off too. A new pitch starts it again.
     */
    private func startPendingTone(_ body: [String: Any]) {
        let name = body["name"] as? String ?? "?"
        guard let segments = body["segments"] as? [[Double]], let gain = body["gain"] as? Double else {
            log("pending-tone without segments and gain")
            return
        }
        stopPendingTone()
        guard speech.isEmpty else {
            record("native-pending-tone-dropped", ["tone": name, "why": "Control is speaking"])
            return
        }
        guard !transitioning, up != .off, engineRunning, let player, let buffer = Self.toneBuffer(segments, gain: toneGain(gain)) else {
            record("native-pending-tone-dropped", ["tone": name, "why": transitioning ? "the engine is coming up" : "no engine running"])
            return
        }
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        if !player.isPlaying { player.play() }
        pendingTonePlayer = player
        record("native-pending-tone", ["tone": name, "gain": gain])
        notePlayback()
    }

    /// The pending tone cut off where it is. Nothing else is queued behind it: it starts only on an idle player, and anything else stops it first.
    private func stopPendingTone() {
        guard let looping = pendingTonePlayer else { return }
        pendingTonePlayer = nil
        guard looping === player else { return }
        looping.stop()
        record("native-pending-tone-stopped", [:])
        notePlayback()
    }

    /// Sine notes with 5 ms fades, as the page synthesizes its cues (cues.ts `cueSamples`): (frequency, seconds),
    /// frequency 0 a rest, and optionally a third number scaling `gain` for that note alone — the thinking
    /// sonar's fading echoes (thinking-cue.ts `echoNotes`).
    nonisolated private static func toneBuffer(_ segments: [[Double]], gain: Double) -> AVAudioPCMBuffer? {
        let rate = SpeechQueue.format.sampleRate
        let fade = max(1, Int(0.005 * rate))
        var samples: [Float] = []
        for segment in segments where segment.count == 2 || segment.count == 3 {
            let (freq, seconds) = (segment[0], segment[1])
            let noteGain = gain * (segment.count == 3 ? segment[2] : 1)
            let n = Int(seconds * rate)
            for i in 0..<n {
                let env = i < fade ? Double(i) / Double(fade) : i > n - fade ? Double(n - i) / Double(fade) : 1
                samples.append(freq == 0 ? 0 : Float(env * sin(2 * .pi * freq * Double(i) / rate) * noteGain))
            }
        }
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: SpeechQueue.format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }

    /**
     * Control's voice, as loud as it is played. Through echo cancellation —
     * hands-free on the phone's own speaker, the only microphone that uses
     * it — at a quarter, about 12 dB down: Voice Operator made its speech
     * 12 dB louder through a limiter (voiceop ebc95c7, October 12), and from
     * then the speaker's echo outran the cancellation, and hands-free heard
     * Control's replies as the user speaking, cut them off and sent them back
     * to it (04:09:23 and 04:09:29, October 13: "Nothing urgent."). That puts
     * it back where the cancellation coped. Everywhere else — AirPods, a
     * dictation, the engine kept for Control — at full. Ducked, a quarter of that.
     */
    private static let echoCancelledSpeechVolume: Float = 0.25

    private func speechVolume(voiceProcessing: Bool) -> Float {
        (voiceProcessing ? Self.echoCancelledSpeechVolume : 1) * (ducked ? Self.duckedVolume : 1)
    }

    /// Control's voice turned down while the user may be talking over it, and back up.
    private static let duckedVolume: Float = 0.25
    private var ducked = false

    private func duckSpeech(_ on: Bool) {
        guard on != ducked else { return }
        ducked = on
        player?.volume = speechVolume(voiceProcessing: voiceProcessing)
        record("native-speech-duck", ["on": on])
    }

    /// The server cut this job off: drop its sentences, and carry on with any queued behind it.
    private func stopSpeech(id: String) {
        guard speech.contains(id: id) else { return }
        speech.remove(id: id)
        record("native-speech-stopped", ["id": String(id.prefix(11))])
        if speech.isEmpty { duckSpeech(false) }
        rescheduleSpeech()
        notePlayback()
    }

    private func schedule(_ sentence: SpeechQueue.Sentence, on player: AVAudioPlayerNode) {
        let generation = speechGeneration
        let key = sentence.key
        player.scheduleBuffer(sentence.buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finished(key, generation: generation) }
            }
        }
    }

    /// A sentence has been heard to its end: say so, and the next has begun.
    private func finished(_ key: String, generation: Int) {
        guard generation == speechGeneration, let sentence = speech.current, sentence.key == key else { return }
        speech.removeCurrent()
        sendSpeech(id: sentence.id, index: sentence.index, event: "finished", outputDb: sentence.levelDb)
        if let next = speech.current { begin(next) } else { duckSpeech(false) }
    }

    private func begin(_ sentence: SpeechQueue.Sentence) {
        sendSpeech(id: sentence.id, index: sentence.index, event: "started", outputDb: sentence.levelDb)
    }

    /// Throw away what is scheduled and schedule what is left again — after a stop, or on a new engine.
    private func rescheduleSpeech() {
        speechGeneration += 1
        // Mid-change the engine is the audio queue's; the change reschedules when it is done.
        guard !transitioning else { return }
        player?.stop()
        pendingTonePlayer = nil
        guard up != .off, let player, !speech.isEmpty else { return }
        for sentence in speech.sentences { schedule(sentence, on: player) }
        player.play()
        if let current = speech.current { begin(current) }
    }

    /// Nothing more can be played: every sentence still to come fails.
    private func failSpeech(why: String) {
        guard !speech.isEmpty else { return }
        speechGeneration += 1
        if !transitioning { player?.stop() }
        record("native-speech-failed", ["why": why, "sentences": speech.sentences.count])
        for sentence in speech.sentences { sendSpeech(id: sentence.id, index: sentence.index, event: "failed") }
        speech = SpeechQueue()
        notePlayback()
    }

    private func sendSpeech(id: String, index: Int, event: String, outputDb: Double? = nil) {
        var detail: [String: Any] = ["id": id, "index": index, "event": event]
        if let outputDb { detail["outputDb"] = outputDb }
        host?.engine(self, speech: detail)
        speechObserver?(id, index, event)
        notePlayback()
    }

    /// To the server's log through the page, as the page's own lines go.
    private func log(_ message: String) {
        NSLog("[native-mic] %@", message)
        host?.engine(self, log: message)
    }

    /// To the host's audio and lifecycle record.
    private func record(_ kind: String, _ detail: [String: Any] = [:]) {
        host?.engine(self, record: kind, detail: detail)
    }

    /// For the heartbeat: whether it is meant to run and does, and what it has heard since the last.
    /// (Whether the page is taking the audio is the host's to add.)
    public func status() -> [String: Any] {
        let heard = capture.takeStats()
        return [
            "wanted": wanted, "running": running, "stayAwake": stayAwake, "mode": up.rawValue, "engineRunning": engineRunning,
            "secondsHeard": Double(heard.samples) / 16_000,
            "peakDbfs": heard.peak > 0 ? Int(20 * log10(heard.peak)) : -999,
            "input": inputName(),
        ]
    }

    private func inputName() -> String {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "no input"
    }

    private func outputName() -> String {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "no output"
    }

    // MARK: - Playback, for hands-free

    /// What the one player is playing, for Voice Operator's `playing`: anything at all (`on`), the
    /// client's voice (`speech`), and whether the microphone is spared hearing it (`echoCancelled`):
    /// always when the sound goes into an ear. On the phone's own speaker, voice processing spares
    /// it cues and the pending beep but not Control's voice: its echo cancellation let the start of
    /// Control's replies through ("First question", heard as the user cutting in — October 25 2026),
    /// so there hands-free does not listen while Control speaks, as on the Mac's speakers. The
    /// pending beep must still count: it plays while the user says "Control", and hands-free going
    /// deaf for it cut the word off after a blip (October 25 2026). Once Control's voice is in what
    /// plays, the microphone is not spared until it has all stopped, and that stays the answer
    /// after, for Voice Operator's tail. The page's `echoFree`, which only decides who plays
    /// Control's voice, counts voice processing.
    public struct Playback: Equatable, Sendable {
        public var on: Bool
        public var speech: Bool
        public var echoCancelled: Bool
    }

    public var playback: Playback {
        let speaking = !speech.isEmpty
        let on = speaking || !cuesPlaying.isEmpty || pendingTonePlayer != nil
        let spared: Bool
        if !running {
            spared = false
        } else if sessionOnHeadphones || Self.headphones(AVAudioSession.sharedInstance().currentRoute) {
            spared = true
        } else if let last = lastPlayback, !last.echoCancelled, last.on || !on {
            // Still playing what was not spared, or just stopped: Control's voice and its tail.
            spared = false
        } else {
            spared = voiceProcessing && !speaking
        }
        return Playback(on: on, speech: speaking, echoCancelled: spared)
    }

    /// Cues scheduled and not yet heard to their end, by number.
    private var cuesPlaying: Set<Int> = []
    private var cueNumber = 0
    private var lastPlayback: Playback?

    private func notePlayback() {
        let now = playback
        guard now != lastPlayback else { return }
        lastPlayback = now
        onPlaybackChange?()
    }

    // MARK: - The system

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            let reason = (note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt) ?? 0
            MainActor.assumeIsolated {
                let began = AVAudioSession.InterruptionType(rawValue: raw) == .began
                self.record(began ? "audio-interruption-began" : "audio-interruption-ended", [
                    "reason": Self.describe(AVAudioSession.InterruptionReason(rawValue: reason)),
                    "shouldResume": AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume),
                    "running": self.running, "wanted": self.wanted, "stayAwake": self.stayAwake,
                    "engineRunning": self.engineRunning,
                    // Which recorder took it: the page's own microphone, or something else.
                    "pageMicrophone": self.host?.pageMicrophoneState ?? "no page",
                    "appState": UIApplication.shared.applicationState == .background ? "background" : "foreground",
                ])
                if began {
                    self.log("interrupted (a call, Siri, another app, or the page's own microphone or sound)")
                    // The engine has stopped: nothing queued will be heard, and the page should play what comes next.
                    self.failSpeech(why: "the audio session was interrupted")
                    self.sendState()
                    // Most never end: the page's own sound starting interrupts it, and iOS says nothing more.
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.interruptionGraceSeconds) { [weak self] in
                        MainActor.assumeIsolated { self?.recover("an interruption with no end") }
                    }
                } else {
                    self.scheduleRestart("an interruption ended", after: 0.3)
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            let previous = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            MainActor.assumeIsolated {
                let why = AVAudioSession.RouteChangeReason(rawValue: reason)
                // AirPods coming and going, among other things.
                var detail: [String: Any] = [
                    "reason": Self.describe(why),
                    "route": Self.describeRoute(AVAudioSession.sharedInstance().currentRoute),
                    "running": self.running,
                ]
                if let previous { detail["previous"] = Self.describeRoute(previous) }
                self.record("audio-route-change", detail)
                if why == .newDeviceAvailable { self.lastHeadsetCameAt = Date() }
                self.sendState()
                if self.wanted, !self.forDictation, why == .newDeviceAvailable || why == .oldDeviceUnavailable { self.noteHeadphones() }
                if self.running, why == .newDeviceAvailable || why == .oldDeviceUnavailable {
                    self.scheduleRestart("a headset came or went")
                }
            }
        })
        // Back from the background, or the lock screen: whatever stopped the engine meanwhile.
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.recover("the app came back") }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereLostNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.record("audio-media-services-lost") }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                self.record("audio-media-services-reset")
                self.scheduleRestart("media services were reset")
            }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard (note.object as AnyObject?) === self.engine else { return }
                self.configurationChanged()
            }
        })
    }

    /// As Spaceterm's NativeEvents describes them, for the record.
    nonisolated static func describeRoute(_ route: AVAudioSessionRouteDescription) -> [String: Any] {
        [
            "inputs": route.inputs.map { "\($0.portName) (\($0.portType.rawValue))" },
            "outputs": route.outputs.map { "\($0.portName) (\($0.portType.rawValue))" },
        ]
    }

    static func describe(_ reason: AVAudioSession.RouteChangeReason?) -> String {
        switch reason {
        case .newDeviceAvailable: "new device available"
        case .oldDeviceUnavailable: "old device unavailable"
        case .categoryChange: "category change"
        case .override: "override"
        case .wakeFromSleep: "wake from sleep"
        case .noSuitableRouteForCategory: "no suitable route for category"
        case .routeConfigurationChange: "route configuration change"
        default: "raw \(reason?.rawValue ?? 0)"
        }
    }

    private static func describe(_ reason: AVAudioSession.InterruptionReason?) -> String {
        switch reason {
        case .default: "default"
        case .builtInMicMuted: "built-in mic muted"
        case .routeDisconnected: "route disconnected"
        default: "raw \(reason?.rawValue ?? 0)"
        }
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

/// The audio thread's side: each tap converted to 16 kHz s16, kept until drained.
private final class Converter: @unchecked Sendable {
    static let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var pcm: [Int16] = []
    private var lastTap: CFTimeInterval = 0
    /// When the input last held anything but exact zeros.
    private var lastSound: CFTimeInterval = 0
    /// Since the last `takeStats`: samples out, and the loudest input sample.
    private var statSamples = 0
    private var statPeak: Float = 0

    /// When it was last reset, and the first tap after that.
    private var resetAt: CFTimeInterval = 0
    private var firstTap: CFTimeInterval?

    func reset(converter: AVAudioConverter?) {
        lock.lock(); defer { lock.unlock() }
        self.converter = converter
        pcm = []
        let now = CACurrentMediaTime()
        lastTap = now
        lastSound = now
        resetAt = now
        firstTap = nil
    }

    /// How long after the last reset audio first arrived; nil if it has not.
    func firstAudioMs() -> Int? {
        lock.lock(); defer { lock.unlock() }
        return firstTap.map { Int(($0 - resetAt) * 1000) }
    }

    func handle(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let converter = self.converter
        lock.unlock()
        var silent = true
        var peak: Float = 0
        if let channel = buffer.floatChannelData?[0] {
            for i in 0..<Int(buffer.frameLength) {
                let v = abs(channel[i])
                if v > peak { peak = v }
            }
            silent = peak == 0
        }
        var out: [Int16] = []
        if let converter {
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 32
            if let converted = AVAudioPCMBuffer(pcmFormat: Self.outFormat, frameCapacity: capacity) {
                var fed = false
                var error: NSError?
                converter.convert(to: converted, error: &error) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true
                    status.pointee = .haveData
                    return buffer
                }
                if let samples = converted.int16ChannelData?[0] {
                    out = Array(UnsafeBufferPointer(start: samples, count: Int(converted.frameLength)))
                }
            }
        }
        let now = CACurrentMediaTime()
        lock.lock()
        if firstTap == nil { firstTap = now }
        lastTap = now
        if !silent { lastSound = now }
        pcm.append(contentsOf: out)
        statSamples += out.count
        statPeak = max(statPeak, peak)
        lock.unlock()
    }

    /// What has come through since the last call, and start counting again.
    func takeStats() -> (samples: Int, peak: Float) {
        lock.lock(); defer { lock.unlock() }
        let result = (statSamples, statPeak)
        statSamples = 0
        statPeak = 0
        return result
    }

    /// Why the input has stalled: nothing from the engine, or only exact zeros from the input.
    enum Stall: String { case noTaps = "no audio from the engine", digitalSilence = "only digital silence from the input" }

    /// The audio since the last drain, and whether the input has stalled. `heard`: real sound since the last reset —
    /// without it, no stall only means a reset was too recent to tell.
    func drain(stallSeconds: Double) -> (pcm: [Int16], stall: Stall?, heard: Bool) {
        lock.lock(); defer { lock.unlock() }
        let result = pcm
        pcm = []
        let now = CACurrentMediaTime()
        let heard = lastSound > resetAt
        if now - lastTap > stallSeconds { return (result, .noTaps, heard) }
        return (result, now - lastSound > stallSeconds ? .digitalSilence : nil, heard)
    }
}

/// Control's sentences waiting to be heard, in order, the first one playing.
/// Buffers are kept until heard, so a new engine can play them again.
private struct SpeechQueue {
    /// What the player is connected with; every sentence is converted to it.
    static let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    struct Sentence {
        let id: String
        let index: Int
        let count: Int
        let buffer: AVAudioPCMBuffer
        /// Its loudness, RMS dBFS: what the microphone would hear of it without cancellation.
        let levelDb: Double
        var key: String { "\(id)#\(index)" }

        init?(id: String, index: Int, count: Int, pcm: Data, sampleRate: Double) {
            let frames = pcm.count / 2
            guard frames > 0, sampleRate > 0,
                  let source = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
                  let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(frames)),
                  let samples = input.int16ChannelData?[0] else { return nil }
            input.frameLength = AVAudioFrameCount(frames)
            var sum = 0.0
            pcm.withUnsafeBytes { raw in
                for i in 0..<frames {
                    let v = raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)
                    samples[i] = v
                    sum += Double(v) * Double(v)
                }
            }
            let rms = (sum / Double(frames)).squareRoot() / 32768
            levelDb = rms > 0 ? (20 * log10(rms)).rounded() : -120
            guard let converter = AVAudioConverter(from: source, to: SpeechQueue.format),
                  let output = AVAudioPCMBuffer(pcmFormat: SpeechQueue.format,
                                                frameCapacity: AVAudioFrameCount(Double(frames) * SpeechQueue.format.sampleRate / sampleRate) + 64) else { return nil }
            var fed = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true
                status.pointee = .haveData
                return input
            }
            guard error == nil, output.frameLength > 0 else { return nil }
            self.id = id
            self.index = index
            self.count = count
            self.buffer = output
        }
    }

    private(set) var sentences: [Sentence] = []
    var current: Sentence? { sentences.first }
    var isEmpty: Bool { sentences.isEmpty }
    mutating func append(_ sentence: Sentence) { sentences.append(sentence) }
    mutating func removeCurrent() { if !sentences.isEmpty { sentences.removeFirst() } }
    func contains(id: String) -> Bool { sentences.contains { $0.id == id } }
    mutating func remove(id: String) { sentences.removeAll { $0.id == id } }
}
#endif
