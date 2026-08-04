import XCTest
@testable import VoiceOperator

final class OpusEncoderTests: XCTestCase {
    // 1 s of 16 kHz mono s16le = 16000 samples = 50 frames of 320 samples (20 ms).
    func testOneSecondProducesFiftyFrames() throws {
        let pcm = Data(count: 16_000 * 2)   // 1 s of silence
        let enc = try OpusEncoder()
        let out = try enc.encode(pcm: pcm)
        XCTAssertEqual(out.packets.count, 50)
        XCTAssertEqual(out.volumes.count, 50)
        XCTAssertEqual(out.packetDurationSeconds, 0.02, accuracy: 1e-9)
        XCTAssertTrue(out.packets.allSatisfy { !$0.isEmpty })   // opus always emits >=1 byte
    }

    // A partial final frame is padded to a full 20 ms frame.
    func testPartialFinalFrameIsPadded() throws {
        let pcm = Data(count: (320 + 100) * 2)   // 1.3 frames worth
        let enc = try OpusEncoder()
        let out = try enc.encode(pcm: pcm)
        XCTAssertEqual(out.packets.count, 2)
    }

    // The live upload pump must never pad mid-stream: a trailing partial frame is
    // left unconsumed so the pump can re-offer it once the rest arrives.
    func testWholeFramesLeavesPartialFrameUnconsumed() throws {
        let pcm = Data(count: (320 * 3 + 100) * 2)   // 3.3 frames worth
        let enc = try OpusEncoder()
        let (out, consumed) = try enc.encodeWholeFrames(pcm: pcm)
        XCTAssertEqual(out.packets.count, 3)
        XCTAssertEqual(consumed, 320 * 3 * 2)
    }

    // Feeding the same audio in ragged slices must yield the same frame count as
    // one shot — that is what keeps the stream aligned while the user is talking.
    func testWholeFramesAcrossRaggedSlicesMatchesSingleShot() throws {
        let total = 320 * 10 * 2
        let pcm = Data(count: total)
        let enc = try OpusEncoder()
        var produced = 0
        var offset = 0
        for slice in [500, 1_000, 2_000, 4_000, total] {
            let end = min(offset + slice, total)
            guard end > offset else { break }
            let (out, consumed) = try enc.encodeWholeFrames(pcm: pcm[offset..<end])
            produced += out.packets.count
            offset += consumed
        }
        XCTAssertEqual(produced, 10)
        XCTAssertEqual(offset, total)
    }

    // No whole frame available yet → nothing encoded, nothing consumed.
    func testWholeFramesWithSubFrameInputIsANoOp() throws {
        let (out, consumed) = try OpusEncoder().encodeWholeFrames(pcm: Data(count: 100))
        XCTAssertTrue(out.packets.isEmpty)
        XCTAssertEqual(consumed, 0)
    }

    // Non-silent audio reports non-zero volume.
    func testVolumeReflectsAmplitude() throws {
        var pcm = Data()
        for i in 0..<320 {
            let v = Int16(truncatingIfNeeded: (i % 2 == 0) ? 8000 : -8000)
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        let out = try OpusEncoder().encode(pcm: pcm)
        XCTAssertEqual(out.volumes.count, 1)
        XCTAssertGreaterThan(out.volumes[0], 0.1)
    }
}
