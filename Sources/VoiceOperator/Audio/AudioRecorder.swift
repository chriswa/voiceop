import AVFoundation

/// Captures the default input device to a 16 kHz mono s16le WAV — the format
/// Wispr's `/llm/asr` expects. Records at the hardware format via AVAudioEngine,
/// then transcodes with the built-in `afconvert` on stop (robust, and fine for
/// the HTTP path which sends the whole clip at once; the streaming WS path will
/// convert incrementally later).
///
/// Requires the Microphone entitlement + user grant at runtime. Emits capture
/// diagnostics (input format, peak level, frame count) to `Log` so silent-audio
/// problems ("you" hallucinations from Whisper) are easy to spot.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var rawFile: AVAudioFile?
    private var rawURL: URL?
    private var peak: Float = 0
    private var sumSquares: Double = 0
    private var sampleCount: Int = 0
    private var framesCaptured: AVAudioFramePosition = 0
    /// Duration (seconds) of the most recently stopped clip.
    private(set) var lastDurationSeconds: Double = 0
    /// Peak amplitude and RMS energy of the most recently stopped clip (0…1).
    /// Used to skip transcription when the user said nothing (silence gate).
    private(set) var lastPeak: Float = 0
    private(set) var lastRMS: Float = 0

    enum RecorderError: Error { case alreadyRecording, notRecording, conversionFailed }

    private(set) var isRecording = false

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

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vo-rec-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        rawFile = file
        rawURL = url
        peak = 0
        sumSquares = 0
        sampleCount = 0
        framesCaptured = 0

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.meter(buffer)
            do { try self?.rawFile?.write(from: buffer) }
            catch { Log.log("recorder: write failed \(error)") }
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops recording and returns a 16 kHz mono WAV URL. Caller owns the file.
    func stop() throws -> URL {
        guard isRecording, let rawURL else { throw RecorderError.notRecording }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        rawFile = nil
        isRecording = false

        let sr = engine.inputNode.inputFormat(forBus: 0).sampleRate
        let seconds = sr > 0 ? Double(framesCaptured) / sr : 0
        lastDurationSeconds = seconds
        lastPeak = peak
        lastRMS = sampleCount > 0 ? Float((sumSquares / Double(sampleCount)).squareRoot()) : 0
        Log.log(String(format: "recorder: stopped — %.2fs, peak %.4f, rms %.4f",
                       seconds, lastPeak, lastRMS))

        let wavURL = rawURL.deletingPathExtension().appendingPathExtension("wav")
        try Self.convertToASRWav(from: rawURL, to: wavURL)
        try? FileManager.default.removeItem(at: rawURL)
        return wavURL
    }

    /// Track peak amplitude and RMS energy across captured buffers (float input).
    private func meter(_ buffer: AVAudioPCMBuffer) {
        framesCaptured += AVAudioFramePosition(buffer.frameLength)
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
