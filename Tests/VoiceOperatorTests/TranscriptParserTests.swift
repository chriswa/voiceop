import XCTest
@testable import VoiceOperator

final class TranscriptParserTests: XCTestCase {
    // .withoutEscapingSlashes matches Claude Code's own writer: completion
    // notifications are matched on the raw line, where "</task-id>" must not
    // become "<\/task-id>".
    private func line(_ obj: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: obj, options: .withoutEscapingSlashes),
               as: UTF8.self)
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
        XCTAssertTrue(parsed.launches.isEmpty)
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
        XCTAssertTrue(parsed.launches.isEmpty,
                      "launch phrase in assistant text must not count as outstanding work")
    }

    func testLaunchInToolResultIsCountedWithOutputPath() {
        let jsonl = [
            line(["type": "user",
                  "message": ["content": [["type": "tool_result",
                                           "content": "Command running in background with ID: xyz789. Output is being written to: /tmp/x.output. You will be notified when it completes."]]]]),
        ].joined(separator: "\n") + "\n"
        let parsed = TranscriptParser.parse(data: Data(jsonl.utf8))
        XCTAssertEqual(parsed.launches.count, 1,
                       "a real launch ack in a tool_result counts as outstanding")
        XCTAssertEqual(parsed.launches.first?.id, "xyz789")
        XCTAssertEqual(parsed.launches.first?.outputPath, "/tmp/x.output",
                       "the output path must be captured so the watcher can probe liveness")
        XCTAssertNil(parsed.launches.first?.donePos)
    }

    func testEchoedLaunchPhraseInToolResultIsNotCounted() {
        // A Read/grep tool_result that echoes the bare phrase (e.g. from code)
        // must NOT count — only the genuine ack (id + output path in one
        // sentence pair) does.
        let jsonl = [
            line(["type": "user",
                  "message": ["content": [["type": "tool_result",
                                           "content": "42\t\"text\": \"Command running in background with ID: abc123\""]]]]),
        ].joined(separator: "\n") + "\n"
        let parsed = TranscriptParser.parse(data: Data(jsonl.utf8))
        XCTAssertTrue(parsed.launches.isEmpty,
                      "an echoed phrase without the ack corroboration must not count")
    }

    func testCompletionNotificationResolvesLaunch() {
        let ack = "Command running in background with ID: xyz789. Output is being written to: /tmp/x.output. You will be notified when it completes."
        let notification = "<task-notification><task-id>xyz789</task-id><status>completed</status></task-notification>"
        let jsonl = [
            line(["type": "user", "message": ["content": [["type": "tool_result", "content": ack]]]]),
            line(["type": "user", "message": ["content": notification]]),
        ].joined(separator: "\n") + "\n"
        let parsed = TranscriptParser.parse(data: Data(jsonl.utf8))
        XCTAssertEqual(parsed.launches.count, 1)
        XCTAssertNotNil(parsed.launches.first?.donePos)
    }

    func testMonitorLaunchIsTracked() {
        // Ack text captured live 2026-07-06 (CC 2.1.201).
        let ack = "Monitor started (task bi2vnqpk7, timeout 240000ms). You will be notified on each event. Keep working — do not poll or sleep."
        let event = "<task-notification>\n<task-id>bi2vnqpk7</task-id>\n<summary>Monitor event: \"x\"</summary>\n<event>monitor-armed</event>\n</task-notification>"
        let done = "<task-notification>\n<task-id>bi2vnqpk7</task-id>\n<status>completed</status>\n<summary>Monitor \"x\" stream ended</summary>\n</task-notification>"
        let launchOnly = line(["type": "user", "message": ["content": [["type": "tool_result", "content": ack]]]])

        var parsed = TranscriptParser.parse(data: Data((launchOnly + "\n").utf8))
        XCTAssertEqual(parsed.launches.first?.kind, .monitor)
        XCTAssertEqual(parsed.launches.first?.id, "bi2vnqpk7")

        // A persistent monitor's per-EVENT notification has no <status> and
        // must NOT resolve the launch; the completion notification does.
        let withEvent = launchOnly + "\n" + line(["type": "user", "message": ["content": event]]) + "\n"
        parsed = TranscriptParser.parse(data: Data(withEvent.utf8))
        XCTAssertNil(parsed.launches.first?.donePos,
                     "an event notification must not complete a monitor")

        let withDone = withEvent + line(["type": "user", "message": ["content": done]]) + "\n"
        parsed = TranscriptParser.parse(data: Data(withDone.utf8))
        XCTAssertNotNil(parsed.launches.first?.donePos)
    }

    func testWorkflowLaunchIsTracked() {
        // Ack text captured live 2026-07-06 (CC 2.1.201).
        let ack = "Workflow launched in background. Task ID: wu388o565\nSummary: Minimal workflow\nRun ID: wf_4f28bf27-806"
        let jsonl = [
            line(["type": "user", "message": ["content": [["type": "tool_result", "content": ack]]]]),
        ].joined(separator: "\n") + "\n"
        let parsed = TranscriptParser.parse(data: Data(jsonl.utf8))
        XCTAssertEqual(parsed.launches.first?.kind, .workflow)
        XCTAssertEqual(parsed.launches.first?.id, "wu388o565",
                       "the task id (w…), not the run id (wf_…), is what notifications carry")
        XCTAssertEqual(parsed.launches.first?.runID, "wf_4f28bf27-806",
                       "the run id keys the on-disk state file the watcher probes")
    }

    func testWorkflowAckWithoutRunIDIsNotRegistered() {
        // An echoed fragment carrying only the task-id line must not register a
        // launch the watcher could never resolve.
        let jsonl = [
            line(["type": "user",
                  "message": ["content": [["type": "tool_result",
                                           "content": "Workflow launched in background. Task ID: wu388o565"]]]]),
        ].joined(separator: "\n") + "\n"
        XCTAssertTrue(TranscriptParser.parse(data: Data(jsonl.utf8)).launches.isEmpty)
    }

    func testSendMessageResumptionReopensAgentLedger() {
        // Verified live (CC 2.1.202, lib-agent settle work): a successful
        // SendMessage to a COMPLETED background agent re-activates it with NO
        // new launch ack. The success tool_result must create a fresh ledger
        // entry that only the id's NEXT completion resolves.
        let agentAck = "Async agent launched successfully (agentId: a936e373ab2cbf4e2)"
        let done1 = "<task-notification><task-id>a936e373ab2cbf4e2</task-id><status>completed</status></task-notification>"
        let resume = "{\"success\": true, \"message\": \"Agent \\\"a936e373ab2cbf4e2\\\" was stopped (completed); resumed it in the background with your message. Output: /tmp/tasks/a936e373ab2cbf4e2.output\"}"
        let done2 = "<task-notification><task-id>a936e373ab2cbf4e2</task-id><status>completed</status></task-notification>"

        var events = [
            line(["type": "user", "message": ["content": [["type": "tool_result", "content": agentAck]]]]),
            line(["type": "user", "message": ["content": done1]]),
            line(["type": "user", "message": ["content": [["type": "tool_result", "content": resume]]]]),
        ]
        var parsed = TranscriptParser.parse(data: Data((events.joined(separator: "\n") + "\n").utf8))
        XCTAssertEqual(parsed.launches.count, 2, "the resumption is a fresh entry for the same id")
        XCTAssertNotNil(parsed.launches[0].donePos, "the original run resolved")
        XCTAssertNil(parsed.launches[1].donePos,
                     "the resumed run must NOT be resolved by its previous completion")
        XCTAssertEqual(parsed.launches[1].kind, .agent)

        events.append(line(["type": "user", "message": ["content": done2]]))
        parsed = TranscriptParser.parse(data: Data((events.joined(separator: "\n") + "\n").utf8))
        XCTAssertNotNil(parsed.launches[1].donePos, "the id's next completion resolves the resumed run")
    }

    func testSendMessageResumptionMatchesLivePayloadFormat() {
        // Exact tool_result captured live 2026-07-06 (CC 2.1.201) — note the
        // structured resumedAgentId field and the "had no active task" phrase
        // variant. Both this and the "was stopped (completed)" variant must
        // register.
        let live = "{\"success\":true,\"message\":\"Agent \\\"af10cb0b0335ef809\\\" had no active task; resumed from transcript in the background with your message. You'll be notified when it finishes. Output: /private/tmp/claude-501/x/tasks/af10cb0b0335ef809.output\",\"resumedAgentId\":\"af10cb0b0335ef809\",\"pin\":{\"id\":\"af10cb0b0335ef809\",\"name\":\"af10cb0b0335ef809\",\"ref\":\"853527\"}}"
        let jsonl = line(["type": "user",
                          "message": ["content": [["type": "tool_result", "content": live]]]]) + "\n"
        let parsed = TranscriptParser.parse(data: Data(jsonl.utf8))
        XCTAssertEqual(parsed.launches.count, 1)
        XCTAssertEqual(parsed.launches.first?.id, "af10cb0b0335ef809")
        XCTAssertEqual(parsed.launches.first?.kind, .agent)
    }

    func testFailedSendMessageDoesNotReopen() {
        let agentAck = "Async agent launched successfully (agentId: a936e373ab2cbf4e2)"
        let failed = "{\"success\": false, \"message\": \"Agent \\\"a936e373ab2cbf4e2\\\" not found\"}"
        let jsonl = [
            line(["type": "user", "message": ["content": [["type": "tool_result", "content": agentAck]]]]),
            line(["type": "user", "message": ["content": [["type": "tool_result", "content": failed]]]]),
        ].joined(separator: "\n") + "\n"
        XCTAssertEqual(TranscriptParser.parse(data: Data(jsonl.utf8)).launches.count, 1)
    }

    func testStrayCompletionBeforeLaunchDoesNotResolveIt() {
        // An echoed notification that lands BEFORE the launch (transcript
        // dumps) must not pre-resolve it — pairing is strictly launch-then-done.
        let stray = "<task-notification><task-id>xyz789</task-id><status>completed</status></task-notification>"
        let ack = "Command running in background with ID: xyz789. Output is being written to: /tmp/x.output. You will be notified when it completes."
        let jsonl = [
            line(["type": "user", "message": ["content": stray]]),
            line(["type": "user", "message": ["content": [["type": "tool_result", "content": ack]]]]),
        ].joined(separator: "\n") + "\n"
        let parsed = TranscriptParser.parse(data: Data(jsonl.utf8))
        XCTAssertEqual(parsed.launches.count, 1)
        XCTAssertNil(parsed.launches.first?.donePos)
    }

    func testQueuedNotificationMarksLaunchQueuedNotDelivered() {
        // Regression (2026-07-07 false summary): while the session is mid-turn,
        // the harness enqueues the FULL notification text as a queue-operation
        // event, then delivers it as a user event once the turn ends. The
        // enqueue must not count as the delivery — a turn ending in between
        // only ended to await the delivery, and the session WILL be re-invoked.
        let ack = "Async agent launched successfully (agentId: a78deaffbad9fd46f)"
        let notification = "<task-notification>\n<task-id>a78deaffbad9fd46f</task-id>\n<status>completed</status>\n</task-notification>"
        var events = [
            line(["type": "user", "message": ["content": [["type": "tool_result", "content": ack]]]]),
            line(["type": "queue-operation", "operation": "enqueue", "content": notification]),
        ]
        var parsed = TranscriptParser.parse(data: Data((events.joined(separator: "\n") + "\n").utf8))
        XCTAssertEqual(parsed.launches.count, 1)
        XCTAssertNil(parsed.launches.first?.donePos,
                     "an enqueued notification is not a delivery")
        XCTAssertNotNil(parsed.launches.first?.queuedPos)

        events.append(line(["type": "queue-operation", "operation": "dequeue"]))
        events.append(line(["type": "user", "message": ["content": notification]]))
        parsed = TranscriptParser.parse(data: Data((events.joined(separator: "\n") + "\n").utf8))
        XCTAssertNotNil(parsed.launches.first?.donePos,
                        "the user event is the delivery, resolving positionally")
    }

    func testQueuedMonitorEventWithoutStatusIsNotQueuedCompletion() {
        // A persistent monitor's per-EVENT notifications also pass through the
        // queue but carry no <status>; they must not mark the launch queued.
        let ack = "Monitor started (task bi2vnqpk7, timeout 240000ms). You will be notified on each event."
        let event = "<task-notification>\n<task-id>bi2vnqpk7</task-id>\n<summary>Monitor event</summary>\n</task-notification>"
        let jsonl = [
            line(["type": "user", "message": ["content": [["type": "tool_result", "content": ack]]]]),
            line(["type": "queue-operation", "operation": "enqueue", "content": event]),
        ].joined(separator: "\n") + "\n"
        let parsed = TranscriptParser.parse(data: Data(jsonl.utf8))
        XCTAssertNil(parsed.launches.first?.queuedPos)
        XCTAssertNil(parsed.launches.first?.donePos)
    }

    func testAgentLaunchHasNoOutputPath() {
        let jsonl = [
            line(["type": "user",
                  "message": ["content": [["type": "tool_result",
                                           "content": "Async agent launched successfully (agentId: abcdef123)"]]]]),
        ].joined(separator: "\n") + "\n"
        let parsed = TranscriptParser.parse(data: Data(jsonl.utf8))
        XCTAssertEqual(parsed.launches.count, 1)
        XCTAssertEqual(parsed.launches.first?.id, "abcdef123")
        XCTAssertNil(parsed.launches.first?.outputPath,
                     "agents have no probeable file — they resolve via notifications only")
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
