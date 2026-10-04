import XCTest
@testable import VoiceOperator

/// Where a listener's interruption lands, in characters rather than sentences.
final class SpokenNarrationTests: XCTestCase {
    /// "Hello world." with each word given a second of audio.
    @MainActor
    private func narration() async -> SpokenNarration {
        let n = SpokenNarration()
        await n.append(start: 0, prepared: TTSPreprocess.prepare("Hello world."), timings: {
            [.init(word: "Hello", start: 0, end: 0.5), .init(word: "world", start: 1, end: 1.5)]
        }).value
        return n
    }

    @MainActor
    func testReportsTheEndOfTheWordBeingSpoken() async {
        let n = await narration()
        // Mid-way through "Hello": the listener has heard it, so it counts.
        XCTAssertEqual(n.spokenPrefix(at: 0.3), SpokenPosition(sentence: 0, characterOffset: 5))
    }

    @MainActor
    func testReportsNothingHeardBeforeTheFirstWordSounds() async {
        let n = await narration()
        // The gap between a sentence starting on the timeline and its first
        // word: a listener who stops it here heard nothing at all, and saying
        // "five characters" would put words in their ears.
        let n2 = SpokenNarration()
        await n2.append(start: 0, prepared: TTSPreprocess.prepare("Hello world."), timings: {
            [.init(word: "Hello", start: 0.4, end: 0.9)]
        }).value
        XCTAssertEqual(n2.spokenPrefix(at: 0.1), SpokenPosition(sentence: 0, characterOffset: 0))
        XCTAssertNotNil(n.spokenPrefix(at: 0.3))
    }

    @MainActor
    func testReportsTheWholeSentenceOnceItsLastWordIsDone() async {
        let n = await narration()
        // Past the last word's end: the trailing "." was never a timing token,
        // but it was certainly spoken past, so the sentence counts as heard in
        // full rather than stopping short at "world".
        XCTAssertEqual(n.spokenPrefix(at: 2), SpokenPosition(sentence: 0, characterOffset: 12))
    }

    /// The offsets are into the sentence as *written*, not as synthesized —
    /// `TTSPreprocess` says "slash" out loud where the text has a `/`, and an
    /// offset measured against the spoken form would drift by four characters
    /// for every path in the sentence.
    @MainActor
    func testOffsetsIndexTheOriginalText() async {
        let n = SpokenNarration()
        await n.append(start: 0, prepared: TTSPreprocess.prepare("Open src/main."), timings: {
            [.init(word: "Open", start: 0, end: 0.4), .init(word: "src", start: 0.5, end: 0.8),
             .init(word: "slash", start: 0.9, end: 1.1), .init(word: "main", start: 1.2, end: 1.5)]
        }).value
        XCTAssertEqual(n.spokenPrefix(at: 1.0), SpokenPosition(sentence: 0, characterOffset: 9),
                       "the spoken 'slash' ends just past the literal / at index 8")
        XCTAssertEqual(n.spokenPrefix(at: 1.3), SpokenPosition(sentence: 0, characterOffset: 13))
    }

    /// A rewind puts the voice back into a sentence the queue has already left.
    /// The reported index is what makes that recoverable downstream.
    @MainActor
    func testReportsWhichSentenceTheVoiceIsActuallyIn() async {
        let n = SpokenNarration()
        await n.append(start: 0, prepared: TTSPreprocess.prepare("First one."), timings: {
            [.init(word: "First", start: 0, end: 0.4), .init(word: "one", start: 0.5, end: 0.9)]
        }).value
        await n.append(start: 2, prepared: TTSPreprocess.prepare("Second one."), timings: {
            [.init(word: "Second", start: 0, end: 0.4), .init(word: "one", start: 0.5, end: 0.9)]
        }).value
        XCTAssertEqual(n.spokenPrefix(at: 2.6), SpokenPosition(sentence: 1, characterOffset: 10))
        XCTAssertEqual(n.spokenPrefix(at: 0.2), SpokenPosition(sentence: 0, characterOffset: 5))
    }

    /// Timings arrive after the sentence takes its place on the timeline. In
    /// that window there is no word-level answer, and saying so lets the caller
    /// fall back to sentence resolution instead of reporting a confident zero.
    @MainActor
    func testHasNoAnswerUntilTimingsLand() {
        let n = SpokenNarration()
        n.append(start: 0, prepared: TTSPreprocess.prepare("Hello world."), timings: {
            try? await Task.sleep(for: .seconds(60))
            return []
        })
        XCTAssertNil(n.spokenPrefix(at: 0.3))
    }

    @MainActor
    func testResetDiscardsTheNarration() async {
        let n = await narration()
        n.reset()
        XCTAssertNil(n.spokenPrefix(at: 0.3))
        XCTAssertTrue(n.isEmpty)
    }

    /// A timed `/v1/synthesize` reports where each word ends in the text as
    /// sent, so the phone can say which word a listener cut in on.
    func testRemoteSynthesisReportsEachWordsEndInTheTextAsSent() {
        let words = SpeechHTTPService.wordObjects(prepared: TTSPreprocess.prepare("Want me to send it to Tessa, or not?"), timings: [
            .init(word: "Want", start: 0, end: 0.2), .init(word: "me", start: 0.2, end: 0.3),
            .init(word: "to", start: 0.3, end: 0.4), .init(word: "send", start: 0.4, end: 0.6),
            .init(word: "it", start: 0.6, end: 0.7), .init(word: "to", start: 0.7, end: 0.8),
            .init(word: "Tessa", start: 0.8, end: 1.2), .init(word: "or", start: 1.3, end: 1.4),
            .init(word: "not", start: 1.4, end: 1.6),
        ])
        XCTAssertEqual(words?.map { $0["character_end"] as? Int }, [4, 7, 10, 15, 18, 21, 27, 31, 35])
        XCTAssertEqual(words?[6]["start"] as? Double, 0.8)
    }

    /// The phone hears the same cleaned-up text as the Mac, and a spoken
    /// "slash" still ends where the `/` does in the text as sent.
    func testRemoteSynthesisMapsCleanedUpWordsBackToTheTextAsSent() {
        let prepared = TTSPreprocess.prepare("Open src/main now.")
        XCTAssertTrue(prepared.ttsText.contains("slash"))
        let words = SpeechHTTPService.wordObjects(prepared: prepared, timings: [
            .init(word: "Open", start: 0, end: 0.2), .init(word: "src", start: 0.2, end: 0.4),
            .init(word: "slash", start: 0.4, end: 0.6), .init(word: "main", start: 0.6, end: 0.8),
            .init(word: "now", start: 0.8, end: 1),
        ])
        XCTAssertEqual(words?.map { $0["character_end"] as? Int }, [4, 8, 9, 13, 17])
    }

    /// Tokens that cannot be found in the text give no words, not wrong ones.
    func testRemoteSynthesisGivesNoWordsWhenTheyCannotBeAligned() {
        XCTAssertNil(SpeechHTTPService.wordObjects(prepared: TTSPreprocess.prepare("Hello world."), timings: [.init(word: "goodbye", start: 0, end: 1)]))
    }
}
