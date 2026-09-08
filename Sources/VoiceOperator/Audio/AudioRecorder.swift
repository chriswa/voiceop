import AVFoundation

/// Captures the default input device to 16 kHz mono s16le — the format Wispr's
/// ASR expects. Audio is converted *live* in the tap (AVAudioConverter from the
/// hardware format) and accumulated in memory, so callers can read partial audio
/// mid-recording: that is what lets the arbiter upload packets while the user is
/// still talking, the way Wispr Flow does. `stop()` writes the accumulated
/// samples out as a WAV for history/retry.
///
/// `onFirstAudio` fires the moment the first buffer with real frames arrives.
/// That instant — not `start()` returning — is when the microphone is genuinely
/// live, so it is both what the "safe to talk" chirp waits for and the number to
/// look at when words go missing from the front of a dictation.
///
/// Requires the Microphone entitlement + user grant at runtime. Emits capture
/// diagnostics (input format, peak level, frame count) to `Log` so silent-audio
/// problems ("you" hallucinations from Whisper) are easy to spot.
final class AudioRecorder: @unchecked Sendable {
    /// The ASR wire format: 16 kHz mono 16-bit PCM (2 bytes per sample).
    static let asrSampleRate = 16_000

    private let engine = AVAudioEngine()

    /// Every touch of the engine graph — tap install/removal, start, stop — runs
    /// here, and nowhere else. Two reasons, and the second is the important one:
    ///
    ///  1. `AVAudioEngine.start()` blocks until the input device is actually
    ///     running, which on an idle built-in microphone is routinely 700–1000 ms
    ///     (measured on a 2019 Intel MacBook Pro; the tail reaches 4 s). It cannot
    ///     be on the main thread — see `start()`.
    ///  2. Because it is *serial*, a stop always executes after the start it
    ///     follows even when that start is still parked in the driver, and the
    ///     next dictation's tap install always executes after that stop. Ordering
    ///     the graph mutations any other way lets a new recording's tap be torn
    ///     down by the previous recording's stop.
    private let engineQueue = DispatchQueue(label: "com.voiceoperator.audio-engine",
                                            qos: .userInitiated)

    /// Everything the audio-tap thread and the main thread share. `AVAudioConverter`
    /// is not thread-safe and `stop()` flushes it from the main thread, so it lives
    /// under the same lock as the buffer it writes into.
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var inputSampleRate: Double = 0
    /// Converted s16le@16k bytes captured so far.
    private var captured = Data()
    /// Bumped by every `start()`. A tap callback still unwinding on the audio
    /// thread when the next recording begins carries the old value and is
    /// dropped — otherwise its buffer would be prepended to the new recording
    /// and its `sawFirstAudio` write would suppress the new "safe to talk" cue.
    private var generation = 0
    private var sawFirstAudio = false
    private var meteringStartByte = 0
    private var trace: DictationTrace?
    private var firstAudioHandler: (@Sendable () -> Void)?
    private var startFailureHandler: (@Sendable (String) -> Void)?
    /// The bus format the live tap is delivering, recorded when the tap was
    /// installed. Held here rather than captured into a queue block:
    /// `AVAudioFormat` is not `Sendable`, and this class already takes
    /// responsibility for its own state via `lock`. It seeds the converter for a
    /// dictation that reuses a held-open tap; `rebuildConverterIfNeededLocked`
    /// is what keeps the converter honest if it turns out to be stale.
    private var tapFormat: AVAudioFormat?

    /// Whether the capture graph is held open between dictations — the "Keep
    /// Microphone Always On" preference (`AudioPreferences`).
    ///
    /// A Bluetooth headset renegotiates its codec every time an input stream
    /// opens or closes, so an AirPods user pays a stall *and* an audible drop in
    /// playback quality at both ends of every dictation. Holding the input open
    /// costs a permanently lit microphone indicator and leaves the headset in its
    /// voice profile for good; in exchange the switch simply never happens.
    private var alwaysOn = false
    /// Whether tap buffers are being kept. False between dictations, including
    /// while the always-on tap is running — that audio is dropped on the audio
    /// thread without ever reaching the converter.
    private var capturing = false
    /// Bumped every time the tap is installed or removed. A buffer still
    /// unwinding from a tap we have since torn down carries an older value and is
    /// dropped, the way `generation` retires a stale *recording's* buffers.
    /// The two are separate because with the microphone held open one tap serves
    /// every dictation, so tap identity no longer tracks recording identity.
    private var tapNumber = 0
    /// Whether the tap is installed and the device running *right now*. Written
    /// on `engineQueue` once the graph has actually changed; read by `start()` to
    /// decide whether it can skip the device wake-up entirely.
    private var micIsOpen = false

