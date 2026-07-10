import XCTest
@testable import VoiceOperator

final class HistoryStoreTests: XCTestCase {
    func testGarbageDecodesToEmptyNotCrash() {
        let c = HistoryStore.decode(Data("not json at all {".utf8))
        XCTAssertTrue(c.tts.isEmpty && c.stt.isEmpty && c.commands.isEmpty)
    }

    func testEmptyDataDecodesToEmpty() {
        let c = HistoryStore.decode(Data())
        XCTAssertTrue(c.tts.isEmpty && c.stt.isEmpty && c.commands.isEmpty)
    }

    func testIncompatibleVersionIsIgnored() {
        let json = #"{"version": 999, "tts": [], "stt": []}"#
        let c = HistoryStore.decode(Data(json.utf8))
        XCTAssertTrue(c.tts.isEmpty && c.stt.isEmpty)
    }

    func testOlderFileWithoutNewFieldsStillLoads() {
        // An early file predating the context/priorSummaries fields and the
        // `commands` list: entries lack those keys. Must load, not drop.
        let json = """
        {"version": 1, "stt": [],
         "tts": [{"id":"00000000-0000-0000-0000-000000000001","name":"Waldo",
                  "body":"did the thing","voiceID":"v1","sessionKey":"s1",
                  "date": 760000000}]}
        """
        let c = HistoryStore.decode(Data(json.utf8))
        XCTAssertEqual(c.tts.count, 1, "older entry should survive")
        XCTAssertEqual(c.tts.first?.name, "Waldo")
        XCTAssertTrue(c.tts.first?.context.isEmpty ?? false)
        XCTAssertTrue(c.commands.isEmpty, "missing commands list defaults to empty")
    }

    func testMissingListsDefaultToEmpty() {
        let c = HistoryStore.decode(Data(#"{"version": 1}"#.utf8))
        XCTAssertTrue(c.tts.isEmpty && c.stt.isEmpty && c.commands.isEmpty)
    }

    func testLastReferencedSessionKeyDecodes() {
        let json = #"{"version": 1, "lastReferencedSessionKey": "s1"}"#
        let c = HistoryStore.decode(Data(json.utf8))
        XCTAssertEqual(c.lastReferencedSessionKey, "s1", "restored last speaker survives")
    }

    func testOlderFileWithoutLastReferencedKeyIsNil() {
        // Files written before "Focus last speaker" persistence lack the key.
        let c = HistoryStore.decode(Data(#"{"version": 1, "tts": [], "stt": []}"#.utf8))
        XCTAssertNil(c.lastReferencedSessionKey, "absent key defaults to nil, not a crash")
    }
}
