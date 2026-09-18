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

    // MARK: - Code-shaped text (rules migrated from spaceterm's cartesiaFixup)

    func testCamelCaseSplits() {
        XCTAssertEqual(TTSPreprocess.ttsText("cleanTerminalCopy"), "clean Terminal Copy")
        XCTAssertEqual(TTSPreprocess.ttsText("TerminalCard renders fine"), "Terminal Card renders fine")
        XCTAssertEqual(TTSPreprocess.ttsText("the speakText function"), "the speak Text function")
        // Nothing to split: one capital, at the front.
        XCTAssertEqual(TTSPreprocess.ttsText("Component"), "Component")
    }

    func testAllCapsWordsArePronounced() {
        XCTAssertEqual(TTSPreprocess.ttsText("FEATURE"), "feature")
        XCTAssertEqual(TTSPreprocess.ttsText("FEATURE: added a thing"), "feature: added a thing")
        XCTAssertEqual(TTSPreprocess.ttsText("IDEAS and CAVEATS were captured"),
                       "ideas and caveats were captured")
        XCTAssertEqual(TTSPreprocess.ttsText("JSON"), "json")
        XCTAssertEqual(TTSPreprocess.ttsText("YAML"), "yaml")
        XCTAssertEqual(TTSPreprocess.ttsText("LERP the values"), "lerp the values")
        // Three letters, consonant-vowel-consonant and vowel-vowel-consonant.
        XCTAssertEqual(TTSPreprocess.ttsText("GAP between items"), "gap between items")
        XCTAssertEqual(TTSPreprocess.ttsText("OUT of order"), "out of order")
        XCTAssertEqual(TTSPreprocess.ttsText("AIM higher"), "aim higher")
    }

    func testAcronymsAreSpelledOut() {
        XCTAssertEqual(TTSPreprocess.ttsText("TTS"), "T. T. S.")
        XCTAssertEqual(TTSPreprocess.ttsText("Kokoro TTS now reads things"),
                       "Kokoro T. T. S. now reads things")
        XCTAssertEqual(TTSPreprocess.ttsText("HTTP"), "H. T. T. P.")
        XCTAssertEqual(TTSPreprocess.ttsText("HTML"), "H. T. M. L.")
        XCTAssertEqual(TTSPreprocess.ttsText("CSS"), "C. S. S.")
        XCTAssertEqual(TTSPreprocess.ttsText("call the API endpoint"), "call the A. P. I. endpoint")
        XCTAssertEqual(TTSPreprocess.ttsText("IDE"), "I. D. E.")
        XCTAssertEqual(TTSPreprocess.ttsText("the OS handles it"), "the O. S. handles it")
    }

    func testCapitalOverrides() {
        // Reads better as one syllable than as three letters.
        XCTAssertEqual(TTSPreprocess.ttsText("the URL is here"), "the url is here")
        // Short words capitalised for emphasis are prose, not acronyms: spelling
        // "D. O. N. O. T." out is the worse failure.
        XCTAssertEqual(TTSPreprocess.ttsText("DO NOT ship it"), "do not ship it")
        XCTAssertEqual(TTSPreprocess.ttsText("NO"), "no")
    }

    func testCapitalRunsThatAreNotWholeWordsAreLeftAlone() {
        // Rewriting half a token splits a word down the middle when spoken.
        XCTAssertEqual(TTSPreprocess.ttsText("HTTPserver"), "HTTPserver")
        XCTAssertEqual(TTSPreprocess.ttsText("ID2"), "ID2")
        XCTAssertEqual(TTSPreprocess.ttsText("I am here"), "I am here")
        XCTAssertEqual(TTSPreprocess.ttsText("Hello World"), "Hello World")
        XCTAssertEqual(TTSPreprocess.ttsText("value is 1234"), "value is 1234")
    }

    func testScreamingSnakeCaseSplitsThenRules() {
        XCTAssertEqual(TTSPreprocess.ttsText("INTER_UTTERANCE_GAP_MS"),
                       "inter utterance gap M. S.")
        XCTAssertEqual(TTSPreprocess.ttsText("set MAX_RETRIES = 3 today"),
                       "set max retries = 3 today")
        XCTAssertEqual(TTSPreprocess.ttsText("set MAX_RETRIES on the httpClient instance"),
                       "set max retries on the http Client instance")
    }

    func testUnderscoresThatSurviveKeepTheirWord() {
        // A dunder is not a separator: both sides of each underscore must be
        // alphanumeric for it to be spoken as a space.
        XCTAssertEqual(TTSPreprocess.ttsText("__init__"), "__init__")
        XCTAssertEqual(TTSPreprocess.ttsText("_private"), "_private")
    }

    func testFileExtensionDotIsSpokenOutsideAPath() {
        // The original complaint: ".ts" read as "dot tess".
        XCTAssertEqual(TTSPreprocess.ttsText("open foo.ts"), "open foo dot T. S.")
        XCTAssertEqual(TTSPreprocess.ttsText("foo.ts:42"), "foo dot T. S.:42")
        XCTAssertEqual(TTSPreprocess.ttsText("edit foo.ts then bar.ts"),
                       "edit foo dot T. S. then bar dot T. S.")
        // A pronounceable extension is a word, not letters.
        XCTAssertEqual(TTSPreprocess.ttsText("open config.json"), "open config dot json")
        XCTAssertEqual(TTSPreprocess.ttsText("src/lib/cleanTerminalCopy.ts"),
                       "src slash lib slash clean Terminal Copy dot T. S.")
    }

    func testUnknownExtensionsAndProseDotsAreLeftAlone() {
        // Not an extension: a decimal, an abbreviation, a sentence end.
        XCTAssertEqual(TTSPreprocess.ttsText("Version 2.0 is out."), "Version 2.0 is out.")
        XCTAssertEqual(TTSPreprocess.ttsText("e.g. this one"), "e.g. this one")
        XCTAssertEqual(TTSPreprocess.ttsText("data.tsv has 100 rows"), "data.tsv has 100 rows")
        XCTAssertEqual(TTSPreprocess.ttsText("Update foo.ts."), "Update foo dot T. S..")
    }

    func testMappingSurvivesTheCodeRules() {
        // "TTS" spells out to eight units, every one of which must point back
        // inside the original three characters, or an interrupt mid-word would
        // report a position past the end of what was said.
        let p = TTSPreprocess.prepare("TTS")
        XCTAssertEqual(p.ttsText, "T. T. S.")
        XCTAssertEqual(p.origPositions.count, (p.ttsText as NSString).length)
        XCTAssertEqual(p.origPositions.first, 0)
        XCTAssertEqual(p.origPositions.last, 2)
        XCTAssertTrue(p.origPositions.allSatisfy { $0 >= 0 && $0 < 3 })

        // A camel seam's inserted space maps back at the capital it precedes.
        let q = TTSPreprocess.prepare("aB")
        XCTAssertEqual(q.ttsText, "a B")
        XCTAssertEqual(q.origPositions, [0, 1, 1])
    }
}
