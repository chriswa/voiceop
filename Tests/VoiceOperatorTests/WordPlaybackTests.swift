import XCTest
@testable import VoiceOperator

final class WordPlaybackTests: XCTestCase {
    @MainActor
    func testReaderFollowsSourcePositionBackAcrossOriginalSentences() async {
        let reader = WordOverlayController()
        reader.beginSession(position: { 0 })
        await reader.appendSentence(start: 0, prepared: TTSPreprocess.prepare("Hello world."), timings: {
            [.init(word: "Hello", start: 0, end: 0.5), .init(word: "world", start: 0.6, end: 1.5)]
        }).value
        await reader.appendSentence(start: 2, prepared: TTSPreprocess.prepare("Open src/main."), timings: {
            [.init(word: "Open", start: 0, end: 0.4), .init(word: "src", start: 0.5, end: 0.8),
             .init(word: "slash", start: 0.9, end: 1.1), .init(word: "main", start: 1.2, end: 1.5)]
        }).value
        let later = reader.line(at: 3)
        XCTAssertEqual(later?.text, "Open src/main.")
        XCTAssertEqual(later?.highlightRange, NSRange(location: 8, length: 1),
                       "the spoken slash must still highlight the original / after timeline offsets")
        let rewound = reader.line(at: 0)
        XCTAssertEqual(rewound?.text, "Hello world.")
        XCTAssertEqual(rewound?.highlightRange, NSRange(location: 0, length: 5))
        XCTAssertEqual(reader.line(at: 0.7)?.highlightRange, NSRange(location: 6, length: 5))
        reader.hide()
        XCTAssertEqual(reader.line(at: 0), rewound, "completion hiding must preserve replay context")
        reader.stop()
        XCTAssertNil(reader.line(at: 0), "discarded jobs must not leave old words behind")
    }
}
