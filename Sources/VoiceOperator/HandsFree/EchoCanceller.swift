import AVFoundation
import CSpeexDSP

/// What Voice Operator has played on the Mac, as 16 kHz mono, stamped with the
/// host time it reached the speaker: the reference the echo canceller takes out
/// of the microphone (`EchoCanceller`). Collected only while it is wanted (the
/// echo experiment on, or `--echo-capture` recording): each speech player taps
/// its mixer as it starts (`StreamingSpeechPlayer.start`), and nothing else
/// changes about playback. Kept in memory, the last `keepSeconds` only.
final class EchoReference: @unchecked Sendable {
    static let shared = EchoReference()
    static let sampleRate = 16_000.0
    static let keepSeconds = 20.0

    private let lock = NSLock()
    private var segments: [(start: UInt64, samples: [Float])] = []
    private var _capturing = false

    /// `--echo-capture` is recording: collect whatever the experiment says.
    var capturing: Bool {
        get { lock.withLock { _capturing } }
        set { lock.withLock { _capturing = newValue } }
    }

    /// Whether a player starting now should tap its output for this.
    var wanted: Bool { EchoExperiment.isOn || capturing }

    /// Tap `engine`'s mixer for the reference. `latency` is how far the
    /// speaker is behind the mixer, read as each buffer comes.
    func tap(_ engine: AVAudioEngine, latency: @escaping @Sendable () -> Double) {
        let mixer = engine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)
        guard format.sampleRate > 0,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: mono) else { return }
        let box = ConverterBox(converter)
        mixer.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
            guard let self, when.isHostTimeValid, let pcm = box.convert(buffer, to: mono), !pcm.isEmpty else { return }
            let start = when.hostTime &+ AVAudioTime.hostTime(forSeconds: max(0, latency()))
            self.append(pcm, at: start)
        }
    }

    func append(_ pcm: [Float], at start: UInt64) {
        lock.withLock {
            segments.append((start, pcm))
            let oldest = start &- AVAudioTime.hostTime(forSeconds: Self.keepSeconds)
            segments.removeAll { $0.start < oldest }
        }
    }

    /// `count` samples of what played from `start` (host time) on; silence where nothing did.
    func samples(from start: UInt64, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        let spans = lock.withLock { segments }
        let startSeconds = AVAudioTime.seconds(forHostTime: start)
        for span in spans {
            // Where this segment begins, in samples relative to `start` (negative: before it).
            let offset = Int(((AVAudioTime.seconds(forHostTime: span.start) - startSeconds) * Self.sampleRate).rounded())
            let from = max(0, offset)
            let to = min(count, offset + span.samples.count)
            guard from < to else { continue }
            for i in from..<to { out[i] = span.samples[i - offset] }
        }
        return out
    }

    func clear() { lock.withLock { segments = [] } }

    /// A converter used from the tap's thread only, one buffer at a time.
    private final class ConverterBox: @unchecked Sendable {
        let converter: AVAudioConverter
        init(_ converter: AVAudioConverter) { self.converter = converter }

        func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> [Float]? {
            let input = Input(buffer)
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
            var samples: [Float] = []
            while true {
                guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
                var error: NSError?
                let status = converter.convert(to: out, error: &error) { _, status in
                    if input.fed { status.pointee = .noDataNow; return nil }
                    input.fed = true
                    status.pointee = .haveData
                    return input.buffer
                }
                if error != nil { return nil }
                if out.frameLength > 0, let channel = out.floatChannelData {
                    samples += UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength))
                }
                if status != .haveData { return samples }
            }
        }
    }

    private final class Input: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var fed = false
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }
}

/// SpeexDSP's echo canceller, with its residual echo suppressor, on 16 kHz
/// mono in 20 ms frames: the microphone with what Voice Operator played taken
/// out. For hands-free's echo experiment on the Mac (`EchoExperiment`), and
/// for `--echo-capture`'s offline copy of the same.
final class EchoCanceller {
    static let frame = 320
    /// The echo path it can model: 300 ms, room for the timing to be out.
    static let tailSamples = 4800
    /// The reference is handed over this much early, so an echo that arrives a
    /// little sooner than the timestamps say is still inside the filter.
    static let leadSeconds = 0.06

