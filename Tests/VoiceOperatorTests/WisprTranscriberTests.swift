import XCTest
@testable import VoiceOperator

final class WisprTranscriberTests: XCTestCase {
    func testPromptJoinsWordsWithCommas() {
        XCTAssertEqual(WisprTranscriber.prompt(from: ["Claude", "kubectl", "Coda"]),
                       "Claude, kubectl, Coda")
    }

    func testPromptEmptyWhenNoWords() {
        XCTAssertEqual(WisprTranscriber.prompt(from: []), "")
    }
}
