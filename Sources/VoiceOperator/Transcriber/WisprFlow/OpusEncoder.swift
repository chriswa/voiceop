import COpus
import Foundation

/// Encodes 16 kHz mono s16le PCM into raw Opus packets at 20 ms / 320-sample
/// frames, matching Wispr's opus worker (`opusEncoder.worker.js`,
/// `OPUS_APPLICATION_VOIP`). These packets feed the flow-request `audio_packets`
/// (ascii85 on the JSON `/llm` path; raw bytes on the msgpack/gRPC paths).
/// See `proto/flow_api_v1.proto` and DESIGN.md Milestone C.
final class OpusEncoder {
    /// The ASR wire format Wispr uses.
    static let sampleRate: Int32 = 16_000
    /// 20 ms @ 16 kHz — Wispr's fixed opus frame.
    static let frameSamples = 320
    /// Bytes of s16le PCM in one frame.
    static let frameBytes = frameSamples * 2
    /// Wispr's `packet_duration`, in seconds.
    static let frameSeconds = Double(frameSamples) / Double(sampleRate)

    private let enc: OpaquePointer

    /// Per-dictation encode result: one opus packet + one RMS volume per frame.
    struct EncodedAudio {
        var packets: [Data]
        var volumes: [Float]
        /// Wispr's `packet_duration`, in seconds (20 ms).
        var packetDurationSeconds: Double { OpusEncoder.frameSeconds }
    }

    enum OpusError: Error { case create(Int32), encode(Int32) }

    init() throws {
        var err: Int32 = 0
        guard let e = opus_encoder_create(Self.sampleRate, 1, OPUS_APPLICATION_VOIP, &err),
              err == OPUS_OK else {
            throw OpusError.create(err)
        }
        enc = e
    }

    deinit { opus_encoder_destroy(enc) }

    /// Encode s16le PCM into 20 ms opus frames. The final partial frame is padded
    /// with silence (Wispr does the same — fixed-length frames, no VAD).
    ///
    /// Use this for a *complete* clip only. Mid-recording, padding a partial frame
    /// would splice silence into the middle of the stream and shift every later
    /// frame — use `encodeWholeFrames` and keep the remainder instead.
    func encode(pcm: Data) throws -> EncodedAudio {
        try encodeFrames(pcm: pcm, padFinalFrame: true)
    }

    /// Encode only the whole 20 ms frames available in `pcm`, leaving any trailing
    /// partial frame unconsumed.
    ///
    /// This is the live-dictation entry point: the upload pump calls it every tick
    /// with whatever new audio the recorder has captured and advances its read
    /// offset by `consumed`, so the leftover samples are re-offered next tick and
    /// no frame is ever padded until the recording actually ends. The encoder is
    /// stateful across calls (that is what makes opus efficient), so a single
    /// instance must serve one whole dictation.
    func encodeWholeFrames(pcm: Data) throws -> (audio: EncodedAudio, consumed: Int) {
        let whole = (pcm.count / Self.frameBytes) * Self.frameBytes
        guard whole > 0 else { return (EncodedAudio(packets: [], volumes: []), 0) }
        return (try encodeFrames(pcm: pcm.prefix(whole), padFinalFrame: false), whole)
    }

    private func encodeFrames(pcm: Data, padFinalFrame: Bool) throws -> EncodedAudio {
        var packets: [Data] = []
        var volumes: [Float] = []
        var out = [UInt8](repeating: 0, count: 4000)
        var offset = pcm.startIndex
        while offset < pcm.endIndex {
            let end = min(offset + Self.frameBytes, pcm.endIndex)
            var frame = Data(pcm[offset ..< end])
            if frame.count < Self.frameBytes {
                guard padFinalFrame else { break }
                frame.append(Data(count: Self.frameBytes - frame.count))
            }
            let n: Int32 = frame.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                return out.withUnsafeMutableBufferPointer { ob in
                    opus_encode(enc, samples.baseAddress!, Int32(Self.frameSamples),
                                ob.baseAddress!, 4000)
                }
            }
            guard n >= 0 else { throw OpusError.encode(n) }
            packets.append(Data(out[0..<Int(n)]))
            volumes.append(Self.rms(frame))
            offset = end
        }
        return EncodedAudio(packets: packets, volumes: volumes)
    }

    /// RMS amplitude (0…1) of a frame — Wispr sends one per packet in `volumes`.
    private static func rms(_ frame: Data) -> Float {
        frame.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            guard !s.isEmpty else { return 0 }
            var sum = 0.0
            for v in s { sum += Double(v) * Double(v) }
            return Float((sum / Double(s.count)).squareRoot() / 32768.0)
        }
    }
}
