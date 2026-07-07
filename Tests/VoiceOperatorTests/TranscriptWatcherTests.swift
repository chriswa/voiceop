import XCTest
@testable import VoiceOperator

final class TranscriptWatcherTests: XCTestCase {
    private func line(_ obj: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: obj, options: .withoutEscapingSlashes),
               as: UTF8.self)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watcher-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - outstandingCount

    func testLaunchWithoutCompletionIsOutstanding() {
        let launches = [BackgroundLaunch(id: "abc", kind: .bash, pos: 10,
                                         outputPath: "/tmp/abc.output", donePos: nil)]
        XCTAssertEqual(TranscriptWatcher.outstandingCount(launches, before: 100, resolved: []), 1)
    }

    func testResolvedIdUnblocksLaunchWithoutCompletion() {
        let launches = [BackgroundLaunch(id: "abc", kind: .bash, pos: 10,
                                         outputPath: "/tmp/abc.output", donePos: nil)]
        XCTAssertEqual(TranscriptWatcher.outstandingCount(launches, before: 100, resolved: ["abc"]), 0,
                       "a probed-dead task must stop muting even with no completion notification")
    }

    func testCompletionResolvesPositionally() {
        // A turn that ended mid-task stays muted on rescan even though the task
        // has since finished — the post-completion turn is the one to speak.
        let launches = [BackgroundLaunch(id: "abc", kind: .bash, pos: 10,
                                         outputPath: "/tmp/abc.output", donePos: 200)]
        XCTAssertEqual(TranscriptWatcher.outstandingCount(launches, before: 100, resolved: ["abc"]), 1,
                       "a recorded completion must resolve by position, not by probe")
        XCTAssertEqual(TranscriptWatcher.outstandingCount(launches, before: 300, resolved: []), 0)
    }

    func testLaunchAfterTurnDoesNotCount() {
        let launches = [BackgroundLaunch(id: "abc", kind: .bash, pos: 500,
                                         outputPath: "/tmp/abc.output", donePos: nil)]
        XCTAssertEqual(TranscriptWatcher.outstandingCount(launches, before: 100, resolved: []), 0)
    }

    // MARK: - isFileHeldOpen (bash-task probe)

    func testFileHeldOpenProbe() throws {
        let path = try tempDir().appendingPathComponent("task.output").path

        XCTAssertFalse(TranscriptWatcher.isFileHeldOpen(path), "missing file is not held")

        FileManager.default.createFile(atPath: path, contents: nil)
        XCTAssertFalse(TranscriptWatcher.isFileHeldOpen(path), "existing but unheld file is not held")

        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        XCTAssertTrue(TranscriptWatcher.isFileHeldOpen(path), "our own open write handle must be detected")
        try handle.close()
        XCTAssertFalse(TranscriptWatcher.isFileHeldOpen(path))
    }

    // MARK: - agentFinished (subagent-transcript probe)

    func testAgentFinishedReadsTranscriptTail() throws {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("agent-a1b2c3.jsonl").path

        XCTAssertTrue(TranscriptWatcher.agentFinished(subagentTranscript: path),
                      "a reaped (missing) transcript means the agent is not running")

        let working = [
            line(["type": "assistant", "message": ["stop_reason": "tool_use",
                                                   "content": [["type": "tool_use", "name": "Bash"]]]]),
            line(["type": "user", "message": ["content": [["type": "tool_result", "content": "ok"]]]]),
        ].joined(separator: "\n") + "\n"
        try working.write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertFalse(TranscriptWatcher.agentFinished(subagentTranscript: path),
                       "a tool_use tail means the agent is still working")

        let finished = working + line(["type": "assistant",
                                       "message": ["stop_reason": "end_turn",
                                                   "content": [["type": "text", "text": "DONE"]]]]) + "\n"
        try finished.write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertTrue(TranscriptWatcher.agentFinished(subagentTranscript: path),
                      "an end_turn tail means the agent has finished (until resumed)")
    }

    func testSubagentTranscriptPathDerivation() {
        let p = TranscriptWatcher.subagentTranscriptPath(
            transcriptPath: "/Users/x/.claude/projects/-Users-x-proj/SID-123.jsonl",
            sid: "SID-123", agentID: "a1b2c3")
        XCTAssertEqual(p, "/Users/x/.claude/projects/-Users-x-proj/SID-123/subagents/agent-a1b2c3.jsonl")
    }

    // MARK: - workflowStateFilePath (workflow probe)

    func testWorkflowStateFilePathDerivation() {
        let p = TranscriptWatcher.workflowStateFilePath(
            transcriptPath: "/Users/x/.claude/projects/-Users-x-proj/SID-123.jsonl",
            sid: "SID-123", runID: "wf_abc-123")
        XCTAssertEqual(p, "/Users/x/.claude/projects/-Users-x-proj/SID-123/workflows/wf_abc-123.json")
    }

    // MARK: - sessionHasLiveShells (monitor probe)

    func testSessionShellProbeSeesArgvMarker() throws {
        let sid = "test-\(UUID().uuidString)"
        XCTAssertFalse(TranscriptWatcher.sessionHasLiveShells(sid: sid))

        // Plant the marker in a live process's argv the same way the CLI does.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", ": CLAUDE_SESSION_ID=\(sid); sleep 3"]
        try p.run()
        defer { p.terminate(); p.waitUntilExit() }
        XCTAssertTrue(TranscriptWatcher.sessionHasLiveShells(sid: sid))
    }

    // MARK: - Orphaned-launch regression (the 2026-07-06 afplay incident)

    func testOrphanedBashLaunchDoesNotMuteForever() throws {
        // Real-world shape: a background task's ack is the ONLY trace it ever
        // leaves — killed tasks and idle-time completions get no notification.
        // Later human-prompted turns must not be muted once the task is dead.
        let dir = try tempDir()
        let outputPath = dir.appendingPathComponent("br1s5b5lj.output").path
        FileManager.default.createFile(atPath: outputPath, contents: nil)  // task dead: exists, unheld

        let ack = "Command running in background with ID: br1s5b5lj. Output is being written to: \(outputPath). You will be notified when it completes."
        let jsonl = [
            line(["type": "user", "message": ["content": "play the recording"]]),
            line(["type": "user", "message": ["content": [["type": "tool_result", "content": ack]]]]),
            line(["type": "user", "message": ["content": "why did it fail to transcribe?"]]),
            line(["type": "assistant",
                  "message": ["stop_reason": "end_turn",
                              "content": [["type": "text", "text": "here is the diagnosis"]]]]),
        ].joined(separator: "\n") + "\n"
        let parsed = TranscriptParser.parse(data: Data(jsonl.utf8))

        let orphan = try XCTUnwrap(parsed.launches.first)
        XCTAssertNil(orphan.donePos)
        let turnPos = try XCTUnwrap(parsed.turns.last?.pos)

        // Without the probe the turn is muted (the pre-fix behavior)…
        XCTAssertEqual(TranscriptWatcher.outstandingCount(parsed.launches, before: turnPos,
                                                          resolved: []), 1)
        // …and the probe unmutes it.
        XCTAssertFalse(TranscriptWatcher.isFileHeldOpen(orphan.outputPath ?? ""))
        XCTAssertEqual(TranscriptWatcher.outstandingCount(parsed.launches, before: turnPos,
                                                          resolved: [orphan.id]), 0)
    }
}
