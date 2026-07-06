import AVFoundation

/// Captures the default input device to 16 kHz mono s16le — the format Wispr's
/// `/llm/asr` expects. Audio is converted *live* in the tap (AVAudioConverter
/// from the hardware format) and accumulated in memory, so callers can read
/// partial audio mid-recording — that's what lets the arbiter transcribe
/// 28-second chunks while the user is still talking, the way Wispr Flow does.
/// `stop()` writes the accumulated samples out as a WAV for history/retry.
///
/// Requires the Microphone entitlement + user grant at runtime. Emits capture
/// diagnostics (input format, peak level, frame count) to `Log` so silent-audio
/// problems ("you" hallucinations from Whisper) are easy to spot.
final class AudioRecorder {
    /// The ASR wire format: 16 kHz mono 16-bit PCM (2 bytes per sample).
    static let asrSampleRate = 16_000

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var inputSampleRate: Double = 0

    /// Converted s16le@16k bytes captured so far. Appended on the audio tap
    /// thread, read from the main thread — guarded by `lock`.
    private var captured = Data()
    private let lock = NSLock()

    private var peak: Float = 0
    private var sumSquares: Double = 0
    private var sampleCount: Int = 0
    /// Duration (seconds) of the most recently stopped clip.
    private(set) var lastDurationSeconds: Double = 0
    /// Peak amplitude and RMS energy of the most recently stopped clip (0…1).
    /// Used to skip transcription when the user said nothing (silence gate).
    private(set) var lastPeak: Float = 0
    private(set) var lastRMS: Float = 0

    enum RecorderError: Error { case alreadyRecording, notRecording, conversionFailed }

    private(set) var isRecording = false

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

    func start() throws {
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
        converter = conv
        inputSampleRate = format.sampleRate
        lock.lock(); captured = Data(); lock.unlock()
        peak = 0
        sumSquares = 0
        sampleCount = 0

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.meter(buffer)
            self?.convertAndStore(buffer)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops recording and returns a 16 kHz mono WAV URL. Caller owns the file.
    func stop() throws -> URL {
        guard isRecording else { throw RecorderError.notRecording }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        convertAndStore(nil)   // flush the converter's resampling tail
        converter = nil
        isRecording = false

        lock.lock()
        let samples = captured
        lock.unlock()
        lastDurationSeconds = Double(samples.count / 2) / Double(Self.asrSampleRate)
        lastPeak = peak
        lastRMS = sampleCount > 0 ? Float((sumSquares / Double(sampleCount)).squareRoot()) : 0
        Log.log(String(format: "recorder: stopped — %.2fs, peak %.4f, rms %.4f",
                       lastDurationSeconds, lastPeak, lastRMS))

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vo-rec-\(UUID().uuidString).wav")
        try WAVFile(sampleRate: Self.asrSampleRate, samples: samples).data.write(to: wavURL)
        return wavURL
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
    /// stream) to s16le@16k and append it to `captured`. Runs on the tap thread.
    private func convertAndStore(_ buffer: AVAudioPCMBuffer?) {
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
                let bytes = Data(bytes: ch[0], count: Int(out.frameLength) * 2)
                lock.lock(); captured.append(bytes); lock.unlock()
            }
            // .haveData = output buffer filled, more may remain — keep draining.
            if status != .haveData { return }
        }
    }

    /// Track peak amplitude and RMS energy across captured buffers (float input).
    private func meter(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        for c in 0..<Int(buffer.format.channelCount) {
            let samples = channels[c]
            for i in 0..<n {
                let s = samples[i]
                peak = max(peak, abs(s))
                sumSquares += Double(s) * Double(s)
                sampleCount += 1
            }
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
