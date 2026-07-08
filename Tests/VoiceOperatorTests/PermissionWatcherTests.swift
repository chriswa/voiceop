import XCTest
@testable import VoiceOperator

final class PermissionWatcherTests: XCTestCase {
    private func spool(_ obj: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["receivedAt": 1, "payload": obj],
                                    options: .withoutEscapingSlashes)
    }

    func testParsesQuestionIncludingOptions() {
        let data = spool([
            "hook_event_name": "PermissionRequest",
            "tool_name": "AskUserQuestion",
            "session_id": "sid-123",
            "transcript_path": "/tmp/sid-123.jsonl",
            "tool_input": ["questions": [
                ["question": "Persist to disk or memory?", "header": "Persistence",
                 "options": [["label": "Disk", "description": "survives restart"],
                             ["label": "Memory", "description": "lost on restart"]]],
            ]],
        ])
        let event = PermissionWatcher.parse(eventData: data)
        XCTAssertEqual(event?.toolName, "AskUserQuestion")
        XCTAssertEqual(event?.sessionID, "sid-123")
        XCTAssertEqual(event?.transcriptPath, "/tmp/sid-123.jsonl")
        let content = event?.content ?? ""
        XCTAssertTrue(content.contains("Persist to disk or memory?"), "the question must be present")
        // Options are now included (label + description) for the summarizer to convey.
        XCTAssertTrue(content.contains("Disk — survives restart"), "options must be included")
        XCTAssertTrue(content.contains("Memory — lost on restart"))
    }

    func testQuestionWithoutOptionsIsJustTheQuestion() {
        let data = spool(["tool_name": "AskUserQuestion",
                          "tool_input": ["questions": [["question": "Ship it?"]]]])
        XCTAssertEqual(PermissionWatcher.parse(eventData: data)?.content, "Ship it?")
    }

    func testJoinsMultipleQuestions() {
        let data = spool([
            "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "A?"], ["question": "B?"]]],
        ])
        XCTAssertEqual(PermissionWatcher.parse(eventData: data)?.content, "A?\n\nB?")
    }

    func testParsesPlanAndCaps() {
        let plan = String(repeating: "x", count: 9000)
        let data = spool(["tool_name": "ExitPlanMode", "tool_input": ["plan": plan]])
        let event = PermissionWatcher.parse(eventData: data, planCap: 6000)
        XCTAssertEqual(event?.toolName, "ExitPlanMode")
        XCTAssertEqual(event?.content.count, 6000, "the plan must be capped")
    }

    func testIgnoresOtherPermissionTools() {
        let data = spool(["tool_name": "Bash", "tool_input": ["command": "rm -rf /"]])
        XCTAssertNil(PermissionWatcher.parse(eventData: data),
                     "non question/plan permission prompts are not announced")
    }

    func testIgnoresMalformedOrEmpty() {
        XCTAssertNil(PermissionWatcher.parse(eventData: Data("not json".utf8)))
        XCTAssertNil(PermissionWatcher.parse(eventData: spool([
            "tool_name": "AskUserQuestion", "tool_input": ["questions": []],
        ])), "a question with no prompts is not narratable")
    }

    func testContextSinceLastEndTurnTakesLeadUpAfterLastEndTurn() {
        let turns = [
            Turn(role: "user", text: "do the thing", pos: 0, stopReason: nil),
            Turn(role: "assistant", text: "done earlier", pos: 1, stopReason: "end_turn"),
            Turn(role: "user", text: "now ask me", pos: 2, stopReason: nil),
            Turn(role: "assistant", text: "let me look", pos: 3, stopReason: "tool_use"),
            Turn(role: "assistant", text: "here's what I found", pos: 4, stopReason: "tool_use"),
        ]
        let ctx = PermissionWatcher.contextSinceLastEndTurn(turns)
        XCTAssertEqual(ctx.map(\.text), ["now ask me", "let me look", "here's what I found"],
                       "context is everything after the last end_turn — the turn's lead-up")
    }

    func testContextWithNoEndTurnReturnsAll() {
        let turns = [
            Turn(role: "user", text: "u", pos: 0, stopReason: nil),
            Turn(role: "assistant", text: "a", pos: 1, stopReason: "tool_use"),
        ]
        XCTAssertEqual(PermissionWatcher.contextSinceLastEndTurn(turns).count, 2)
        XCTAssertEqual(PermissionWatcher.contextSinceLastEndTurn([]).count, 0)
    }
}
