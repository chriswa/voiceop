import FluidAudio
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

    func testTokenTimingsBecomeWordsInMilliseconds() {
        func token(_ text: String, _ start: Double, _ end: Double) -> TokenTiming {
            TokenTiming(token: text, tokenId: 0, startTime: start, endTime: end, confidence: 1)
        }
        // Sub-word pieces join their word, and a word's span runs from its first piece to the last one of it
        // that is not punctuation (a comma or full stop is timed in the silence after the word).
        let words = ParakeetEngine.words(from: [token("\u{2581}Mo", 0.08, 0.24), token("ve", 0.24, 0.4), token(",", 0.4, 0.9),
                                                token("\u{2581}up", 0.8, 1.04)])
        XCTAssertEqual(words, [TranscribedWord(word: "Move,", startMs: 80, endMs: 400), TranscribedWord(word: "up", startMs: 800, endMs: 1040)])
    }

    func testNoTokenTimingsMeansNoWords() {
        XCTAssertNil(ParakeetEngine.words(from: nil))
        XCTAssertNil(ParakeetEngine.words(from: []))
    }

    func testAnOddTrailingByteIsIgnored() {
        XCTAssertEqual(ParakeetEngine.floatSamples(Data([0, 0, 7])).count, 1)
    }
}
