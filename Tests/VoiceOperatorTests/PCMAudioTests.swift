import AVFoundation
import XCTest
@testable import VoiceOperator

final class PCMAudioTests: XCTestCase {
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!

    /// Serialize floats to `pcm_f32le` bytes (host is little-endian on Apple).
    private func f32le(_ floats: [Float]) -> Data {
        var d = Data(capacity: floats.count * 4)
        for f in floats {
            withUnsafeBytes(of: f.bitPattern.littleEndian) { d.append(contentsOf: $0) }
        }
        return d
    }

    /// The reframer must reassemble floats regardless of how the byte stream is
    /// chopped — including chunk boundaries that fall mid-sample.
    func testReframerCarriesPartialSamplesAcrossChunks() {
        let input: [Float] = (0..<50).map { Float($0) / 50.0 - 0.5 }
        let bytes = f32le(input)

        var reframer = PCMReframer()
        var out: [Float] = []
        // Chunk sizes deliberately not multiples of 4 (a float straddles
        // boundaries); cycle through them until the whole stream is consumed.
        let sizes = [3, 1, 7, 5, 2, 9]
        var offset = 0, i = 0
        while offset < bytes.count {
            let end = min(offset + sizes[i % sizes.count], bytes.count)
            let chunk = bytes.subdata(in: offset..<end)
            offset = end; i += 1
            if let buf = reframer.buffer(from: chunk, format: format) {
                let ptr = buf.floatChannelData![0]
                out.append(contentsOf: (0..<Int(buf.frameLength)).map { ptr[$0] })
            }
        }

        XCTAssertEqual(out.count, input.count)
        for (a, b) in zip(out, input) { XCTAssertEqual(a, b, accuracy: 1e-6) }
    }

    /// A chunk shorter than one whole sample yields no buffer yet.
    func testReframerHoldsBackSubSampleChunk() {
        var reframer = PCMReframer()
        XCTAssertNil(reframer.buffer(from: Data([0x01, 0x02, 0x03]), format: format))
    }

    /// float32 → s16le conversion clamps out-of-range samples to full scale.
    func testS16leClampsAndConverts() {
        let samples = PCMAudio.s16leSamples(fromFloat32: f32le([0, 1.0, -1.0, 2.0, -2.0]))
        func s16(_ i: Int) -> Int16 {
            Int16(bitPattern: UInt16(samples[i * 2]) | UInt16(samples[i * 2 + 1]) << 8)
        }
        XCTAssertEqual(samples.count, 5 * 2)
        XCTAssertEqual(s16(0), 0)
        XCTAssertEqual(s16(1), 32767)     // 1.0
        XCTAssertEqual(s16(2), -32767)    // -1.0
        XCTAssertEqual(s16(3), 32767)     // clamped from 2.0
        XCTAssertEqual(s16(4), -32767)    // clamped from -2.0
    }

    /// The assembled WAV parses back as canonical s16le mono at the given rate.
    func testWavRoundTripsThroughWAVFile() throws {
        let floats: [Float] = (0..<200).map { sinf(Float($0) * 0.1) * 0.8 }
        let wav = PCMAudio.wav(fromFloat32: f32le(floats), sampleRate: 44100)
        let parsed = try WAVFile.parse(wav)
        XCTAssertEqual(parsed.sampleRate, 44100)
        XCTAssertEqual(parsed.samples.count, floats.count * 2)
    }
}