    /// When the held-open microphone was last brought up by `openMicNow`. A
    /// configuration change arriving within `selfInflictedWindow` of it is one we
    /// caused, and must not be rebuilt for — see `configurationChanged`.
    private var lastHeldOpenAt: Date?
    /// Rebuilds attempted inside the current `rebuildWindow`, and when that
    /// window opened. The burst limiter that stops us fighting a device
    /// something else keeps moving.
    private var rebuildCount = 0
    private var rebuildWindowStart: Date?
    /// Set when the limiter has given up: the preference is still on, but we have
    /// stopped rebuilding the graph for configuration changes. Cleared whenever
    /// `setAlwaysOn` turns the hold back on, which is what an AirPod going back
    /// in the ear does (via `AppCoordinator.applyMicrophonePolicy`).
    private var holdSuspended = false

    /// Duration (seconds) of the most recently stopped clip.
    private(set) var lastDurationSeconds: Double = 0
    /// Peak amplitude and RMS energy of the most recently stopped clip (0…1).
    /// Used to skip transcription when the user said nothing (silence gate).
    private(set) var lastPeak: Float = 0
    private(set) var lastRMS: Float = 0

    enum RecorderError: Error { case alreadyRecording, notRecording, conversionFailed }

    private(set) var isRecording = false

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(configurationChanged),
            name: .AVAudioEngineConfigurationChange, object: engine)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Fired once per recording, on the audio thread, when the first buffer
    /// containing frames arrives. Set it before `start()`.
    var onFirstAudio: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return firstAudioHandler }
        set { lock.lock(); firstAudioHandler = newValue; lock.unlock() }
    }

    /// Fired **on the main thread** if the audio device fails to come up. `start()`
    /// only validates the graph synchronously; the device is spun up afterwards,
    /// so this is the only way a caller learns that the microphone never opened.
    /// `isRecording` is already back to false by the time it runs. Carries a
    /// rendered reason rather than the `Error` itself, which is not `Sendable`.
    var onStartFailed: (@Sendable (String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return startFailureHandler }
        set { lock.lock(); startFailureHandler = newValue; lock.unlock() }
    }

    /// The recording currently being captured. A tap buffer or a queued graph
    /// mutation carrying an older value belongs to a recording that has since
    /// been stopped, and is dropped.
    private var currentGeneration: Int {
        lock.lock(); defer { lock.unlock() }; return generation
    }

    /// Exclude the next `seconds` of audio from the peak/RMS measurement, counting
    /// from whatever has been captured *right now*.
    ///
    /// The "safe to talk" cue plays once capture is live rather than before it, so
    /// the microphone hears it. Left in the measurement it would read as voice
    /// energy and defeat the silence gate entirely — every stray tap of the
    /// trigger key would look like speech. Anchoring to the live byte count rather
    /// than to a fixed offset from sample zero keeps this correct no matter how
    /// long CoreAudio took to deliver that first buffer. The audio itself is
    /// untouched: this only narrows what the gate *measures*.
    func excludeFromMetering(seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        meteringStartByte = captured.count + Int(seconds * Double(Self.asrSampleRate)) * 2
    }

    /// Bytes of converted audio available so far (thread-safe; grows while
    /// recording). 1 second of audio = `asrSampleRate * 2` bytes.
    var capturedByteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return captured.count
    }

    /// Copy of captured bytes starting at `offset`, at most `maxCount` long
    /// (clamped to what's available; thread-safe).
    func capturedData(offset: Int, maxCount: Int) -> Data {
        lock.lock(); defer { lock.unlock() }
        guard offset < captured.count else { return Data() }
        return captured.subdata(in: offset..<min(offset + maxCount, captured.count))
    }

    /// Begin capturing.
    ///
    /// Returns as soon as the capture graph is *configured* — a millisecond or
    /// two. The audio device itself is spun up on `engineQueue`, because
    /// `AVAudioEngine.start()` blocks for as long as the hardware takes to wake,
    /// and on a built-in microphone that has gone idle that is routinely
    /// 700–1000 ms.
    ///
    /// It must not block, because this is called straight out of the trigger
    /// key's event-tap callback. Blocking here freezes key handling for the whole
    /// wake-up: the key-*up* that ends a push-to-talk, and the second press of a
    /// double-tap, both queue behind it and are then handled a second late — at
    /// which point `HotkeyMonitor` reads a 20 ms tap as a one-second hold and
    /// stops the dictation the user was trying to lock on. macOS also disables an
    /// event tap whose callback is that slow. (This is what
    /// "the Fn key does nothing for a second, then beeps on and straight off" was.)
    ///
    /// Nothing downstream needs the device to be live before this returns: the
    /// tap is installed ahead of the start, `onFirstAudio` reports the instant
    /// samples genuinely begin, and the upload pump only ever sends what has
    /// actually been captured. Failure is reported later via `onStartFailed`.
    func start(trace: DictationTrace? = nil) throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }
        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        if auth != .authorized {
            Log.log("recorder: mic not authorized (status \(auth.rawValue)) — capture will be silent")
        }
        lock.lock()
        let openFormat = micIsOpen ? tapFormat : nil
        lock.unlock()
        // With the microphone already held open, the running tap's format is the
        // one buffers will actually arrive in — ask the node again and a device
        // that has since changed underneath it answers for the wrong hardware.
        let format = openFormat ?? engine.inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            Log.log("recorder: ERROR invalid input format — no microphone input available")
            throw RecorderError.conversionFailed
        }
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: Double(Self.asrSampleRate),
                                            channels: 1, interleaved: true),
              let conv = AVAudioConverter(from: format, to: outFormat) else {
            Log.log("recorder: ERROR cannot build \(format.sampleRate)Hz→16kHz converter")
            throw RecorderError.conversionFailed
        }
        lock.lock()
        generation += 1
        let recording = generation
        converter = conv
        inputSampleRate = format.sampleRate
        tapFormat = format
        captured = Data()
        sawFirstAudio = false
        meteringStartByte = 0
        capturing = true
        self.trace = trace
        let alreadyOpen = micIsOpen
        lock.unlock()
        isRecording = true

        // Always-on: the microphone is already live and its tap starts feeding
        // this recording on its very next buffer — no device wake-up, and on
        // Bluetooth no codec renegotiation. That is the whole point of the
        // preference, and it is why none of the graph work below runs. (The first
        // buffer can be up to one buffer-length old, which only ever helps: it is
        // the audio immediately *before* the key went down.)
        if alreadyOpen {
            trace?.mark("engine-live")
            return
        }

        engineQueue.async { [weak self] in
            guard let self else { return }
            // Stopped while we were queued (or while a previous start was still
            // blocked in the driver). Don't wake a device nobody is listening to.
            self.lock.lock()
            let stale = recording != self.generation
            self.lock.unlock()
            guard !stale else { return }

            if let reason = self.openMic(trace: trace) {
                Log.log("recorder: engine start failed — \(reason)")
                trace?.note("engine start failed: \(reason)")
                self.reportStartFailure(reason, generation: recording)
            }
        }
    }

    // MARK: - Holding the microphone open

    /// Whether the microphone is held open between dictations.
    var isAlwaysOn: Bool {
        lock.lock(); defer { lock.unlock() }; return alwaysOn
    }

    /// Turn the always-open microphone on or off.
    ///
    /// Applied immediately when idle. Flipped *during* a dictation it only
    /// records the wish — the graph must not be rebuilt under a live recording —
    /// and `stop()` reconciles, so turning it on mid-dictation keeps the device
    /// up afterwards and turning it off releases it.
    func setAlwaysOn(_ on: Bool) {
        lock.lock()
        guard on != alwaysOn else { lock.unlock(); return }
        alwaysOn = on
        // A fresh decision deserves a fresh budget: whatever made us stand down
        // last time (AirPods out, music fighting us for the device) is over as
        // far as we know, so the limiter starts again from zero.
        holdSuspended = false
        rebuildCount = 0
        rebuildWindowStart = nil
        lastHeldOpenAt = nil
        let recording = capturing
        lock.unlock()
        Log.log("recorder: always-on microphone \(on ? "enabled" : "disabled")")
        guard !recording else { return }
        if on { openMicAfterSettling() } else { engineQueue.async { [weak self] in self?.closeMic() } }
    }

    /// How long to let the audio system settle before opening the microphone in
    /// response to a device change, and how many times to try again after that.
    private static let deviceSettle: DispatchTimeInterval = .milliseconds(400)
    private static let openAttempts = 8

    /// Opening the microphone on a Bluetooth headset *is itself* a configuration
    /// change — the device flips into its voice profile a beat later. A change
    /// this soon after our own open is therefore ours, not the hardware moving.
    private static let selfInflictedWindow: TimeInterval = 1.0
    /// How many rebuilds we will attempt in `rebuildWindow` seconds before
    /// concluding that something else is moving the device faster than we can
    /// follow, and standing down.
    ///
    /// **Calibrated against the slow flap, not the fast one.** Music playing
    /// through the same headset trades the device back and forth on a ~3.4 s
    /// cycle (v0.1.32, 2026-09-06) — far too slow to look like a burst, and the
    /// first values here (4 in 10 s) never tripped on it while it cut the user's
    /// audio indefinitely. A genuine device change is isolated, and reconnecting
    /// a headset re-arms this through `setAlwaysOn` anyway, so the budget can be
    /// this small without costing anything real.
    private static let rebuildWindow: TimeInterval = 30
    private static let maxRebuildsPerWindow = 2

    /// Open the microphone once the hardware has stopped moving.
    ///
    /// **The delay is the fix for a crash** (v0.1.24, 2026-09-05: `abort()` inside
    /// `installTapOnBus:`, one second after AirPods reconnected). Opening the
    /// instant the default *output* device changed meant reading the input node's
    /// format while the *input* device was still switching underneath it, and
    /// `installTap` raises an ObjC exception — which Swift cannot catch, so it
    /// takes the process with it — when the format it is handed disagrees with
    /// the bus's real one. Waiting is only half the answer; `openMic` no longer
    /// hands it a format at all.
    private func openMicAfterSettling() {
        engineQueue.asyncAfter(deadline: .now() + Self.deviceSettle) { [weak self] in
            self?.openMicNow()
        }
    }

    /// Bring the microphone up against whatever the current default input device
    /// is, provided anything still wants it open — the preference, or a dictation
    /// that has begun since this was queued. That second case is not theoretical:
    /// a device change tears the graph down and queues a rebuild here, and if the
    /// user presses the trigger key in that window their `start()` sees the
    /// microphone as already open and does no graph work of its own. This is then
    /// the only thing that can hand them a live tap. **engineQueue only.**
    private func openMicNow(attemptsLeft: Int = openAttempts) {
        lock.lock()
        let wanted = alwaysOn || capturing
        lock.unlock()
        guard wanted else { return }

        guard let reason = openMic(trace: nil) else {
            lock.lock(); let format = tapFormat; lastHeldOpenAt = Date(); lock.unlock()
            Log.log(String(format: "recorder: microphone held open (%.0f Hz, %d ch)",
                           format?.sampleRate ?? 0, format?.channelCount ?? 0))
            return
        }
        // A device that is still arriving reports no usable format for a moment.
        // Keep asking rather than leaving the microphone shut until the next
        // dictation wakes it — that stall is the whole thing this avoids.
        guard attemptsLeft > 1 else {
            Log.log("recorder: gave up holding the microphone open — \(reason)")
            return
        }
        if attemptsLeft == Self.openAttempts {
            Log.log("recorder: microphone not ready yet (\(reason)) — retrying")
        }
        engineQueue.asyncAfter(deadline: .now() + Self.deviceSettle) { [weak self] in
            self?.openMicNow(attemptsLeft: attemptsLeft - 1)
        }
    }

    /// Install the tap and spin the device up, returning a rendered failure
    /// reason or nil.
    ///
    /// Idempotent: with the tap already installed it only makes sure the engine
    /// is running, so a dictation's start and the always-on path can both call it
    /// without ever racing a double `installTap` (both run here, serially).
    ///
    /// **Every precondition here is one that `installTap` would otherwise answer
    /// with `abort()`.** It raises an ObjC exception, which no Swift `do/catch`
    /// can contain, so the alternative to checking is losing the process — and
    /// with it whatever the user was dictating. Hence: a validated bus format, a
    /// nil format on the call itself (meaning "the bus's own", which cannot
    /// disagree with itself the way a format read a moment earlier can), and a
    /// `removeTap` first so a second install is impossible even if `micIsOpen`
    /// were ever wrong. **engineQueue only.**
    private func openMic(trace: DictationTrace?) -> String? {
        let input = engine.inputNode
        lock.lock()
        let alreadyInstalled = micIsOpen
        lock.unlock()
        if !alreadyInstalled {
            // The format the tap will actually be handed. Read here only to be
            // checked and remembered — a device still switching underneath us
            // reports 0 Hz / 0 channels, and installing against that aborts.
            let bus = input.outputFormat(forBus: 0)
            guard bus.sampleRate > 0, bus.channelCount > 0 else {
                return String(format: "input bus not ready (%.0f Hz, %d ch)",
                              bus.sampleRate, bus.channelCount)
            }
            lock.lock()
            tapFormat = bus
            tapNumber += 1
            let tap = tapNumber
            lock.unlock()
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
                self?.handleTap(buffer, tap: tap)
            }
        }
        if engine.isRunning {
            lock.lock(); micIsOpen = true; lock.unlock()
            return nil
        }
        engine.prepare()
        trace?.mark("engine-prepare")
        do {
            try engine.start()
            trace?.mark("engine-start")
            lock.lock(); micIsOpen = true; lock.unlock()
            return nil
        } catch {
            input.removeTap(onBus: 0)
            lock.lock(); micIsOpen = false; tapNumber += 1; lock.unlock()
            return "\(error)"
        }
    }

    /// Tear the tap down and release the device. **engineQueue only.**
    private func closeMic() {
        lock.lock()
        let wasOpen = micIsOpen
        micIsOpen = false
        tapNumber += 1
        lock.unlock()
        if wasOpen { engine.inputNode.removeTap(onBus: 0) }
        engine.stop()
    }

    /// The input hardware changed under a running graph — AirPods connecting, a
    /// dock being unplugged, the headset flipping profiles. AVAudioEngine tears
    /// its graph down when this happens, so a microphone we are holding open has
    /// to be rebuilt against the new format or it silently stays shut until the
    /// next dictation wakes it, which is exactly the stall the preference exists
    /// to remove. Mid-dictation the graph is left alone (the recording keeps what
    /// it has) and `stop()` reconciles.
    @objc private func configurationChanged() {
        lock.lock()
        let wanted = alwaysOn && !capturing
        guard wanted, !holdSuspended else { lock.unlock(); return }

        // **The rebuild must not answer its own notification.** Bringing the
        // microphone up pulls a Bluetooth headset into its voice profile, and
        // that is itself a configuration change — which, rebuilt for, reopens the
        // microphone and changes the configuration again. Left unguarded that is
        // a loop with no exit but the device disappearing, and every turn of it
        // is an audible gap in whatever the user is listening to.
        if let opened = lastHeldOpenAt, Date().timeIntervalSince(opened) < Self.selfInflictedWindow {
            lock.unlock()
            return
        }

        // Past that, the changes are real but may still be unwinnable: music
        // playing through the same headset pulls it back to its media profile as
        // fast as we pull it into the voice one. Rebuilding into that fight is
        // what cuts the user's audio every few seconds, so we count the attempts
        // and stand down rather than keep trying.
        let now = Date()
        if let start = rebuildWindowStart, now.timeIntervalSince(start) < Self.rebuildWindow {
            rebuildCount += 1
        } else {
            rebuildWindowStart = now
            rebuildCount = 1
        }
        let standDown = rebuildCount > Self.maxRebuildsPerWindow
        if standDown { holdSuspended = true }
        lock.unlock()

        if standDown {
            // Deliberately loud: the preference is still on, so the menu still
            // says the microphone is held open, and the user is about to start
            // paying the stall it exists to avoid.
            Log.log("recorder: the audio device changed \(Self.maxRebuildsPerWindow + 1) times in "
                    + "\(Int(Self.rebuildWindow))s — releasing the held-open microphone instead of "
                    + "rebuilding it again. Dictation will wake it on demand; it is held open again "
                    + "the next time the output device changes.")
            engineQueue.async { [weak self] in self?.closeMic() }
            return
        }

        Log.log("recorder: audio configuration changed — rebuilding the held-open microphone")
        engineQueue.async { [weak self] in
            guard let self else { return }
            self.closeMic()
            self.openMicAfterSettling()
        }
    }

    /// Hand a failed device start back to the caller on the main thread, unless a
    /// newer recording has already superseded this one.
    private func reportStartFailure(_ reason: String, generation: Int) {
        let handler = onStartFailed
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentGeneration == generation, self.isRecording else { return }
            self.isRecording = false
            handler?(reason)
        }
    }

    /// One tap buffer. Runs on the audio thread; the first-audio callback is
    /// invoked outside the lock and must get off this thread promptly.
    private func handleTap(_ buffer: AVAudioPCMBuffer, tap: Int) {
        lock.lock()
        // Dropped here: buffers from a tap we have since torn down, and — while
        // the microphone is held open between dictations — every buffer that
        // belongs to no recording at all. Neither reaches the converter.
        guard tap == tapNumber, capturing else { lock.unlock(); return }
        let isFirstAudio = !sawFirstAudio && buffer.frameLength > 0
        if isFirstAudio { sawFirstAudio = true }
        let trace = self.trace
        let handler = isFirstAudio ? firstAudioHandler : nil
        rebuildConverterIfNeededLocked(for: buffer.format)
        convertAndStoreLocked(buffer)
        lock.unlock()

        if isFirstAudio {
            trace?.mark("audio")
            handler?()
        }
    }

    /// Stops recording and returns the finished clip: a 16 kHz mono WAV URL (the
    /// caller owns the file) plus the raw PCM, so callers needing the samples do
    /// not have to race a subsequent `start()` for them.
    func stop() throws -> (url: URL, pcm: Data) {
        guard isRecording else { throw RecorderError.notRecording }
        isRecording = false

        lock.lock()
        // Retire this recording *before* draining. The graph is torn down
        // asynchronously — possibly behind a start still blocked in the driver —
        // so tap buffers can still be in flight; the bump makes `handleTap` drop
        // them rather than append audio past the flush.
        generation += 1
        capturing = false
        convertAndStoreLocked(nil)     // flush the converter's resampling tail
        converter = nil
        trace = nil
        let keepOpen = alwaysOn
        if !keepOpen { tapFormat = nil }
        let samples = captured
        let meteringStart = meteringStartByte
        lock.unlock()

        // Queued rather than immediate, so it lands after this recording's own
        // start and before the next one's. Worst case the device stays up for the
        // remainder of a slow wake-up, which costs nothing but a moment of the
        // microphone-in-use indicator.
        //
        // With the microphone held open there is nothing to tear down — the tap
        // stays installed and `capturing`, cleared above, is what stops its audio
        // being kept. Opening rather than skipping covers the preference having
        // been turned on *during* this dictation.
        engineQueue.async { [weak self] in
            guard let self else { return }
            if keepOpen { self.openMicNow() } else { self.closeMic() }
        }

        lastDurationSeconds = Double(samples.count / 2) / Double(Self.asrSampleRate)
        (lastPeak, lastRMS) = Self.levels(pcm16: samples, from: meteringStart)
        Log.log(String(format: "recorder: stopped — %.2fs, peak %.4f, rms %.4f (metered from %.2fs)",
                       lastDurationSeconds, lastPeak, lastRMS,
                       Double(meteringStart / 2) / Double(Self.asrSampleRate)))

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vo-rec-\(UUID().uuidString).wav")
        try WAVFile(sampleRate: Self.asrSampleRate, samples: samples).data.write(to: wavURL)
        return (wavURL, samples)
    }

    /// RMS of the opening `bins × binMS` of a clip, one value per bin (0…1).
    ///
    /// This is the empirical answer to "did I lose my first words": if the first
    /// two or three bins are ~0 and speech only appears later, capture was still
    /// warming up when the user started talking. Logged once per dictation.
    static func leadingLevelProfile(pcm16: Data, binMS: Int = 50, bins: Int = 10) -> [Float] {
        let samplesPerBin = Self.asrSampleRate * binMS / 1000
        let bytesPerBin = samplesPerBin * 2
        var profile: [Float] = []
        var offset = 0
        while profile.count < bins, offset + bytesPerBin <= pcm16.count {
            let bin = Data(pcm16[pcm16.startIndex + offset ..< pcm16.startIndex + offset + bytesPerBin])
            profile.append(bin.withUnsafeBytes { raw -> Float in
                let samples = raw.bindMemory(to: Int16.self)
                guard !samples.isEmpty else { return 0 }
                var sum = 0.0
                for sample in samples { sum += Double(sample) * Double(sample) }
                return Float((sum / Double(samples.count)).squareRoot() / 32768)
            })
            offset += bytesPerBin
        }
        return profile
    }

    /// One tap buffer being handed to the converter's input block. The block is
    /// `@Sendable` but `convert()` calls it synchronously on the current thread,
    /// so single-threaded mutation of `fed` is safe.
    private final class ConverterInput: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer?
        var fed = false
        init(_ buffer: AVAudioPCMBuffer?) { self.buffer = buffer }
    }

    /// Rebuild the converter when the tap starts delivering a format it was not
    /// built for. A held-open tap outlives any one input device, so a headset
    /// swapped mid-capture would otherwise have its samples reinterpreted at the
    /// old rate — audible as a chipmunked or slurred transcript rather than as an
    /// error. **The caller must already hold `lock`.**
    private func rebuildConverterIfNeededLocked(for format: AVAudioFormat) {
        guard let current = converter,
              format.sampleRate != current.inputFormat.sampleRate
                || format.channelCount != current.inputFormat.channelCount,
              let rebuilt = AVAudioConverter(from: format, to: current.outputFormat) else { return }
        Log.log(String(format: "recorder: input format changed mid-capture %.0fHz/%dch → %.0fHz/%dch — converter rebuilt",
                       current.inputFormat.sampleRate, current.inputFormat.channelCount,
                       format.sampleRate, format.channelCount))
        converter = rebuilt
        inputSampleRate = format.sampleRate
    }

    /// Convert one captured buffer (or, with nil, drain the converter at end of
    /// stream) to s16le@16k and append it to `captured`.
    ///
    /// **The caller must already hold `lock`.** `AVAudioConverter` is not
    /// thread-safe and this runs from both the tap thread and `stop()`'s
    /// end-of-stream flush, so those two must not overlap.
    private func convertAndStoreLocked(_ buffer: AVAudioPCMBuffer?) {
        guard let converter else { return }
        let input = ConverterInput(buffer)
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            guard let buffer = input.buffer else { status.pointee = .endOfStream; return nil }
            if input.fed { status.pointee = .noDataNow; return nil }
            input.fed = true
            status.pointee = .haveData
            return buffer
        }
        let inFrames = Double(buffer?.frameLength ?? 4096)
        let capacity = AVAudioFrameCount(inFrames * Double(Self.asrSampleRate) / inputSampleRate) + 64
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                             frameCapacity: capacity) else { return }
            var convError: NSError?
            let status = converter.convert(to: out, error: &convError, withInputFrom: inputBlock)
            if let convError { Log.log("recorder: conversion failed \(convError)"); return }
            if out.frameLength > 0, let ch = out.int16ChannelData {
                captured.append(Data(bytes: ch[0], count: Int(out.frameLength) * 2))
            }
            // .haveData = output buffer filled, more may remain — keep draining.
            if status != .haveData { return }
        }
    }

    /// Peak amplitude and RMS energy (0…1) of the converted PCM from `offset`
    /// onwards. Measured on the s16 data we actually send rather than on the raw
    /// float tap buffers, so the numbers describe the audio the server sees.
    ///
    /// A clip no longer than the lead-in reads as silent, which is the right
    /// answer: all it can contain is the start cue.
    static func levels(pcm16: Data, from offset: Int = 0) -> (peak: Float, rms: Float) {
        let start = min(offset, pcm16.count) & ~1        // stay on a sample boundary
        guard pcm16.count - start >= 2 else { return (0, 0) }
        let body = Data(pcm16[pcm16.startIndex + start ..< pcm16.endIndex])
        return body.withUnsafeBytes { raw -> (Float, Float) in
            let samples = raw.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return (0, 0) }
            var peak: Float = 0
            var sumSquares = 0.0
            for sample in samples {
                let value = Float(sample) / 32768
                peak = max(peak, abs(value))
                sumSquares += Double(value) * Double(value)
            }
            return (peak, Float((sumSquares / Double(samples.count)).squareRoot()))
        }
    }

    /// Transcode any input to 16 kHz mono 16-bit little-endian WAV via afconvert.
    /// (Used by the `--asr-test` debug path for `say`-generated AIFFs; live
    /// capture converts in-process instead.)
    static func convertToASRWav(from src: URL, to dst: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                       src.path, dst.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              FileManager.default.fileExists(atPath: dst.path) else {
            throw RecorderError.conversionFailed
        }
    }
}
