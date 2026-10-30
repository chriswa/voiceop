import AppKit

/// Coordinates microphone dictation with the shared speech queue. Dictation has
/// priority: starting it immediately stops the audible sentence and prevents a
/// subsequent sentence from starting until transcription has finished.
///
/// Dictation is **streamed**, the way Wispr Flow does it. The moment the trigger
/// key goes down three things start at once: the microphone, the transcription
/// provider's live session (`TranscriptionLeg`), and an upload pump. The pump
/// hands each new slice of captured PCM to the session while the user is still
/// speaking, so when the key comes up all that is left to do is commit and wait
/// for the tail plus whatever clean-up the provider does.
///
/// The previous design did none of this: it recorded to a file, and only after
/// the key came up did it fetch a token, encode the whole clip, dial a fresh TLS
/// connection and issue a *unary* call carrying every packet at once. Server-side
/// ASR time therefore scaled with clip length and landed entirely after the user
/// stopped talking, which is why a 25-second dictation took five seconds to come
/// back and anything over 28 seconds was cut into sequential round trips.
@MainActor
final class AudioArbiter {
    private let recorder = AudioRecorder()
    let muter = OutputMuter()
    private let narrationDucker = NarrationDucker()
    /// Read at each dictation, so a change of provider applies from the next one.
    private let currentProvider: @MainActor () -> any TranscriptionProvider
    private let tts = TTSEngine()
    private var speechSessionID: String?
    /// Where the voice was when this session was last halted. Held so a second
    /// halt for the same interruption still has an answer — see `haltSpeech`.
    private var lastStoppedAt: SpokenPosition?
    private var playbackControls = PlaybackControls(rate: PlaybackPreferences().rate)
    private var speechExpiry: Task<Void, Never>?
    private var queueSpeechActive = false
    var onSpeechIdle: (() -> Void)?
    var onPlaybackControlsChanged: (() -> Void)?
    var speechRate: Float { playbackControls.rate }
    var canAdjustSpeech: Bool { speechSessionID != nil && isSpeaking && !isDictating }
    var canRewindSpeech: Bool {
        speechSessionID != nil && !isDictating && tts.duration > 0
            && playbackControls.canRewind(now: ProcessInfo.processInfo.systemUptime)
    }
    /// Full-width word-highlight bar, driven in time with TTS playback.
    let wordOverlay = WordOverlayController()
    private let historyStore = HistoryStore()
    private let sttDir: URL

    var onStatus: ((OperatorStatus) -> Void)?
    /// The transcript style of the dictation in flight, for the menu-bar badge.
    /// Reset to `.normal` when the dictation ends.
    var onTranscriptStyle: ((TranscriptStyle) -> Void)?
    var onHistoryChanged: (() -> Void)?
    var onCommand: ((String, DictationContext) -> Void)?
    var onDictationBegan: (() -> Void)?
    var onDictationEnded: (() -> Void)?
    /// The microphone's stall watchdog, on the main thread — see
    /// `AudioRecorder.checkDelivery`.
    var onMicrophoneDelivery: ((AudioRecorder.Delivery) -> Void)?
    /// Which transcription path the last dictation took — fires on every
    /// transition, including the launch-time key check in `prewarm`.
    var onStreamHealth: ((StreamHealth) -> Void)?
    private(set) var streamHealth: StreamHealth = .unverified

    private(set) var sttHistory: [STTHistoryEntry] = []
    private(set) var commandHistory: [CommandHistoryEntry] = []
    /// The most recent insertion: what ⌘⌃V and ⌘⌃⇧V replay.
    private var lastInsertion: String?
    /// True from key-down until the transcript has been pasted and the closing
    /// cue has had its moment. This is what "safe to restart" means
    /// (see `RestartCoordinator`).
    private(set) var isDictating = false
    /// True while a speech job is audible: from the first sentence handed to
    /// playback until the whole job finishes or is interrupted. It deliberately
    /// does not flicker in the gap between a job's sentences (see
    /// `SpeechJobManager.refreshActivity`), which is what makes it safe to hold a
    /// restart on.
    private(set) var isSpeaking = false
    private var transcriptionProgressTask: Task<Void, Never>?
    private var ttsWaitCueTask: Task<Void, Never>?
    private var live: LiveDictation?
    /// Shadow transcripts that finished before their dictation was filed.
    private var pendingShadows: [UUID: ShadowTranscript] = [:]

    /// Whether the microphone is held open between dictations rather than being
    /// woken for each one — see `AudioRecorder.setAlwaysOn`. Set from the menu's
    /// keep-open preference (`AudioPreferences`).
    var microphoneAlwaysOn: Bool {
        get { recorder.isAlwaysOn }
        set { recorder.setAlwaysOn(newValue) }
    }

    /// Hands-free's ear on the microphone — see `AudioRecorder.setListener`.
    /// The "Mac's microphone with headsets" preference changed (`AudioPreferences`).
    nonisolated func macMicrophoneChoiceChanged() { recorder.inputChoiceChanged() }

    nonisolated func setHandsFreeListener(_ handler: (@Sendable (Data, UInt64) -> Void)?) {
        recorder.setListener(handler)
    }

    /// Voice-energy thresholds below which a clip counts as "said nothing".
    private static let silencePeak: Float = 0.025
    private static let silenceRMS: Float = 0.005

    /// A silent clip no longer than this is treated as an accidental brush of the
    /// trigger key and discarded in complete silence — no cue, no history entry.
    /// Recording now starts on key-down rather than after a hold threshold, so
    /// stray taps do produce (empty) recordings, and they should be invisible.
    /// Must exceed the hotkey's lock window, since a lone quick tap always records
    /// for at least that long.
    private static let accidentalTapSeconds: Double = 0.8

    /// How often the upload pump drains newly captured audio into the stream.
    /// Wispr's renderer hands over a chunk every 40 ms; we poll a shared buffer
    /// instead, and 100 ms keeps the server within a couple of frames of live
    /// while costing one cheap encode per tick.
    private static let uploadInterval: TimeInterval = 0.1

    /// Slack added to the start cue's own length when deciding how much audio to
    /// keep out of the silence gate. The window is anchored at the moment the cue
    /// is triggered, so this only has to cover `AVAudioPlayer` start-up, the
    /// speaker-to-microphone path, and ring-out.
    private static let cueCaptureMargin: Double = 0.2

    /// How long, after key-up, to keep waiting for a stream that is still opening
    /// before giving up on it and transcribing the recorded clip instead.
    private static let streamOpenGrace: Duration = .seconds(2)

