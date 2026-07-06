import XCTest
@testable import VoiceOperator

final class WAVFileTests: XCTestCase {
    /// n seconds of 16 kHz s16le samples, each sample = its index (mod Int16).
    private func sampleData(seconds: Double, rate: Int = 16_000) -> Data {
        let n = Int(seconds * Double(rate))
        var d = Data(capacity: n * 2)
        for i in 0..<n {
            let v = Int16(truncatingIfNeeded: i)
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        return d
    }

    func testRoundTrip() throws {
        let original = WAVFile(sampleRate: 16_000, samples: sampleData(seconds: 1.5))
        let parsed = try WAVFile.parse(original.data)
        XCTAssertEqual(parsed.sampleRate, 16_000)
        XCTAssertEqual(parsed.samples, original.samples)
        XCTAssertEqual(parsed.duration, 1.5, accuracy: 0.001)
    }

    func testParsesAfconvertStyleHeaderWithFLLRPaddingChunk() throws {
        // afconvert inserts a `FLLR` padding chunk between `fmt ` and `data`;
        // rebuild a file in that layout and check the parser walks past it.
        let samples = sampleData(seconds: 0.25)
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let padding = 4044
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(4 + 24 + 8 + padding + 8 + samples.count))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(16_000); u32(32_000); u16(2); u16(16)
        d.append(contentsOf: Array("FLLR".utf8)); u32(UInt32(padding))
        d.append(Data(count: padding))
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(samples.count))
        d.append(samples)

        let parsed = try WAVFile.parse(d)
        XCTAssertEqual(parsed.sampleRate, 16_000)
        XCTAssertEqual(parsed.samples, samples)
    }

    func testSegmentsSplitAtChunkBoundary() {
        // 70 s at 28 s per segment → 28 + 28 + 14.
        let wav = WAVFile(sampleRate: 16_000, samples: sampleData(seconds: 70))
        let parts = wav.segments(maxSeconds: 28)
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0].duration, 28, accuracy: 0.001)
        XCTAssertEqual(parts[1].duration, 28, accuracy: 0.001)
        XCTAssertEqual(parts[2].duration, 14, accuracy: 0.001)
        // Segments must be a lossless, ordered partition of the original.
        XCTAssertEqual(parts.map(\.samples).reduce(Data(), +), wav.samples)
    }

    func testShortClipYieldsSingleSegment() {
        let wav = WAVFile(sampleRate: 16_000, samples: sampleData(seconds: 5))
        let parts = wav.segments(maxSeconds: 28)
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].samples, wav.samples)
    }

    func testEmptyClipYieldsItself() {
        let wav = WAVFile(sampleRate: 16_000, samples: Data())
        XCTAssertEqual(wav.segments(maxSeconds: 28).count, 1)
    }

    func testRejectsUnsupportedFormats() {
        // Stereo file → unsupportedFormat.
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2)   // 2 channels
        u32(16_000); u32(64_000); u16(4); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(0)
        XCTAssertThrowsError(try WAVFile.parse(d))

        XCTAssertThrowsError(try WAVFile.parse(Data("not a wav".utf8)))
    }
}
