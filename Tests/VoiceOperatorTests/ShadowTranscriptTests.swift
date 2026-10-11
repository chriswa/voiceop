import XCTest
@testable import VoiceOperator

final class ShadowTranscriptTests: XCTestCase {
    func testAnEntryFromBeforeShadowsStillDecodes() throws {
        let json = #"{"id":"6B1C2F3E-1111-4222-8333-944455556666","date":0,"duration":1.5,"transcript":"hi","wavURL":null}"#
        let entry = try JSONDecoder().decode(STTHistoryEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.transcript, "hi")
        XCTAssertNil(entry.shadow)
    }

    func testAShadowRoundTripsWithItsEntry() throws {
        var entry = STTHistoryEntry(date: Date(timeIntervalSince1970: 0), duration: 2, transcript: "pasted", wavURL: nil)
        entry.shadow = ShadowTranscript(provider: TranscriptionProviderID.wisprFlow.rawValue, text: "shadowed", latencyMS: 420)
        let decoded = try JSONDecoder().decode(STTHistoryEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded.shadow, entry.shadow)
    }

    func testMenuTitleNamesTheProviderAndAnyFailure() {
        XCTAssertEqual(ShadowTranscript(provider: "wispr-flow", text: "Hello there.").menuTitle,
                       "Wispr Flow: Hello there.")
        XCTAssertEqual(ShadowTranscript(provider: "parakeet", error: "boom").menuTitle,
                       "Parakeet (on this Mac): ⚠️ boom")
        XCTAssertEqual(ShadowTranscript(provider: "retired-provider", text: "").menuTitle,
                       "retired-provider: (empty)")
    }
}