    private let echo: OpaquePointer
    private let preprocess: OpaquePointer
    private var micCarry: [Int16] = []
    private var refCarry: [Int16] = []

    init() {
        echo = speex_echo_state_init(Int32(Self.frame), Int32(Self.tailSamples))
        preprocess = speex_preprocess_state_init(Int32(Self.frame), 16_000)
        var rate: Int32 = 16_000
        speex_echo_ctl(echo, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)
        // Echo suppression only: denoising and gain control would change what the speech detector hears.
        var off: Int32 = 0
        speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_DENOISE, &off)
        speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_AGC, &off)
        speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_ECHO_STATE, UnsafeMutableRawPointer(echo))
    }

    deinit {
        speex_preprocess_state_destroy(preprocess)
        speex_echo_state_destroy(echo)
    }

    /// The microphone with the echo of `reference` taken out. The two are the
    /// same length and line up sample for sample (the reference already early
    /// by `leadSeconds`, if it is to be). Whole frames go through; the rest
    /// waits for the next call, so the output is up to a frame behind.
    func process(mic: [Int16], reference: [Int16]) -> [Int16] {
        micCarry += mic
        refCarry += reference
        var out: [Int16] = []
        out.reserveCapacity(micCarry.count)
        var frameOut = [Int16](repeating: 0, count: Self.frame)
        var at = 0
        while micCarry.count - at >= Self.frame, refCarry.count - at >= Self.frame {
            micCarry[at..<at + Self.frame].withUnsafeBufferPointer { rec in
                refCarry[at..<at + Self.frame].withUnsafeBufferPointer { play in
                    frameOut.withUnsafeMutableBufferPointer { o in
                        speex_echo_cancellation(echo, rec.baseAddress, play.baseAddress, o.baseAddress)
                        _ = speex_preprocess_run(preprocess, o.baseAddress)
                    }
                }
            }
            out += frameOut
            at += Self.frame
        }
        micCarry.removeFirst(at)
        refCarry.removeFirst(min(at, refCarry.count))
        return out
    }

    /// Start over: a new room, a new device, a gap in the microphone.
    func reset() {
        speex_echo_state_reset(echo)
        micCarry = []
        refCarry = []
    }

    static func int16(_ samples: [Float]) -> [Int16] {
        samples.map { Int16(max(-32768, min(32767, ($0 * 32767).rounded()))) }
    }
}

/// The Mac's microphone through the echo canceller: each chunk is placed on a
/// steady clock (the host time of its first sample, carried forward sample by
/// sample, so a jittery tap does not jitter the alignment), and the reference
/// for the same stretch is taken from `EchoReference`. Started afresh after a
/// gap, or when it has been off.
final class MacEchoPath {
    private let canceller = EchoCanceller()
    private var nextTime: UInt64?
    private var nextSeconds = 0.0
    /// A chunk this far from where the clock says it belongs is a gap: start over.
    static let gapSeconds = 0.08

    func process(_ pcm: [Int16], hostTime: UInt64, reference: EchoReference = .shared) -> [Int16] {
        let seconds = AVAudioTime.seconds(forHostTime: hostTime)
        if nextTime == nil || abs(seconds - nextSeconds) > Self.gapSeconds {
            canceller.reset()
            nextSeconds = seconds
        }
        let start = AVAudioTime.hostTime(forSeconds: max(0, nextSeconds - EchoCanceller.leadSeconds))
        let ref = EchoCanceller.int16(reference.samples(from: start, count: pcm.count))
        nextSeconds += Double(pcm.count) / EchoReference.sampleRate
        nextTime = AVAudioTime.hostTime(forSeconds: nextSeconds)
        return canceller.process(mic: pcm, reference: ref)
    }

    func reset() {
        canceller.reset()
        nextTime = nil
    }
}
