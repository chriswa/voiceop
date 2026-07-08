import XCTest
@testable import VoiceOperator

final class WisprTranscriberTests: XCTestCase {
    func testJoinChunkTextsDropsEmptyAndSingleSpaces() {
        XCTAssertEqual(WisprTranscriber.joinChunkTexts(["Hello ", "", "  world"]),
                       "Hello world")
    }

    func testJoinChunkTextsEmptyWhenNoContent() {
        XCTAssertEqual(WisprTranscriber.joinChunkTexts(["", "   "]), "")
    }
}
