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
    /// The hardware format the tap is installed with. Held here rather than
    /// captured into the queue block: `AVAudioFormat` is not `Sendable`, and this
    /// class already takes responsibility for its own state via `lock`.
    private var tapFormat: AVAudioFormat?

    /// Duration (seconds) of the most recently stopped clip.
    private(set) var lastDurationSeconds: Double = 0
    /// Peak amplitude and RMS energy of the most recently stopped clip (0…1).
    /// Used to skip transcription when the user said nothing (silence gate).
    private(set) var lastPeak: Float = 0
    private(set) var lastRMS: Float = 0

    enum RecorderError: Error { case alreadyRecording, notRecording, conversionFailed }

    private(set) var isRecording = false

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
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
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
        self.trace = trace
        lock.unlock()
        isRecording = true

        engineQueue.async { [weak self] in
            guard let self else { return }
            // Stopped while we were queued (or while a previous start was still
            // blocked in the driver). Don't wake a device nobody is listening to.
            self.lock.lock()
            let stale = recording != self.generation
            let tapFormat = self.tapFormat
            self.lock.unlock()
            guard !stale, let tapFormat else { return }

            let input = self.engine.inputNode
            input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
                self?.handleTap(buffer, generation: recording)
            }
            self.engine.prepare()
            trace?.mark("engine-prepare")
            do {
                try self.engine.start()
                trace?.mark("engine-start")
            } catch {
                input.removeTap(onBus: 0)
                let reason = "\(error)"
                Log.log("recorder: engine start failed — \(reason)")
                trace?.note("engine start failed: \(reason)")
                self.reportStartFailure(reason, generation: recording)
            }
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
    private func handleTap(_ buffer: AVAudioPCMBuffer, generation: Int) {
        lock.lock()
        guard generation == self.generation else { lock.unlock(); return }
        let isFirstAudio = !sawFirstAudio && buffer.frameLength > 0
        if isFirstAudio { sawFirstAudio = true }
        let trace = self.trace
        let handler = isFirstAudio ? firstAudioHandler : nil
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
        convertAndStoreLocked(nil)     // flush the converter's resampling tail
        converter = nil
        tapFormat = nil
        trace = nil
        let samples = captured
        let meteringStart = meteringStartByte
        lock.unlock()

        // Queued rather than immediate, so it lands after this recording's own
        // start and before the next one's. Worst case the device stays up for the
        // remainder of a slow wake-up, which costs nothing but a moment of the
        // microphone-in-use indicator.
        engineQueue.async { [weak self] in
            guard let self else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
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
