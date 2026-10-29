import XCTest
@testable import VoiceOperator

/// The shape of a pasted transcript — the whole visible effect of tapping left
/// Shift during a dictation.
final class TranscriptStyleTests: XCTestCase {
    private let lower = TranscriptStyle(lowercaseFirst: true)
    private let trim = TranscriptStyle(trimTrailingPunctuation: true)
    private let both = TranscriptStyle(lowercaseFirst: true, trimTrailingPunctuation: true)
    private let discard = TranscriptStyle(discard: true)

    // MARK: - The cycle

    func testTheCycleVisitsEveryStateAndReturns() {
        var seen: [TranscriptStyle] = [.normal]
        var s = TranscriptStyle.normal
        for _ in 0..<5 { s = s.next; seen.append(s) }
        XCTAssertEqual(seen, [.normal, lower, both, trim, discard, .normal])
    }

    func testDiscardIsAlwaysItsOwnStateAndDoesNotShapeText() {
        let invalidCombinedState = TranscriptStyle(lowercaseFirst: true, trimTrailingPunctuation: true, discard: true)
        XCTAssertEqual(invalidCombinedState, discard)
        XCTAssertEqual(discard.apply(to: "The cat sat."), "The cat sat.")
        XCTAssertEqual(discard.accessibilityLabel, "discard transcript")
    }

    // MARK: - Delivery

    func testDiscardSendsNothingInEitherMode() {
        XCTAssertEqual(discard.delivery(of: "Open the logs.", command: false), .none)
        XCTAssertEqual(discard.delivery(of: "Open the logs.", command: true), .none)
    }

    func testACommandIsRoutedUnshaped() {
        XCTAssertEqual(both.delivery(of: "Open the logs.", command: true), .route("Open the logs."))
    }

    func testDictationIsPastedShaped() {
        XCTAssertEqual(trim.delivery(of: "The cat sat.", command: false), .paste("The cat sat "))
    }

    func testABlankTranscriptGoesNowhere() {
        XCTAssertEqual(lower.delivery(of: " ", command: false), .none)
        XCTAssertEqual(TranscriptStyle.normal.delivery(of: "", command: true), .none)
    }

    // MARK: - Normal

    func testNormalIsAnExactNoOp() {
        let text = "The cat sat on the mat."
        XCTAssertEqual(TranscriptStyle.normal.apply(to: text), text)
    }

    func testEmptyTranscriptSurvivesEveryStyle() {
        for style in [TranscriptStyle.normal, lower, trim, both] {
            XCTAssertEqual(style.apply(to: ""), "")
        }
    }

    // MARK: - Lowercase first

    func testLowercasesTheFirstWordAndAddsALeadingSpace() {
        XCTAssertEqual(lower.apply(to: "The cat sat."), " the cat sat.")
    }

    func testALeadingSpaceIsNeverDoubled() {
        XCTAssertEqual(lower.apply(to: " The cat sat."), " the cat sat.")
    }

    func testANonLetterFirstCharacterIsLeftAloneButStillSpaced() {
        XCTAssertEqual(lower.apply(to: "42 cats sat."), " 42 cats sat.")
        XCTAssertEqual(lower.apply(to: "\"The cat sat.\""), " \"The cat sat.\"")
    }

    /// An initial capital that belongs to the word rather than to the sentence.
    func testAcronymsAndThePronounIAreNotCaseFolded() {
        XCTAssertEqual(lower.apply(to: "API is broken."), " API is broken.")
        XCTAssertEqual(lower.apply(to: "I think so."), " I think so.")
        XCTAssertEqual(lower.apply(to: "I'll check."), " I'll check.")
        XCTAssertEqual(lower.apply(to: "TTS, mostly."), " TTS, mostly.")
    }

    /// …but a lone capital A really is the article, and mid-sentence it is "a".
    func testASingleLetterWordOtherThanIIsFolded() {
        XCTAssertEqual(lower.apply(to: "A cat sat."), " a cat sat.")
    }

    /// The exemption is the pronoun, not every word starting with a capital I.
    func testACapitalIThatBeginsAnOrdinaryWordIsStillFolded() {
        XCTAssertEqual(lower.apply(to: "It's fine."), " it's fine.")
    }

    func testAnAlreadyLowercaseTranscriptOnlyGainsItsSpace() {
        XCTAssertEqual(lower.apply(to: "the cat sat."), " the cat sat.")
    }

    // MARK: - Trim end punctuation

    func testStripsTerminalPunctuationAndGuaranteesOneTrailingSpace() {
        XCTAssertEqual(trim.apply(to: "The cat sat."), "The cat sat ")
        XCTAssertEqual(trim.apply(to: "The cat sat, "), "The cat sat ")
        XCTAssertEqual(trim.apply(to: "The cat sat;"), "The cat sat ")
        XCTAssertEqual(trim.apply(to: "The cat sat:"), "The cat sat ")
        XCTAssertEqual(trim.apply(to: "Did the cat sit?"), "Did the cat sit ")
        XCTAssertEqual(trim.apply(to: "The cat sat!"), "The cat sat ")
    }

    func testATrailingSpaceIsAddedEvenWithNothingToStrip() {
        XCTAssertEqual(trim.apply(to: "The cat sat"), "The cat sat ")
    }

    /// A space *before* the full stop would otherwise survive as a double space.
    func testASpaceBeforeThePunctuationIsAbsorbed() {
        XCTAssertEqual(trim.apply(to: "The cat sat ."), "The cat sat ")
    }

    /// Only one mark comes off: an ellipsis is not four sentences ending.
    func testOnlyOneMarkIsRemoved() {
        XCTAssertEqual(trim.apply(to: "The cat sat..."), "The cat sat.. ")
    }

    func testInteriorPunctuationIsUntouched() {
        XCTAssertEqual(trim.apply(to: "First, second."), "First, second ")
    }

    // MARK: - Both

    func testBothFlagsProduceAFragmentSpacedAtEachEnd() {
        XCTAssertEqual(both.apply(to: "The cat sat on the mat."), " the cat sat on the mat ")
    }

    /// The realistic case this exists for: dropping a phrase into the middle of a
    /// half-written line.
    func testMidSentenceInjectionReadsAsOneSentence() {
        let before = "I think we should"
        let after = "before the deploy."
        XCTAssertEqual(before + both.apply(to: "Check the logs first.") + after,
                       "I think we should check the logs first before the deploy.")
    }
}
