import XCTest
@testable import VoiceOperator

final class PlaceholderTests: XCTestCase {
    func testStatusTint() {
        XCTAssertEqual(OperatorStatus.listening.tint, .systemRed)
        XCTAssertEqual(OperatorStatus.speaking.tint, .systemGreen)
        XCTAssertNil(OperatorStatus.idle.tint)
    }
}
