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
