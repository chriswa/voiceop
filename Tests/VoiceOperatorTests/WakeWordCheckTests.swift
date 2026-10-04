import XCTest
@testable import VoiceOperator

final class WakeWordCheckTests: XCTestCase {
    func testTheWordAloneMatches() {
        XCTAssertTrue(WakeWordCheck.isOnly("control", in: "Control."))
        XCTAssertTrue(WakeWordCheck.isOnly("control", in: "control?"))
        XCTAssertTrue(WakeWordCheck.isOnly("control", in: "  CONTROL!  "))
    }

    func testAnythingElseSaidDoesNot() {
        XCTAssertFalse(WakeWordCheck.isOnly("control", in: "Under control."))
        XCTAssertFalse(WakeWordCheck.isOnly("control", in: "Control the lights."))
        XCTAssertFalse(WakeWordCheck.isOnly("control", in: "Controller."))
        XCTAssertFalse(WakeWordCheck.isOnly("control", in: "Patrol."))
        XCTAssertFalse(WakeWordCheck.isOnly("control", in: ""))
        XCTAssertFalse(WakeWordCheck.isOnly("", in: ""))
    }
}
