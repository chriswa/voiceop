import XCTest
@testable import VoiceOperator

final class WisprDictionaryTests: XCTestCase {
    private func entry(_ word: String?, replacement: String? = nil, deleted: Bool = false,
                       freq: Double = 0, lastUsed: String? = nil, modified: String? = nil)
        -> WisprDictionary.Entry {
        .init(word: word, replacement: replacement, is_deleted: deleted,
              frequency_used: freq, last_used: lastUsed, modified_at: modified)
    }

    func testKeepsOnlyRecognitionWords() {
        let personal = [
            entry("Claude"),                          // kept
            entry("brb", replacement: "be right back"), // dropped: has a replacement (snippet)
            entry("Kubernetes", deleted: true),        // dropped: soft-deleted
            entry("   "),                              // dropped: blank
            entry(nil),                                // dropped: no word
        ]
        XCTAssertEqual(WisprDictionary.contextWords(personal: personal, team: []), ["Claude"])
    }

    func testRanksByFrequencyThenRecency() {
        let personal = [
            entry("low", freq: 1, lastUsed: "2026-01-01T00:00:00"),
            entry("high", freq: 9, lastUsed: "2020-01-01T00:00:00"),
            entry("recent", freq: 1, lastUsed: "2026-07-01T00:00:00"),
        ]
        // high (freq 9) first; then the two freq-1 words most-recent first.
        XCTAssertEqual(WisprDictionary.contextWords(personal: personal, team: []),
                       ["high", "recent", "low"])
    }

    func testPersonalWordsRankAheadOfTeam() {
        let personal = [entry("Anthropic", freq: 1)]
        let team = [entry("Datadog", freq: 100)]   // higher freq but team ranks after personal
        XCTAssertEqual(WisprDictionary.contextWords(personal: personal, team: team),
                       ["Anthropic", "Datadog"])
    }

    func testDedupesCaseInsensitivelyKeepingFirst() {
        let personal = [entry("Claude", freq: 5)]
        let team = [entry("claude", freq: 99)]     // duplicate of the personal entry
        XCTAssertEqual(WisprDictionary.contextWords(personal: personal, team: team), ["Claude"])
    }

    func testCapsAtLimit() {
        let personal = (0..<100).map { entry("word\($0)", freq: Double(100 - $0)) }
        let words = WisprDictionary.contextWords(personal: personal, team: [], limit: 60)
        XCTAssertEqual(words.count, 60)
        XCTAssertEqual(words.first, "word0")   // highest frequency
        XCTAssertEqual(words.last, "word59")
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(WisprDictionary.contextWords(personal: [entry("  Claude  ")], team: []),
                       ["Claude"])
    }
}
