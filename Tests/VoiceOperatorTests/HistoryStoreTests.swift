import XCTest
@testable import VoiceOperator

final class HistoryStoreTests: XCTestCase {
    func testGarbageDecodesToEmptyNotCrash() {
        let (tts, stt) = HistoryStore.decode(Data("not json at all {".utf8))
        XCTAssertTrue(tts.isEmpty)
        XCTAssertTrue(stt.isEmpty)
    }

    func testEmptyDataDecodesToEmpty() {
        let (tts, stt) = HistoryStore.decode(Data())
        XCTAssertTrue(tts.isEmpty && stt.isEmpty)
    }

    func testIncompatibleVersionIsIgnored() {
        // A future/older format: right JSON shape, wrong version → dropped, no crash.
        let json = #"{"version": 999, "tts": [], "stt": []}"#
        let (tts, stt) = HistoryStore.decode(Data(json.utf8))
        XCTAssertTrue(tts.isEmpty && stt.isEmpty)
    }

    func testOlderEntriesWithoutNewFieldsStillLoad() {
        // A pre-"More details" payload: entries have no context/priorSummaries.
        // Must load (with empty defaults), not be dropped.
        let json = """
        {"version": 1, "stt": [],
         "tts": [{"id":"00000000-0000-0000-0000-000000000001","name":"Waldo",
                  "body":"did the thing","voiceID":"v1","sessionKey":"s1",
                  "date": 760000000}]}
        """
        let (tts, stt) = HistoryStore.decode(Data(json.utf8))
        XCTAssertEqual(tts.count, 1, "older entry should survive")
        XCTAssertEqual(tts.first?.name, "Waldo")
        XCTAssertTrue(tts.first?.context.isEmpty ?? false)
        XCTAssertTrue(stt.isEmpty)
    }

    func testMissingFieldsDoNotCrash() {
        // Payload missing required keys → decode fails → empty, not a crash.
        let json = #"{"version": 1}"#
        let (tts, stt) = HistoryStore.decode(Data(json.utf8))
        XCTAssertTrue(tts.isEmpty && stt.isEmpty)
    }
}
