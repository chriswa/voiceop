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

    private let enc: OpaquePointer

    /// Per-dictation encode result: one opus packet + one RMS volume per frame.
    struct EncodedAudio {
        var packets: [Data]
        var volumes: [Float]
        /// Wispr's `packet_duration`, in seconds (20 ms).
        var packetDurationSeconds: Double { Double(OpusEncoder.frameSamples) / Double(OpusEncoder.sampleRate) }
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
    func encode(pcm: Data) throws -> EncodedAudio {
        let frameBytes = Self.frameSamples * 2
        var packets: [Data] = []
        var volumes: [Float] = []
        var out = [UInt8](repeating: 0, count: 4000)
        var offset = 0
        while offset < pcm.count {
            var frame = pcm.subdata(in: offset..<min(offset + frameBytes, pcm.count))
            if frame.count < frameBytes { frame.append(Data(count: frameBytes - frame.count)) }
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
            offset += frameBytes
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
