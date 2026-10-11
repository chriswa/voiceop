import XCTest
@testable import VoiceOperator

final class ParakeetProviderTests: XCTestCase {
    func testPCM16BecomesUnitRangeFloats() {
        var pcm = Data()
        for value: Int16 in [0, 16_384, -32_768, 32_767] {
            withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
        }
        let samples = ParakeetEngine.floatSamples(pcm)
        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(samples[0], 0)
        XCTAssertEqual(samples[1], 0.5, accuracy: 1e-6)
        XCTAssertEqual(samples[2], -1)
        XCTAssertEqual(samples[3], 32_767 / 32_768, accuracy: 1e-6)
    }

    func testAnOddTrailingByteIsIgnored() {
        XCTAssertEqual(ParakeetEngine.floatSamples(Data([0, 0, 7])).count, 1)
    }
}
