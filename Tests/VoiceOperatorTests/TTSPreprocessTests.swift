import XCTest
@testable import VoiceOperator

final class TTSPreprocessTests: XCTestCase {
    func testSlashIsSpoken() {
        XCTAssertEqual(TTSPreprocess.ttsText("See lib/ci for details."),
                       "See lib slash ci for details.")
    }

    func testPathSpeaksSlashAndDot() {
        XCTAssertEqual(TTSPreprocess.ttsText("Open src/main/app.swift now."),
                       "Open src slash main slash app dot swift now.")
    }

    func testDotOnlySpokenInsidePaths() {
        // No slash in the token → the dot is a decimal, left for Kokoro to read.
        XCTAssertEqual(TTSPreprocess.ttsText("Version 2.0 is out."), "Version 2.0 is out.")
    }

    func testHyphenAndUnderscoreBecomeSpaces() {
        XCTAssertEqual(TTSPreprocess.ttsText("It is state-of-the-art today."),
                       "It is state of the art today.")
        XCTAssertEqual(TTSPreprocess.ttsText("Edit my_file_name here."),
                       "Edit my file name here.")
    }

    func testAsterisksAreDropped() {
        XCTAssertEqual(TTSPreprocess.ttsText("this is **bold** text"), "this is bold text")
    }

    func testLeavesNonWordBoundariesAlone() {
        XCTAssertEqual(TTSPreprocess.ttsText("It is -5 degrees."), "It is -5 degrees.")
        XCTAssertEqual(TTSPreprocess.ttsText("a - b and c — d"), "a - b and c — d")
        XCTAssertEqual(TTSPreprocess.ttsText("open the dir/ please"), "open the dir/ please")
    }

    func testPlainTextIsUnchanged() {
        let s = "The quick brown fox jumps over the lazy dog."
        XCTAssertEqual(TTSPreprocess.ttsText(s), s)
    }

    func testMappingPointsSpokenSeparatorBackAtTheCharacter() {
        // "a/b" → "a slash b"; the "slash" token must map back to the "/" at
        // original offset 1, so the overlay highlights the literal slash.
        let p = TTSPreprocess.prepare("a/b")
        XCTAssertEqual(p.ttsText, "a slash b")
        XCTAssertEqual(p.origPositions.count, (p.ttsText as NSString).length)
        let slash = (p.ttsText as NSString).range(of: "slash")
        XCTAssertEqual(p.origPositions[slash.location], 1)
        XCTAssertEqual(p.origPositions[slash.location + slash.length - 1], 1)
    }
}
