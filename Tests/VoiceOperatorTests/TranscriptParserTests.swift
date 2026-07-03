import XCTest
@testable import VoiceOperator

final class TranscriptParserTests: XCTestCase {
    private func line(_ obj: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }

    func testExtractsAssistantEndTurns() {
        let jsonl = [
            line(["type": "user", "entrypoint": "cli",
                  "message": ["content": "please do the thing"]]),
            line(["type": "assistant",
                  "message": ["stop_reason": "tool_use", "content": [["type": "text", "text": "working on it"]]]]),
            line(["type": "assistant",
                  "message": ["stop_reason": "end_turn", "content": [["type": "text", "text": "done, it works"]]]]),
        ].joined(separator: "\n") + "\n"

        let parsed = TranscriptParser.parse(data: Data(jsonl.utf8))
        XCTAssertEqual(parsed.entrypoint, "cli")
        XCTAssertEqual(parsed.turns.count, 3)
        let endTurns = parsed.turns.filter { $0.role == "assistant" && $0.stopReason == "end_turn" }
        XCTAssertEqual(endTurns.map(\.text), ["done, it works"])
    }

    func testSkipsToolResultsAndTracksBackground() {
        let jsonl = [
            line(["type": "user", "message": ["content": [["type": "tool_result", "content": "x"]]]]),
            line(["type": "assistant",
                  "message": ["stop_reason": "end_turn",
                              "content": [["type": "text", "text": "Command running in background with ID: abc123"]]]]),
        ].joined(separator: "\n") + "\n"

        let parsed = TranscriptParser.parse(data: Data(jsonl.utf8))
        // tool_result user line is skipped; only the assistant turn remains.
        XCTAssertEqual(parsed.turns.count, 1)
        // The launch phrase is in assistant text (not a tool_result), so it must
        // NOT count as outstanding work (see the phantom-launch regression test).
        XCTAssertEqual(parsed.bgEvents.reduce(0) { $0 + $1.delta }, 0)
    }

    func testLaunchPhraseInAssistantTextIsNotABackgroundLaunch() {
        // Regression: the assistant merely *writing* the launch phrase (e.g. in
        // code or prose) must NOT register a phantom, never-completing background
        // task that suppresses all later narration.
        let jsonl = [
            line(["type": "assistant",
                  "message": ["stop_reason": "end_turn",
                              "content": [["type": "text",
                                           "text": "Here's a test: Command running in background with ID: abc123"]]]]),
        ].joined(separator: "\n") + "\n"
        let parsed = TranscriptParser.parse(data: Data(jsonl.utf8))
        XCTAssertEqual(parsed.bgEvents.reduce(0) { $0 + $1.delta }, 0,
                       "launch phrase in assistant text must not count as outstanding work")
    }

    func testLaunchInToolResultIsCounted() {
        let jsonl = [
            line(["type": "user",
                  "message": ["content": [["type": "tool_result",
                                           "content": "Command running in background with ID: xyz789. Output is being written to: /tmp/x.output. You will be notified when it completes."]]]]),
        ].joined(separator: "\n") + "\n"
        let parsed = TranscriptParser.parse(data: Data(jsonl.utf8))
        XCTAssertEqual(parsed.bgEvents.reduce(0) { $0 + $1.delta }, 1,
                       "a real launch ack in a tool_result counts as outstanding")
    }

    func testEchoedLaunchPhraseInToolResultIsNotCounted() {
        // A Read/grep tool_result that echoes the bare phrase (e.g. from code)
        // must NOT count — only the genuine ack (with "Output is being written to")
        // does.
        let jsonl = [
            line(["type": "user",
                  "message": ["content": [["type": "tool_result",
                                           "content": "42\t\"text\": \"Command running in background with ID: abc123\""]]]]),
        ].joined(separator: "\n") + "\n"
        let parsed = TranscriptParser.parse(data: Data(jsonl.utf8))
        XCTAssertEqual(parsed.bgEvents.reduce(0) { $0 + $1.delta }, 0,
                       "an echoed phrase without the ack corroboration must not count")
    }

    func testIncompleteTrailingLineExcluded() {
        let jsonl = line(["type": "assistant",
                          "message": ["stop_reason": "end_turn", "content": [["type": "text", "text": "complete"]]]])
            + "\n" + "{\"partial\": tru"  // no trailing newline
        let parsed = TranscriptParser.parse(data: Data(jsonl.utf8))
        XCTAssertEqual(parsed.turns.count, 1)
        XCTAssertEqual(parsed.completeBytes, jsonl.count - "{\"partial\": tru".count)
    }
}
