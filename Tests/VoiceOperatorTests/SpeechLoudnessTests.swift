import XCTest
@testable import VoiceOperator

/// The phone's copy of speech (`/v1/synthesize`) gets the same lift as speech
/// played here, stays in step with its word timings, and never clips.
final class SpeechLoudnessTests: XCTestCase {
    private func wav(_ samples: [Float]) -> WAVFile {
        var d = Data()
        for v in samples { withUnsafeBytes(of: Int16(v * 32767).littleEndian) { d.append(contentsOf: $0) } }
        return WAVFile(sampleRate: 24_000, samples: d)
    }
    private func floats(_ w: WAVFile) -> [Float] {
        w.samples.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)).map { Float(Int16(littleEndian: $0)) / 32768 } }
    }

    func testQuietSpeechIsLiftedByTheMakeupGainInPlace() throws {
        // Silence, then a quiet tone starting at exactly 0.5 s.
        let input = (0..<24_000).map { $0 < 12_000 ? 0 : 0.03 * sin(Float($0) * 0.1) }
        let out = floats(try SpeechLoudness.boosted(wav(input)))
        XCTAssertEqual(out.count, input.count)
        let peak = out[13_000...].map(abs).max()!
        XCTAssertEqual(20 * log10(peak / 0.03), SpeechLoudness.makeupGainDB, accuracy: 0.5)
        // The limiter's lookahead is trimmed: nothing before the tone starts.
        XCTAssertLessThan(out[..<11_950].map(abs).max()!, 0.001)
        XCTAssertGreaterThan(out[12_000..<12_100].map(abs).max()!, 0.05)
    }

    func testHotSpeechDoesNotClip() throws {
        let input = (0..<24_000).map { 0.98 * sin(Float($0) * 0.1) }
        let out = floats(try SpeechLoudness.boosted(wav(input)))
        XCTAssertLessThan(out.map(abs).max()!, 0.999)
    }
}