    /// If no microphone buffer has arrived by now, something is wrong with
    /// capture (permissions, a device that never started). Wispr has the same
    /// watchdog — `NoAudioDuringDictationError` at 5 s.
    private static let noAudioWarningSeconds: TimeInterval = 3
    /// A Bluetooth headset whose microphone this dictation opens (not held open)
    /// switches profiles at both ends, and the devices report changes while it
    /// does (`DeviceSettleWatch`). The start cue waits until they have been still
    /// for `headsetQuietAtStart` (at most `headsetCapAtStart` after the first
    /// audio); at key-up the unmute and the closing cue wait for
    /// `headsetQuietAtEnd` of stillness after the microphone closed (at most
    /// `headsetCapAtEnd`). The first audio arriving was not enough: on AirPods
    /// it is real sound from its first buffer, 150 ms in, and the switch still
    /// under way (October 29, v0.1.113: the cue and the music both cut by it).
    private nonisolated static let headsetQuietAtStart: TimeInterval = 0.25
    private nonisolated static let headsetCapAtStart: TimeInterval = 2.0
    /// At key-up the switch back to music is a full reconfiguration of the
    /// output (`out:cfgb` … `out:cfge`, the stream configuration changing), about
    /// 2.15 s after the microphone closes, every time: macOS holds the headset's
    /// voice link that long. The bursts of format changes before it (0.4 s, 0.75 s)
    /// are not the switch: unmuted after them, the music came back for a second and
    /// then dropped out for the reconfiguration (v0.1.115, three in three). So the
    /// unmute waits for the configuration to end, and no longer.
    private nonisolated static let headsetQuietAtEnd: TimeInterval = 0
    private nonisolated static let headsetSwitchBackSign = "out:cfge"
    private nonisolated static let headsetCapAtEnd: TimeInterval = 4
    /// The closing sounds after that unmute: half a second later, or the end of
    /// the switch swallows them.
    private nonisolated static let headsetCueDelay: TimeInterval = 0.5
    /// The watch at key-up keeps listening this long after the unmute, for the log:
    /// a change after it is a switch the unmute did not wait for.
    private nonisolated static let headsetWatchAfterUnmute: TimeInterval = 3

    /// Tunable timing for the audible indication that transcription is ongoing.
    /// The cue itself is synthesized to last `cueDuration` (see SoundEffects).
    private enum TranscriptionProgressCue {
        static let initialDelay: Duration = .milliseconds(1_500)
        static let cueDuration: Duration = .milliseconds(1_500)
        static let repeatGap: Duration = .seconds(1)
    }

    /// Sonar echo while a TTS sentence is still synthesizing. Within each 1.5 s
    /// period: 0.5 s quiet, 0.5 s of `transcriptionPending`, 0.5 s quiet — cut
    /// the instant playback starts.
    private enum TTSWaitCue {
        static let leadQuiet: Duration = .milliseconds(500)
        static let cueDuration: Duration = .milliseconds(500)
        static let trailQuiet: Duration = .milliseconds(500)
    }

    init(provider: @escaping @MainActor () -> any TranscriptionProvider = { TranscriptionProviders.primary }) {
        self.currentProvider = provider
        let loaded = historyStore.load()
        sttHistory = loaded.stt
        commandHistory = loaded.commands
        sttDir = HistoryStore.supportDir.appendingPathComponent("stt-history", isDirectory: true)
        try? FileManager.default.createDirectory(at: sttDir, withIntermediateDirectories: true)
        recorder.onDelivery = { [weak self] delivery in
            // Delivered on the main thread by contract (see AudioRecorder).
            MainActor.assumeIsolated { self?.onMicrophoneDelivery?(delivery) }
        }
    }

    /// Warm the providers' connections, credentials and models, so the first
    /// dictation of a session is as quick as the tenth.
    func prewarm() {
        // Say so at launch rather than at the first key press: the icon badge and
        // the menu warning should already be there when the user looks, not
        // appear after they have sat through a slow dictation. Only the primary
        // speaks for the health: a struggling shadow is the shadow's business.
        let provider = currentProvider()
        Task { [weak self] in
            guard let reason = await provider.prewarm() else { return }
            self?.noteStreamHealth(.degraded(reason: reason, provider: provider.id))
        }
        if let shadow = TranscriptionProviders.shadow {
            Task { _ = await shadow.prewarm() }
        }
        // Synthesizing the cue bank happens on first use and is not instant. Do it
        // now: the start cue is on the critical path for "safe to talk", and the
        // silence-gate exclusion window is anchored the moment we ask for it.
        _ = SoundBank.shared
    }

    /// The menu changed the provider or its shadow. The old health belonged to
    /// the old provider, so it starts over, and the new ones are warmed now
    /// rather than on the next key press.
    func providersChanged() {
        noteStreamHealth(.unverified)
        prewarm()
    }

    /// Incognito mode was turned on or off. Turning it on forgets the
    /// transcript re-paste would have replayed; either way the provider's
    /// health starts over, since Wispr is blocked one way and not the other.
    func incognitoChanged() {
        if Incognito.isOn { lastInsertion = nil }
        providersChanged()
    }

    /// Record a change of transcription path. Idempotent, so the callers can be
    /// generous: every fallback and every successful commit reports in, and only
    /// the transitions reach the log, the menu bar and `/v1/status`.
    private func noteStreamHealth(_ health: StreamHealth) {
        guard health != streamHealth else { return }
        streamHealth = health
        Log.log(health.logLine)
        onStreamHealth?(health)
    }

    // MARK: - Live dictation state

    /// Everything belonging to the dictation currently in flight.
    @MainActor
    private final class LiveDictation {
        let trace: DictationTrace
        /// Paste vs. command for *this* dictation. A decision rather than a value
        /// because Ctrl+Fn's two halves do not land together and capture must not
        /// wait for the second one — see `DictationModeDecision`. Read it through
        /// `whenResolved`/`resolve()`; `decision.mode` on its own is provisional.
        let modeDecision: DictationModeDecision
        /// The provider's live session for this dictation. Its liveness is its
        /// own, not "is this the *current* dictation": the arbiter clears `live`
        /// at key-up while the commit is still in flight.
        var leg: TranscriptionLeg?
        /// The shadow provider's leg, fed the same audio. Its transcript is only
        /// filed beside the real one for comparison; it never pastes, never holds
        /// anything up, and its failures are its own.
        var shadow: TranscriptionLeg?
        /// Captured PCM bytes already handed to the leg.
        var offset = 0
        var pump: Timer?
        var heardAudio = false
        /// This dictation opens a Bluetooth headset's microphone (it was not held
        /// open), so the headset switches profiles at both ends: the start cue
        /// waits for its first sound, and the unmute at the end for it to close.
        var headsetSwitches = false
        /// The devices' changes since key-down, while `headsetSwitches`.
        var deviceWatch: DeviceSettleWatch?
        /// The start cue has been asked for (`announceListening`).
        var cueRequested = false
        /// True only after the start cue actually played. Distinct from
        /// `heardAudio`, which flips earlier — before the mode/`live` guards that
        /// can still cancel the chirp. Closing cues key off this so a discarded
        /// tap that already announced "safe to talk" never goes silent.
        var announcedListening = false
        /// How this dictation's transcript is shaped before it is recorded and
        /// pasted. Cycled by tapping left Shift while recording, and deliberately
        /// per-dictation: it belongs to the sentence being spoken, not to the app.
        var style: TranscriptStyle = .normal
        /// PCM captured but not yet handed over, snapshotted synchronously at key-up.
        /// Read from the recorder later would race the *next* dictation's
        /// `start()`, which resets the shared capture buffer.
        var tailPCM = Data()

        init(trace: DictationTrace, mode decision: DictationModeDecision) {
            self.trace = trace
            self.modeDecision = decision
        }
    }

    // MARK: - Begin

