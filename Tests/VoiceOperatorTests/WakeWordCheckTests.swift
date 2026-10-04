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

    func testAStartingWakeWordMatchesWhateverFollows() {
        XCTAssertTrue(WakeWordCheck.startsWith("control", in: "Control, what's Kevin doing?"))
        XCTAssertTrue(WakeWordCheck.startsWith("control", in: "control the lights"))
        XCTAssertTrue(WakeWordCheck.startsWith("control", in: "Control."))
        XCTAssertFalse(WakeWordCheck.startsWith("control", in: "Under control."))
        XCTAssertFalse(WakeWordCheck.startsWith("control", in: "Controller, please."))
        XCTAssertFalse(WakeWordCheck.startsWith("control", in: ""))
    }

    func testTheEndPhraseIsFoundAnywhereAsWholeWords() {
        XCTAssertTrue(PhraseWatcher.contains("over and out", in: "Tell Kevin to stop. Over and out."))
        XCTAssertTrue(PhraseWatcher.contains("over and out", in: "over, and out"))
        XCTAssertTrue(PhraseWatcher.contains("over and out", in: "Over and out, and then something"))
        XCTAssertFalse(PhraseWatcher.contains("over and out", in: "moreover and outside"))
        XCTAssertFalse(PhraseWatcher.contains("over and out", in: "over and over"))
    }

    func testTheCreateBodyMayNameAPhraseToWatchFor() {
        XCTAssertEqual(TranscriptionRoute.watchPhrase(fromCreateBody: Data(#"{"sample_rate":16000,"watch":"over and out"}"#.utf8)), "over and out")
        XCTAssertNil(TranscriptionRoute.watchPhrase(fromCreateBody: Data(#"{"sample_rate":16000}"#.utf8)))
        XCTAssertNil(TranscriptionRoute.watchPhrase(fromCreateBody: Data(#"{"watch":"  "}"#.utf8)))
        XCTAssertNil(TranscriptionRoute.watchPhrase(fromCreateBody: Data()))
    }
}
