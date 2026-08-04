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
final class AudioRecorder {
    /// The ASR wire format: 16 kHz mono 16-bit PCM (2 bytes per sample).
    static let asrSampleRate = 16_000

    private let engine = AVAudioEngine()

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
        let generation = self.generation
        converter = conv
        inputSampleRate = format.sampleRate
        captured = Data()
        sawFirstAudio = false
        meteringStartByte = 0
        self.trace = trace
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handleTap(buffer, generation: generation)
        }
        engine.prepare()
        trace?.mark("engine-prepare")
        try engine.start()
        trace?.mark("engine-start")
        isRecording = true
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
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false

        lock.lock()
        convertAndStoreLocked(nil)     // flush the converter's resampling tail
        converter = nil
        let samples = captured
        let meteringStart = meteringStartByte
        lock.unlock()

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
