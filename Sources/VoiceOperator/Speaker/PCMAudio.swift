import AVFoundation
import Foundation

/// Turns a stream of `pcm_f32le` byte chunks (as delivered over Cartesia's SSE
/// path) into `AVAudioPCMBuffer`s on whole-sample boundaries. A single 4-byte
/// float can straddle two network chunks, so any trailing partial-sample bytes
/// are carried over to the next call.
struct PCMReframer {
    /// Bytes per sample for float32 mono (one channel × 4 bytes).
    private static let bytesPerSample = 4
    private var pending = Data()

    /// Append `chunk` and return a buffer for every whole sample now available.
    /// Returns nil (no buffer) when the chunk only extends a partial sample.
    mutating func buffer(from chunk: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        pending.append(chunk)
        let whole = pending.count - (pending.count % Self.bytesPerSample)
        guard whole > 0 else { return nil }

        let usable = pending.prefix(whole)
        pending.removeFirst(whole)

        let frames = whole / Self.bytesPerSample
        guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(frames)),
              let dst = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        // f32le matches the little-endian in-memory Float layout on Apple targets,
        // so a raw copy is correct (no byte-swap).
        usable.withUnsafeBytes { raw in
            memcpy(dst[0], raw.baseAddress!, whole)
        }
        return buf
    }
}

/// Conversions between the raw `pcm_f32le` we receive live and the s16le WAV the
/// audio cache stores (matching the app's canonical `WAVFile` format, so cached
/// clips replay unchanged through `AVAudioPlayer`).
enum PCMAudio {
    /// Convert accumulated `pcm_f32le` bytes to s16le sample bytes, clamping to
    /// [-1, 1] first (a boosted `volume` can push samples past full scale).
    static func s16leSamples(fromFloat32 pcm: Data) -> Data {
        let n = pcm.count / 4
        var out = Data(capacity: n * 2)
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let floats = raw.bindMemory(to: Float.self)
            for i in 0..<n {
                let v = max(-1, min(1, floats[i]))
                let bits = UInt16(bitPattern: Int16(v * 32767))
                out.append(UInt8(bits & 0xFF))       // little-endian s16
                out.append(UInt8(bits >> 8))
            }
        }
        return out
    }

    /// Build a canonical s16le mono WAV blob from accumulated `pcm_f32le` bytes.
    static func wav(fromFloat32 pcm: Data, sampleRate: Int) -> Data {
        WAVFile(sampleRate: sampleRate, samples: s16leSamples(fromFloat32: pcm)).data
    }
}
