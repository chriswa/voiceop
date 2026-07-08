import XCTest
import FlowAPI
@testable import VoiceOperator

final class WisprFlowTranscriberTests: XCTestCase {
    func testBuildRequestPopulatesDictionaryPacketsAndCommit() {
        let packets = [Data([1, 2, 3]), Data([4, 5])]
        let req = WisprFlowTranscriber.buildRequest(
            packets: packets, words: ["Claude", "kubectl"], token: "jwt")
        XCTAssertEqual(req.payload.audioPackets.items, packets)
        XCTAssertEqual(req.init_p.preferences.vocabulary.dictionaryPersonal, ["Claude", "kubectl"])
        XCTAssertEqual(req.init_p.metadata.audioEncoding, .opus)
        XCTAssertEqual(req.init_p.metadata.environment, .production)
        XCTAssertEqual(req.commit.rawValue, 1)   // COMMIT_TRUE
    }

    func testTextPrefersFormattedResult() {
        var resp = FlowApi_V1_Response()
        var out = FlowApi_V1_Transcription()
        out.plaintext = "Formatted text."
        var result = FlowApi_V1_Result()
        result.output = out
        resp.result = result
        XCTAssertEqual(WisprFlowTranscriber.text(from: resp), "Formatted text.")
    }

    func testTextFallsBackToStateFormattedThenRaw() {
        var resp = FlowApi_V1_Response()
        var state = FlowApi_V1_State()
        var raw = FlowApi_V1_Text()
        raw.content = "raw only"
        state.rawText = raw
        resp.state = state
        XCTAssertEqual(WisprFlowTranscriber.text(from: resp), "raw only")

        var formatted = FlowApi_V1_Text()
        formatted.content = "formatted wins"
        resp.state.formattedText = formatted
        XCTAssertEqual(WisprFlowTranscriber.text(from: resp), "formatted wins")
    }
}