    func beginDictation(mode decision: DictationModeDecision, trace: DictationTrace = DictationTrace()) {
        guard !recorder.isRecording else { return }
        // The last dictation's unmute is still waiting for its headset to switch
        // back: do it now, or this dictation's mute would save "muted" as the
        // user's own setting, and nothing would ever unmute it.
        outputIsBack()
        isDictating = true
        haltSpeech()
        // Release the narration ducker here, ahead of `recorder.start()`, rather
        // than leaving it to the speech queue's `setSpeechActive(false)`.
        //
        // Dictation always silences narration, so the lease is over either way —
        // what matters is *when*. The queue's answer arrives one actor hop later,
        // by which time capture has started, and the ducker's Voice Processing
        // I/O graph owns the same input device: dropping it then reconfigures the
        // microphone out from under the tap we just installed and the dictation
        // records nothing at all. Both engines mutate on `AudioGraphQueue`, so
        // enqueueing the teardown first is what guarantees it finishes before the
        // tap goes in. Idempotent, so the queue's later call is a no-op.
        narrationDucker.stop()
        onDictationBegan?()

        let live = LiveDictation(trace: trace, mode: decision)
        live.headsetSwitches = OutputDevice.isWireless && !recorder.isAlwaysOn && !recorder.hasListener
            && !AudioRecorder.willUseMacMicrophone
        if live.headsetSwitches { live.deviceWatch = DeviceSettleWatch() }
        self.live = live

        // The start cue means "it is safe to talk now", so it must wait for the
        // microphone to actually deliver samples rather than fire on key-down.
        // Fires on the audio thread; hop to main before touching anything.
        recorder.onFirstAudio = { [weak self] in
            DispatchQueue.main.async { self?.captureBecameLive() }
        }
        // The device is spun up after `start()` returns (it is far too slow to do
        // on the trigger key's thread — see AudioRecorder.start), so a microphone
        // that never opens surfaces here rather than as a thrown error.
        // Weak in `live` as well as `self`: this handler outlives the dictation
        // (it is only replaced by the next `beginDictation`), and a strong capture
        // would pin the finished dictation's trace and session until then.
        recorder.onStartFailed = { [weak self, weak live] reason in
            // Delivered on the main thread by contract (see AudioRecorder).
            MainActor.assumeIsolated {
                guard let self, let live else { return }
                self.abandonDictation(live, reason: "recorder start failed: \(reason)")
            }
        }
        do {
            try recorder.start(trace: trace)
        } catch {
            abandonDictation(live, reason: "recorder start failed: \(error)")
            return
        }
        // Tint the menu bar the instant capture begins. While Control may still be
        // on its way the mode is provisional, so this is the paste tint, corrected
        // when the window closes — inside 200 ms, faster than a menu bar can be read.
        onStatus?(decision.mode.listeningStatus)
        decision.whenResolved { [weak self] mode in
            trace.note("mode=\(mode.rawValue)@\(Int(trace.elapsedMS))ms")
            guard let self, self.live === live else { return }
            self.onStatus?(mode.listeningStatus)
        }

        // Open the stream concurrently with microphone start-up — neither waits
        // for the other, and by the time the first packet is encoded the socket
        // is usually already handshaked.
        openStream(for: live)
        startUploadPump(for: live)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noAudioWarningSeconds) { [weak self] in
            guard let self, let current = self.live, current === live, !current.heardAudio else { return }
            Log.log("dictation: WARNING no microphone audio after \(Self.noAudioWarningSeconds)s — check mic permission/device")
            current.trace.note("no audio within \(Self.noAudioWarningSeconds)s")
        }
    }

    /// The process is about to exit (`applicationWillTerminate`). Put the system
    /// output back the way the user had it — a dictation mutes it, and a process
    /// that dies mid-dictation otherwise leaves the Mac silent — and say so in the
    /// log if a dictation is being lost, so the user's "where did my words go?"
    /// has an answer. Nothing here waits: by this point the decision to quit has
    /// been made (the cooperative path in `RestartCoordinator` is where waiting
    /// happens).
    func prepareForTermination() {
        outputIsBack()
        muter.restore()
        narrationDucker.stopSynchronously()
        guard isDictating else { return }
        Log.log("dictation: WARNING terminating with a dictation in flight — it will not be pasted")
        if let live {
            live.trace.note("terminated mid-dictation")
            live.trace.flush()
            cancelStream(live)
        }
    }

    /// Advance the in-flight dictation's transcript style by one (left Shift
    /// tapped while recording). A no-op when nothing is recording — which is
    /// exactly the condition the red menu-bar icon shows, so the icon is an
    /// honest indicator of when the key does anything.
    func cycleTranscriptStyle() {
        guard let live else { return }
        live.style = live.style.next
        let styleTrace = live.style.discard
            ? "trash"
            : "\(live.style.lowercaseFirst ? "a" : "-")\(live.style.trimTrailingPunctuation ? "x" : "-")"
        live.trace.note("style=\(styleTrace)")
        onTranscriptStyle?(live.style)
    }

    /// Tear a dictation down before it ever produced anything — the capture graph
    /// was invalid, or the device failed to come up. Idempotent, and a no-op once
    /// some later dictation has taken over.
    private func abandonDictation(_ live: LiveDictation, reason: String) {
        guard self.live === live else { return }
        Log.log("dictation: \(reason)")
        live.trace.note(reason)
        live.trace.flush()
        live.pump?.invalidate()
        live.pump = nil
        cancelStream(live)
        self.live = nil
        isDictating = false
        onDictationEnded?()
        onTranscriptStyle?(.normal)
        onStatus?(.idle)
    }

    /// The microphone is genuinely capturing. Chirp now, then mute background
    /// output — in that order, so the system-output mute cannot swallow our own
    /// cue. The chirp does land in the recording (the mic is live by definition),
    /// but it is a fraction of a second of pure tone at the very start and the
    /// ASR ignores it; trimming it would risk cutting a word from anyone who
    /// starts speaking over the cue.
    private func captureBecameLive() {
        guard let live, !live.heardAudio else { return }
        live.heardAudio = true
        guard live.headsetSwitches, let watch = live.deviceWatch else { announceListening(live); return }
        // The headset is still switching into its call profile: the cue waits until it has.
        let began = Date()
        watch.whenQuiet(quiet: Self.headsetQuietAtStart, cap: Self.headsetCapAtStart) { [weak self] settled in
            guard let self, self.live === live else { return }
            live.trace.note(String(format: "headset %@ %.0fms after first audio — %@", settled ? "settled" : "still changing at the cap",
                                   Date().timeIntervalSince(began) * 1000, watch.summary))
            self.announceListening(live)
        }
    }

    /// The start cue, once the mode is final; then the output mute, after the
    /// cue (on a headset, once it has played out — the mute would cut it).
    private func announceListening(_ live: LiveDictation) {
        guard !live.cueRequested else { return }
        live.cueRequested = true        // The two start cues name the mode, so this one must not sound until the
        // mode is final. That wait is normally zero and never more than a few tens
        // of milliseconds: the mode window closes 200 ms after key-down and
        // CoreAudio has not been seen to deliver a first buffer sooner than that.
        live.modeDecision.whenResolved { [weak self] mode in
            guard let self, self.live === live else { return }
            live.trace.mark("chirp")
            let cue = mode.startCue
            // Anchor the metering exclusion here, at the instant we ask for the
            // cue, rather than at a fixed offset from sample zero: how long
            // CoreAudio took to hand over that first buffer is exactly the thing
            // we cannot predict.
            self.recorder.excludeFromMetering(seconds: cue.duration + Self.cueCaptureMargin)
            cue.play()
            live.announcedListening = true
            let muteAfter = live.headsetSwitches ? max(0.2, cue.duration + 0.05) : 0.2
            DispatchQueue.main.asyncAfter(deadline: .now() + muteAfter) { [weak self] in
                guard let self, self.recorder.isRecording else { return }
                self.muter.mute()
            }
        }
    }

    private func openStream(for live: LiveDictation) {
        let target = DictationTarget(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                     name: NSWorkspace.shared.frontmostApplication?.localizedName)
        let provider = currentProvider()
        live.leg = TranscriptionLeg(provider: provider, target: target, trace: live.trace,
                                    onOpenFailed: { [weak self] reason in
            Task { @MainActor in self?.noteStreamHealth(.degraded(reason: reason, provider: provider.id)) }
        })
        // A shadow's only product is a history entry, which incognito never files.
        if let shadow = TranscriptionProviders.shadow, shadow.id != provider.id, !Incognito.isOn {
            live.shadow = TranscriptionLeg(provider: shadow, target: target,
                                           trace: DictationTrace("shadow-\(shadow.id.rawValue)"),
                                           logPrefix: "shadow \(shadow.id.rawValue)")
        }
    }

    // MARK: - Upload pump

    private func startUploadPump(for live: LiveDictation) {
        let timer = Timer.scheduledTimer(withTimeInterval: Self.uploadInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pumpAudio(live)
            }
        }
        // .common so uploads keep flowing while the menu is open (menu tracking
        // parks the run loop outside the default mode).
        RunLoop.main.add(timer, forMode: .common)
        live.pump = timer
    }

    /// Hand whatever new audio the recorder has captured to the provider's
    /// session, and the shadow's.
    private func pumpAudio(_ live: LiveDictation) {
        guard recorder.isRecording, live === self.live else { return }
        let legs = [live.leg, live.shadow].compactMap { $0 }.filter { !$0.isBroken }
        guard !legs.isEmpty else { return }
        let slice = unencodedPCM(for: live)
        guard !slice.isEmpty else { return }
        live.offset += slice.count
        legs.forEach { $0.append(slice) }
    }

    /// Captured bytes the leg has not been given yet. Only valid while this
    /// dictation is the one recording — the capture buffer is shared and reset by
    /// the next `start()`.
    private func unencodedPCM(for live: LiveDictation) -> Data {
        let available = recorder.capturedByteCount
        guard available > live.offset else { return Data() }
        return recorder.capturedData(offset: live.offset, maxCount: available - live.offset)
    }

    // MARK: - End

    /// Capture command routing context at stop, not at key-down: this is the app
    /// the user intentionally had selected when they finished speaking.
    ///
    /// `micStalled`: the microphone stopped delivering mid-dictation
    /// (`AudioRecorder.Delivery.stalled`), and this stops it early, with the user
    /// most likely still talking. What was captured is transcribed as usual, but
    /// the closing cue is the long `microphoneStalled` alarm, played before
    /// anything else so the user stops as soon as possible. Returns whether there
    /// was a recording to end.
    @discardableResult
    func endDictation(context: DictationContext? = nil, micStalled: Bool = false) -> Bool {
        guard recorder.isRecording else { return false }
        let live = self.live
        self.live = nil
        // Clear `live` first, then latch: resolving fires the observers registered
        // at begin, and their identity guards must now reject them — this dictation
        // is ending, so it wants neither a listening tint nor a start cue. In
        // practice the mode has been settled for at least 300 ms by now (nothing can
        // stop a dictation sooner than `lockWindow`), and this only makes the
        // invariant that routing reads a final mode true by construction.
        let mode = live?.modeDecision.resolve() ?? .paste
        let isCommand = mode == .command
        // Latch the style with the mode, and for the same reason: the transcript
        // lands well after this dictation stopped being the current one, by which
        // time `live` may describe a newer dictation with a style of its own.
        let style = live?.style ?? .normal
        onTranscriptStyle?(.normal)   // the badge belongs to the recording, which is over
        let announcedListening = live?.announcedListening ?? false
        // How long the trigger key was actually held. Deliberately not the clip's
        // length: the two agree in normal operation and diverge exactly when
        // capture fails, because a clip's length is zero *because* nothing was
        // recorded, however long the user spoke for.
        let heldSeconds = (live?.trace.mark("key-up") ?? 0) / 1000
        live?.pump?.invalidate()
        live?.pump = nil

        // Watching from before the microphone closes, so the switch back is seen whole.
        let closingWatch = live?.headsetSwitches == true ? DeviceSettleWatch() : nil
        live?.deviceWatch?.stop()
        let pcm: Data
        do { pcm = try recorder.stop() }
        catch {
            Log.log("recorder stop failed: \(error)")
            if let live { cancelStream(live) }
            live?.trace.flush()
            muter.restore(); finishDictation(); return true
        }
        live?.trace.mark("recorder-stop")
        // Snapshot the un-encoded remainder now, synchronously. Reading it later
        // from the commit task would race a new dictation's `start()`, which
        // resets the shared capture buffer — at best losing the tail, at worst
        // splicing the next utterance's audio onto this one.
        if let live { live.tailPCM = unencodedPCM(for: live) }
        let duration = recorder.lastDurationSeconds
        let peak = recorder.lastPeak
        let rms = recorder.lastRMS
        if let closingWatch {
            // The headset switches back to music as its microphone closes: unmute,
            // and play the closing cue, once it has — not into the switch.
            outputPending = []
            let keyUp = Date()
            recorder.afterMicClosed {
                closingWatch.whenQuiet(quiet: Self.headsetQuietAtEnd,
                                       after: Self.headsetSwitchBackSign, cap: Self.headsetCapAtEnd) { [weak self] settled in
                    let unmutedAt = Date().timeIntervalSince(keyUp) * 1000
                    Log.log(String(format: "dictation: headset %@ %.0fms after key-up — unmuting. %@",
                                   settled ? "settled" : "not switched back by the cap", unmutedAt, closingWatch.summary))
                    self?.outputIsBack(cueDelay: Self.headsetCueDelay)
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.headsetWatchAfterUnmute) {
                        Log.log(String(format: "dictation: headset after the unmute (at %.0fms): %@", unmutedAt, closingWatch.summary))
                        closingWatch.stop()
                    }
                }
            }
        } else {
            muter.restore()
        }
        if micStalled {
            playClosingCue(.microphoneStalled, mode: mode)
            Log.log(String(format: "dictation: WARNING stopped early — the microphone stalled after %.1fs of "
                           + "audio, %.1fs into the dictation", duration, heldSeconds))
            live?.trace.note("stopped early: microphone stalled")
        }

        if let live { noteLeadingLevels(live, pcm: pcm) }
        // In memory only. Whether it is ever written down is `record`'s call.
        let clip = WAVFile(sampleRate: AudioRecorder.asrSampleRate, samples: pcm).data

        let silent = peak < Self.silencePeak && rms < Self.silenceRMS
        if silent {
            if let live { cancelStream(live) }
            // Nothing was captured at all, on a press far too long to be a brush
            // of the key. The microphone is broken, not the room quiet — and this
            // is the one failure that would otherwise pass in complete silence,
            // because both cues are gated on audio that never arrived. Say so.
            if pcm.isEmpty, heldSeconds > Self.accidentalTapSeconds {
                Log.log(String(format: "dictation: WARNING captured no audio in %.1fs of recording — "
                               + "nothing to transcribe. The capture graph never delivered a buffer "
                               + "(check the microphone device, or a configuration change that killed it).",
                               heldSeconds))
                live?.trace.note(String(format: "captured nothing in %.1fs", heldSeconds))
                live?.trace.flush()
                // Not `playClosingCue`: there is no closing to announce, and the
                // start chirp this would silence never played either.
                if !micStalled { whenOutputIsBack { SoundEffect.captureFailed.play() } }
                record(clip: nil, duration: heldSeconds, transcript: "", command: isCommand,
                       error: "the microphone captured no audio")
                finishDictation()
                return true
            }
            // A stray brush of the trigger key: stay completely quiet about it
            // unless the start cue already told the user we were listening.
            if duration <= Self.accidentalTapSeconds {
                live?.trace.note(String(format: "discarded silent %.2fs tap", duration))
                live?.trace.flush()
                if announcedListening, !micStalled { playClosingCue(.silenceSkipped, mode: mode) }
                finishDictation()
                return true
            }
            if !micStalled { playClosingCue(.silenceSkipped, mode: mode) }
            live?.trace.note("no speech detected")
            live?.trace.flush()
            record(clip: clip, duration: duration, transcript: "", command: isCommand,
                   error: "no speech detected")
            finishDictation()
            return true
        }

        // Say it at the moment it starts costing: a stream that has already
        // failed means this dictation goes the long way round, so the finish
        // cue carries a low tail instead of ending clean (see StreamHealth).
        let slow = live?.leg?.isBroken ?? false
        if !micStalled { playClosingCue(slow ? mode.slowFinishCue : mode.finishCue, mode: mode) }
        onStatus?(.transcribing)
        startTranscriptionProgressCue()
        // Bind the routing context to *this* dictation rather than reading shared
        // state when the transcript lands. The user can start a new dictation while
        // this one is still transcribing, and anything ambient will by then describe
        // that newer one — which would paste a command, or dispatch a plain
        // dictation as one, and file either in the wrong history list. (`mode` is
        // already per-dictation: it lives on the `LiveDictation`.)
        let routingContext = context
        let entryID = UUID()
        if let live, let shadow = live.shadow {
            runShadow(shadow, tail: live.tailPCM, pcm: pcm, entryID: entryID)
        }
        Task { [weak self] in
            guard let self else { return }
            defer { live?.trace.flush() }
            do {
                let transcript = try await self.transcribe(live, clip: clip)
                self.stopTranscriptionProgressCue()
                let text = isCommand ? transcript.text : style.apply(to: transcript.text)
                self.record(clip: clip, duration: duration, transcript: text, raw: transcript.raw,
                            command: isCommand, error: nil, id: entryID)
                switch style.delivery(of: transcript.text, command: isCommand) {
                case .none:
                    if style.discard { live?.trace.note("discarded") }
                case .route(let command):
                    if let routingContext { self.onCommand?(command, routingContext) }
                case .paste(let styled):
                    self.pasteAndRemember(styled)
                }
                live?.trace.mark("done")
            } catch {
                self.stopTranscriptionProgressCue()
                Log.log("transcribe failed: \(error)")
                let provider = live?.leg?.provider.id ?? TranscriptionPreferences.primary
                self.noteStreamHealth(.degraded(reason: TranscriberError.userMessage(for: error), provider: provider))
                live?.trace.note("failed: \(TranscriberError.userMessage(for: error))")
                self.whenOutputIsBack { SoundEffect.transcriptionFailed.play() }
                self.record(clip: clip, duration: duration, transcript: "", command: isCommand,
                            error: TranscriberError.userMessage(for: error), id: entryID)
            }
            self.finishDictation()
        }
        return true
    }

    /// Finish the live session if we have one; it falls back to the provider's
    /// whole-clip path if the session never opened or failed. The fallback is a
    /// genuine failure path — routine appearances in the log mean the streaming
    /// path is broken, not that this is normal.
    private func transcribe(_ live: LiveDictation?, clip: Data) async throws -> Transcript {
        guard let live, let leg = live.leg else {
            return try await currentProvider().transcribe(wavData: clip)
        }
        let tail = live.tailPCM
        live.tailPCM = Data()
        let outcome = try await leg.finish(tail: tail, openGrace: Self.streamOpenGrace,
                                           clip: { clip })
        noteStreamHealth(outcome.liveFailure.map { .degraded(reason: $0, provider: leg.provider.id) } ?? .streaming)
        return outcome.transcript
    }

    /// Finish the shadow leg on its own, and file what it said beside the history
    /// entry `entryID` — whenever that lands, before or after the primary's.
    /// Nothing waits for this: not the paste, not the closing cue, not a restart.
    private func runShadow(_ leg: TranscriptionLeg, tail: Data, pcm: Data, entryID: UUID) {
        let keyUp = ContinuousClock.now
        leg.trace.mark("key-up")
        Task { [weak self] in
            var result = ShadowTranscript(provider: leg.provider.id.rawValue)
            do {
                let outcome = try await leg.finish(tail: tail, openGrace: Self.streamOpenGrace, clip: {
                    WAVFile(sampleRate: AudioRecorder.asrSampleRate, samples: pcm).data
                })
                result.text = outcome.text
                leg.trace.note("\(outcome.text.count) chars")
            } catch {
                let message = TranscriberError.userMessage(for: error)
                result.error = message
                leg.trace.note("failed: \(message)")
            }
            result.latencyMS = Int(keyUp.duration(to: .now) / .milliseconds(1))
            leg.trace.mark("done")
            leg.trace.flush()
            self?.attachShadow(result, to: entryID)
        }
    }

    private func attachShadow(_ shadow: ShadowTranscript, to id: UUID) {
        if let i = sttHistory.firstIndex(where: { $0.id == id }) {
            sttHistory[i].shadow = shadow
        } else if let i = commandHistory.firstIndex(where: { $0.id == id }) {
            commandHistory[i].shadow = shadow
        } else {
            // The primary has not filed its entry yet; `record` picks this up.
            pendingShadows[id] = shadow
            return
        }
        save()
    }

    /// The most recent dictation's shadow transcript, if any dictation has one.
    var lastShadow: ShadowTranscript? {
        let stt = sttHistory.first { $0.shadow != nil }.map { ($0.date, $0.shadow!) }
        let command = commandHistory.first { $0.shadow != nil }.map { ($0.date, $0.shadow!) }
        return [stt, command].compactMap { $0 }.max { $0.0 < $1.0 }?.1
    }

    /// Copy the last shadow transcript (the menu's "Copy Last Shadow Transcript").
    func copyLastShadow() {
        guard let text = lastShadow?.text, !text.isEmpty else {
            SoundEffect.transcriptionFailed.play(); return
        }
        copy(text)
        SoundEffect.clipFinished.play()
    }

    func copyShadowSTT(id: UUID) { if let t = sttHistory.first(where: { $0.id == id })?.shadow?.text { copy(t) } }
    func copyShadowCommand(id: UUID) { if let t = commandHistory.first(where: { $0.id == id })?.shadow?.text { copy(t) } }

    /// Release a dictation's live session. Idempotent, and safe to call whether or
    /// not it ever opened.
    private func cancelStream(_ live: LiveDictation) {
        live.leg?.cancel()
        live.shadow?.cancel()
    }

    /// Record how loud the opening half-second was, in 50 ms bins.
    ///
    /// Expect the first two bins to hold the start cue. What matters is what
    /// follows: if those bins are near zero and speech only appears several bins
    /// in, the user was talking before capture caught up — the empirical answer
    /// to "why did it miss my first words".
    private func noteLeadingLevels(_ live: LiveDictation, pcm: Data) {
        let profile = AudioRecorder.leadingLevelProfile(pcm16: pcm)
        guard !profile.isEmpty else { return }
        live.trace.note("lead(50ms bins) " + profile.map { String(format: "%.3f", $0) }.joined(separator: ","))
    }

    // MARK: - Other actions

    func speakClipboard() {
        if playbackControls.replaying { haltSpeech(); return }
        // Toggle: stop whatever is speaking/queued; otherwise speak the clipboard.
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        Log.log("speak-clipboard: \(text.count) char(s) on the clipboard")
        SpeechJobManager.shared.speakOrStop(text: text)
    }

    func summarizeClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            Log.log("summarize-clipboard: clipboard has no text — nothing to summarize")
            return
        }
        // `askHaiku` refuses too; this is for the cue, without a "summarizing" status first.
        guard Incognito.allows(ClaudeSummarizer.incognitoActivity) else {
            Log.log("summarize-clipboard: incognito mode — not sending the clipboard to Claude")
            SoundEffect.transcriptionFailed.play(); return
        }
        Log.log("summarize-clipboard: summarizing \(text.count) char(s) via Haiku")
        onStatus?(.summarizing)
        Task { [weak self] in
            defer { self?.onStatus?(.idle) }
            guard let summary = await ClaudeSummarizer.summarizeText(text), !summary.isEmpty else {
                Log.log("summarize-clipboard: no summary returned — clipboard untouched")
                SoundEffect.transcriptionFailed.play(); return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(summary, forType: .string)
            Log.log("summarize-clipboard: wrote \(summary.count)-char summary to the clipboard")
            SoundEffect.clipFinished.play()
        }
    }

    /// ⌘⌃V / ⌘⌃⇧V: insert the last transcript again, by clipboard or by typing
    /// respectively — whatever the "Type Text Instead of Pasting" checkbox says.
    /// Typing waits for the chord's modifiers to be released first.
    func repasteLast(using technique: PasteTechnique) {
        guard let lastInsertion else { return }
        TextInserter.insert(lastInsertion, using: technique, afterModifiersClear: true) { SoundEffect.pasted.play() }
    }
    func retrySTT(id: UUID) { guard let e = sttHistory.first(where: { $0.id == id }), let url = e.wavURL else { return }; retry(url, id: id, command: false) }
    func retryCommand(id: UUID) { guard let e = commandHistory.first(where: { $0.id == id }), let url = e.wavURL else { return }; retry(url, id: id, command: true) }
    func copySTT(id: UUID) { if let e = sttHistory.first(where: { $0.id == id }) { copy(e.transcript) } }
    func copyCommand(id: UUID) { if let e = commandHistory.first(where: { $0.id == id }) { copy(e.transcript) } }
    func copyRawSTT(id: UUID) { if let t = sttHistory.first(where: { $0.id == id })?.raw { copy(t) } }
    func copyRawCommand(id: UUID) { if let t = commandHistory.first(where: { $0.id == id })?.raw { copy(t) } }

    private func retry(_ url: URL, id: UUID, command: Bool) {
        onStatus?(.transcribing)
        startTranscriptionProgressCue()
        Task { [weak self] in
            guard let self else { return }
            defer { self.onStatus?(.idle) }
            do {
                let transcript = try await self.currentProvider().transcribe(wavURL: url)
                let text = transcript.text
                self.stopTranscriptionProgressCue()
                // Pasted, but not written into the (persisted) entry it came from.
                guard Incognito.allows(Self.historyActivity) else {
                    if !command { self.pasteAndRemember(text) }
                    return
                }
                if command {
                    if let i = self.commandHistory.firstIndex(where: { $0.id == id }) {
                        self.commandHistory[i].transcript = text; self.commandHistory[i].raw = transcript.raw
                        self.commandHistory[i].error = nil
                    }
                } else {
                    if let i = self.sttHistory.firstIndex(where: { $0.id == id }) {
                        self.sttHistory[i].transcript = text; self.sttHistory[i].raw = transcript.raw
                        self.sttHistory[i].error = nil
                    }
                    self.pasteAndRemember(text)
                }
                self.save()
            } catch {
                self.stopTranscriptionProgressCue()
                self.whenOutputIsBack { SoundEffect.transcriptionFailed.play() }
            }
        }
    }

    private func finishDictation() {
        stopTranscriptionProgressCue()
        onStatus?(.idle)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.isDictating = false
            self.onDictationEnded?()
        }
    }

    /// Stop any in-flight start chirp, then play the closing cue. The start cue is
    /// short and normally finished by key-up; cutting it avoids rare overlap if
    /// timings tighten, without changing when capture starts or stops.
    private func playClosingCue(_ cue: SoundEffect, mode: DictationMode) {
        mode.startCue.stop()
        whenOutputIsBack { cue.play() }
    }

    /// What waits, after a headset dictation's key-up, for the headset to have
    /// switched back (`headsetQuietAtEnd`): nil when nothing does.
    private var outputPending: [() -> Void]?

    /// `action` now, or once the output is back, if it is still waiting.
    private func whenOutputIsBack(_ action: @escaping () -> Void) {
        if outputPending != nil { outputPending?.append(action) } else { action() }
    }

    /// The headset has switched back: unmute, then what waited for it. Also
    /// called early — by the next dictation, or quitting — to settle it now.
    /// `cueDelay`: the switch back has just ended, and a sound played at once is
    /// lost in it (v0.1.117: no closing cues heard at all), so what waited plays
    /// this much later. Settled early — the next dictation, quitting — it plays at once.
    private func outputIsBack(cueDelay: TimeInterval = 0) {
        guard let pending = outputPending else { return }
        outputPending = nil
        muter.restore()
        guard cueDelay > 0 else { pending.forEach { $0() }; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + cueDelay) { pending.forEach { $0() } }
    }

    /// Starts after a short grace period so quick transcriptions stay quiet,
    /// then repeats once the previous cue has fully played plus its pause.
    private func startTranscriptionProgressCue() {
        stopTranscriptionProgressCue()
        transcriptionProgressTask = Task {
            do {
                try await Task.sleep(for: TranscriptionProgressCue.initialDelay)
                while !Task.isCancelled {
                    // Muted while a headset switches back (`outputPending`): skipped, not queued.
                    if self.outputPending == nil { SoundEffect.transcriptionPending.play() }
                    try await Task.sleep(for: TranscriptionProgressCue.cueDuration)
                    try await Task.sleep(for: TranscriptionProgressCue.repeatGap)
                }
            } catch is CancellationError {
                // Transcription completed or failed while the task was asleep.
            } catch {
                Log.log("transcription progress cue failed: \(error)")
            }
        }
    }

    private func stopTranscriptionProgressCue() {
        transcriptionProgressTask?.cancel()
        transcriptionProgressTask = nil
        SoundEffect.transcriptionPending.stop()
    }

    /// Plays during a synthesis wait so a short sentence followed by a long one
    /// does not sound like the job ended. Separate task from the STT pending cue
    /// so the two loops never cancel each other.
    private func startTTSWaitCue() {
        stopTTSWaitCue()
        ttsWaitCueTask = Task {
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: TTSWaitCue.leadQuiet)
                    SoundEffect.transcriptionPending.play()
                    try await Task.sleep(for: TTSWaitCue.cueDuration)
                    SoundEffect.transcriptionPending.stop()
                    try await Task.sleep(for: TTSWaitCue.trailQuiet)
                }
            } catch is CancellationError {
                // Playback began (or halted) while waiting / echoing.
            } catch {
                Log.log("tts wait cue failed: \(error)")
            }
        }
    }

    private func stopTTSWaitCue() {
        ttsWaitCueTask?.cancel()
        ttsWaitCueTask = nil
        SoundEffect.transcriptionPending.stop()
    }

    /// The cue fires from the completion, not alongside the call: on the
    /// keystroke path the transcript is still going out character by character
    /// for the better part of a second, and a cue that plays at the start would
    /// announce text that is not there yet.
    private func pasteAndRemember(_ text: String) {
        // Re-paste keeps the transcript after the dictation is over, so incognito
        // drops it (and any older one) instead.
        lastInsertion = Incognito.isOn ? nil : text
        // After a headset dictation the output is still muted for the switch back: the cue waits for it.
        TextInserter.insert(text) { [weak self] in self?.whenOutputIsBack { SoundEffect.pasted.play() } }
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    /// What incognito refuses when a dictation would be filed: the clip and the
    /// transcript, both written to Application Support.
    nonisolated static let historyActivity = Incognito.Activity.persist("dictation history")

    private func persist(_ clip: Data) -> URL? {
        guard Incognito.refusal(Self.historyActivity) == nil else { return nil }
        let dst = sttDir.appendingPathComponent("\(UUID().uuidString).wav")
        do { try clip.write(to: dst) } catch { Log.log("history: could not keep the clip: \(error)"); return nil }
        return dst
    }
    /// File the dictation in history. `clip` is nil when there is no clip worth
    /// keeping — a capture that produced no samples has nothing to retry from.
    ///
    /// In incognito mode nothing is filed at all, not even in memory: the menu's
    /// recent lists would otherwise hold the transcript after the dictation ended.
    private func record(clip: Data?, duration: TimeInterval, transcript: String, raw: String? = nil,
                        command: Bool, error: String?, id: UUID = UUID()) {
        guard Incognito.refusal(Self.historyActivity) == nil else {
            pendingShadows.removeValue(forKey: id)
            return
        }
        let stored = clip.flatMap(persist)
        let shadow = pendingShadows.removeValue(forKey: id)
        if command { commandHistory.insert(CommandHistoryEntry(id: id, date: Date(), duration: duration, transcript: transcript, recognized: false, error: error, wavURL: stored, shadow: shadow, raw: raw), at: 0) }
        else { sttHistory.insert(STTHistoryEntry(id: id, date: Date(), duration: duration, transcript: transcript, error: error, wavURL: stored, shadow: shadow, raw: raw), at: 0) }
        save()
    }
    private func save() { historyStore.save(.init(stt: sttHistory, commands: commandHistory)); onHistoryChanged?() }

    func playSentence(_ request: SpeechJobManager.SentencePlayback,
                      onStart: @escaping @Sendable () -> Void = {},
                      onSynthesized: @escaping @Sendable () -> Void = {}) async -> SpeechJobManager.SentenceOutcome {
        guard !isDictating else { onSynthesized(); return .interrupted(lastStoppedAt) }
        let id = request.jobID
        if speechSessionID != id {
            speechExpiry?.cancel()
            tts.beginSession(rate: PlaybackPreferences().rate)
            speechSessionID = id
            lastStoppedAt = nil
            playbackControls = PlaybackControls(rate: PlaybackPreferences().rate)
            wordOverlay.beginSession(position: { [weak self] in self?.tts.position ?? 0 })
            tts.onDrain = { [weak self] in
                guard let self, self.speechSessionID == id, self.playbackControls.completed else { return }
                self.finishSpeechPlayback()
            }
        }
        queueSpeechActive = true
        refreshSpeechActivity()
        onPlaybackControlsChanged?()
        onStatus?(.requestingTTS)
        startTTSWaitCue()
        let prepared = TTSPreprocess.prepare(request.text)
        let utterance = Utterance(text: prepared.ttsText, voiceID: request.voice)
        let timingsTask = Task { await self.tts.wordTimings(for: utterance) }
        wordOverlay.appendSentence(start: tts.duration, prepared: prepared, timings: { await timingsTask.value })
        let result = await tts.play(utterance, startGate: duckingStartGate(), onStart: { [weak self] in
            guard let self, self.speechSessionID == id, !self.isDictating else { return }
            self.stopTTSWaitCue()
            self.onStatus?(.speaking)
            self.onPlaybackControlsChanged?()
            onStart()
        }, onSynthesized: { onSynthesized() })
        // The session is replaced by `haltSpeech`, so losing it means something
        // stopped this on purpose — not that the audio broke.
        guard speechSessionID == id else { return .interrupted(lastStoppedAt) }
        stopTTSWaitCue()
        if result && request.isLast {
            finishSpeechPlayback()
            // A rewind can arrive after the last sample's completion callback
            // but before this await resumes. Keep that local replay audible.
            if !tts.atEnd {
                _ = playbackControls.rewind(now: ProcessInfo.processInfo.systemUptime)
                speechExpiry?.cancel()
                refreshSpeechActivity()
            }
        } else if !result {
            return .interrupted(haltSpeech())
        }
        return .finished
    }

    /// The furthest back `haltSpeech(heardUntil:)` will date a stop.
    static let maxHeardUntilSeconds: TimeInterval = 10

    /// Where the voice is in the sentence playing now, without stopping it.
    func spokenPosition() -> SpokenPosition? {
        wordOverlay.narration.spokenPrefix(at: tts.position)
    }

    /// Stop speaking, and report how far the voice actually got.
    ///
    /// The position is read first because stopping is what throws it away: the
    /// player's clock is reset by `tts.stop()` and the word timings by
    /// `wordOverlay.stop()`. Reading it anywhere else in this method would
    /// report a narration that no longer exists.
    ///
    /// One interruption can reach this twice. Dictation halts the voice itself
    /// for latency — the microphone must not be fighting the speakers — and the
    /// speech queue's own halt follows an actor hop later, by which time there
    /// is nothing left to measure. The second call answers with what the first
    /// one found, so which of the two a caller happens to be does not decide
    /// whether the interruption has a position.
    ///
    /// `heardUntil`: the listener stopped hearing the voice then, before this
    /// call — they began talking over it, and the stop was decided later (a
    /// phone's hands-free mode checks the speech was words first). The
    /// position is read as it was at that moment. At most
    /// `maxHeardUntilSeconds` back.
    @discardableResult
    func haltSpeech(heardUntil: Date? = nil) -> SpokenPosition? {
        let back = heardUntil.map { min(Self.maxHeardUntilSeconds, max(0, Date().timeIntervalSince($0))) } ?? 0
        let position = back > 0 ? tts.position(at: ProcessInfo.processInfo.systemUptime - back) : tts.position
        let measured = wordOverlay.narration.spokenPrefix(at: position)
        if let measured {
            // The output latency is what decides whether a headset's words count: say what it was.
            Log.log(String(format: "tts halt: heard to %.2fs (%@output latency %.0f ms, %@) — %d chars into sentence %d",
                           position, back > 0 ? String(format: "dated %.0f ms back, ", back * 1000) : "",
                           tts.outputLatency * 1000, OutputDevice.summary, measured.characterOffset, measured.sentence + 1))
        }
        let stoppedAt = measured ?? lastStoppedAt
        lastStoppedAt = stoppedAt
        speechExpiry?.cancel(); speechExpiry = nil
        speechSessionID = nil
        playbackControls = PlaybackControls(rate: PlaybackPreferences().rate)
        queueSpeechActive = false
        tts.stop()
        recorder.replaceEngineIfStale()
        stopTTSWaitCue()
        wordOverlay.stop()
        refreshSpeechActivity()
        onPlaybackControlsChanged?()
        return stoppedAt
    }

    func adjustSpeechRate(by delta: Float) {
        guard canAdjustSpeech else { return }
        playbackControls.adjust(by: delta)
        PlaybackPreferences().rate = playbackControls.rate
        tts.setPlaybackRate(playbackControls.rate)
        wordOverlay.refresh()
        onPlaybackControlsChanged?()
    }

    func rewindSpeech(seconds: Double) {
        guard canRewindSpeech, tts.rewind(seconds: seconds) else { return }
        _ = playbackControls.rewind(now: ProcessInfo.processInfo.systemUptime)
        speechExpiry?.cancel(); speechExpiry = nil
        stopTTSWaitCue()
        refreshSpeechActivity()
        onStatus?(.speaking)
        wordOverlay.refresh()
        onPlaybackControlsChanged?()
        Log.log(String(format: "tts rewind: %.1fs → %.2fs (job %@)", seconds, tts.position, speechSessionID ?? ""))
    }

    func skipSpeechAhead(seconds: Double) {
        guard canAdjustSpeech, tts.skipAhead(seconds: seconds) else { return }
        wordOverlay.refresh()
        onPlaybackControlsChanged?()
        Log.log(String(format: "tts skip ahead: %.1fs (job %@)", seconds, speechSessionID ?? ""))
    }

    /// Natural completion retains the local session for two seconds. HTTP jobs
    /// still complete normally: replay never reopens a terminal external job.
    private func finishSpeechPlayback() {
        guard let id = speechSessionID else { return }
        playbackControls.finish(now: ProcessInfo.processInfo.systemUptime)
        speechExpiry?.cancel()
        speechExpiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, self.speechSessionID == id,
                  !self.playbackControls.replaying, self.tts.atEnd else { return }
            self.speechSessionID = nil
            self.playbackControls = PlaybackControls(rate: PlaybackPreferences().rate)
            self.tts.stop()
            // Tearing the speech engine down touches the output device too.
            self.recorder.speechEnded()
            // The speech engine is gone; get the capture engine it left unable
            // to open AirPods replaced before the next dictation needs it.
            self.recorder.replaceEngineIfStale()
            self.wordOverlay.stop()
            self.onPlaybackControlsChanged?()
        }
        refreshSpeechActivity()
        onPlaybackControlsChanged?()
    }

    func setSpeechActive(_ active: Bool) {
        queueSpeechActive = active && !isDictating
        refreshSpeechActivity()
    }

    private func refreshSpeechActivity() {
        let active = !isDictating && (queueSpeechActive || playbackControls.replaying)
        let wasSpeaking = isSpeaking
        isSpeaking = active
        if active {
            applyDucking(announce: !wasSpeaking)
            wordOverlay.activate()
        } else {
            narrationDucker.stop()
            wordOverlay.hide()
            if !isDictating { onStatus?(.idle) }
        }
        if wasSpeaking && !active {
            recorder.speechEnded()
            onSpeechIdle?()
        }
        onPlaybackControlsChanged?()
    }
    /// Whether narration ducks other audio, and if not, why. The one decision
    /// behind both starting the ducker (`applyDucking`) and holding a session's
    /// first audio until it is up (`duckingStartGate`).
    private enum DuckingDecision: Equatable {
        case duck
        /// Voice Processing I/O opens the microphone and runs echo cancellation,
        /// which puts AirPods and every other Bluetooth headset into its call
        /// profile: low-rate, distorted playback, with the canceller working
        /// against our own speech.
        case offBluetooth
        /// Hands-free holds the microphone. The ducker's Voice Processing I/O graph
        /// takes the input device as it starts and stops: every reply was two
        /// configuration changes, each tearing the held microphone down (its light
        /// going off, audio cutting out), and three in 30 s stood the hold down
        /// altogether. Listening through speech matters more than ducking other audio.
        case offHandsFree
    }

    private var duckingDecision: DuckingDecision {
        if OutputDevice.isWireless { return .offBluetooth }
        if recorder.hasListener { return .offHandsFree }
        return .duck
    }

    private func applyDucking(announce: Bool) {
        switch duckingDecision {
        case .duck:
            narrationDucker.start()
        case .offBluetooth:
            narrationDucker.stop()
            if announce { Log.log("tts ducking: off on Bluetooth output — \(OutputDevice.summary)") }
        case .offHandsFree:
            narrationDucker.stop()
            if announce { Log.log("tts ducking: off while hands-free holds the microphone") }
        }
    }

    /// The default output device changed. Ducking follows it: dropped the moment
    /// a Bluetooth headset becomes the output, restored when it goes, if speech is
    /// playing at the time. (The player rebuilds itself — see `StreamingSpeechPlayer`.)
    func outputDeviceChanged() {
        guard isSpeaking else { return }
        applyDucking(announce: true)
    }

    /// Starting the ducker's Voice Processing I/O graph reconfigures the output
    /// device, which is an audible cut-out on the built-in speakers and on a USB
    /// headset dongle (EPOS BTD 800) alike. The graph takes about a second to
    /// start, so unheld, the cut-out lands on the first words of speech: always
    /// when the first sentence is cached (a replay, a recurring "Isaac here."),
    /// and on any output whose first sentence synthesizes faster than that. So
    /// whenever the ducker is starting, a session's first audio waits for it.
    /// When the first sentence must be synthesized, the wait mostly overlaps it.
    private func duckingStartGate() -> (@MainActor () async -> Void)? {
        guard duckingDecision == .duck else { return nil }
        let ducker = narrationDucker
        return {
            let began = ContinuousClock.now
            await ducker.ready(timeout: .seconds(3))
            Log.log("tts: first audio held \(began.duration(to: .now).formatted(.units(allowed: [.milliseconds]))) "
                    + "for ducking to start — \(OutputDevice.summary)")
        }
    }

    func prefetchSentence(text: String, voiceID: String) async {
        // Must transform identically to `playSentence`, so the cache keys match
        // and the prefetched audio/timings are the ones playback finds.
        let ttsText = TTSPreprocess.ttsText(text)
        await tts.prefetch(text: ttsText, voiceID: voiceID)
        // Warm word timings for this lookahead sentence too, so when it reaches
        // playback the overlay has them immediately (no first-word miss). Cached,
        // so the play-time fetch is then free. Fire-and-forget.
        let utterance = Utterance(text: ttsText, voiceID: voiceID)
        Task { _ = await tts.wordTimings(for: utterance) }
    }
}

struct DictationContext: Sendable {
    let bundleIdentifier: String?
}
