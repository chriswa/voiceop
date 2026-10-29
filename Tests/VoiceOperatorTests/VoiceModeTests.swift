import XCTest
@testable import VoiceOperator

final class VoiceModeTextTests: XCTestCase {
    func testMarkdownIsMadeFitToHear() {
        let reply = """
        ## Done

        I made **two** changes:
        - raised the `jumpHeight` to 4
        - fixed [the bug](https://example.com/issue/1)

        ```swift
        let x = 1
        ```
        See https://example.com for more
        """
        XCTAssertEqual(VoiceModeText.spoken(reply),
                       "Done. I made two changes: raised the jumpHeight to 4. fixed the bug. (Code in the terminal.) See a link for more.")
    }

    func testTablesReadAsLists() {
        XCTAssertEqual(VoiceModeText.spoken("| a | b |\n|---|---|\n| 1 | 2 |"), "a, b. 1, 2.")
    }

    func testIdentifiersKeepTheirUnderscoresAndStars() {
        XCTAssertEqual(VoiceModeText.spoken("set max_speed to 2*3"), "set max_speed to 2*3.")
        XCTAssertEqual(VoiceModeText.spoken("it is *really* fast"), "it is really fast.")
    }

    func testTheTriggerWordComesOff() {
        XCTAssertEqual(VoiceModeText.withoutTrigger("Claude, make it jump higher.", trigger: "claude"), "Make it jump higher.")
        XCTAssertEqual(VoiceModeText.withoutTrigger("claude. what's next", trigger: "claude"), "What's next")
        XCTAssertEqual(VoiceModeText.withoutTrigger("Claudette is here", trigger: "claude"), "Claudette is here")
        XCTAssertEqual(VoiceModeText.withoutTrigger("Claude.", trigger: "claude"), "")
        XCTAssertEqual(VoiceModeText.withoutTrigger("make it red", trigger: nil), "Make it red")
    }

    func testMessagesSayHowTheyCame() {
        XCTAssertEqual(VoiceModeText.message(said: "Hi", whileWorking: false, interrupted: false, heard: nil),
                       "[Voice mode] The user said (by voice, transcribed on device): \"Hi\"")
        XCTAssertTrue(VoiceModeText.message(said: "Stop", whileWorking: false, interrupted: true, heard: "…the jump")
            .hasSuffix("which they heard up to: \"…the jump\"."))
        XCTAssertEqual(VoiceModeText.tail("one two three", words: 2), "…two three")
    }

    func testHookInput() throws {
        let json = #"{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"voice-mode stop"},"last_assistant_message":"Hi"}"#
        let input = try XCTUnwrap(VoiceModeHookInput(json: Data(json.utf8)))
        XCTAssertEqual(input.sessionID, "s1")
        XCTAssertEqual(input.command, "voice-mode stop")
        XCTAssertEqual(input.lastAssistantMessage, "Hi")
        XCTAssertNil(VoiceModeHookInput(json: Data("nope".utf8)))
    }

    func testLastAssistantTextFromTheTranscript() {
        let transcript = """
        {"type":"user","message":{"role":"user","content":"hi"}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"First."}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"All done."},{"type":"text","text":"Bye."}]}}
        {"type":"system","subtype":"stop_hook_summary"}
        """
        XCTAssertEqual(VoiceModeHookInput.lastAssistantText(transcript: transcript), "All done.\nBye.")
    }

    func testOnlyVoiceModeControlsGoAheadUnasked() {
        for ok in ["voice-mode stop", "voice-mode status", "voice-mode", " voice-mode stop\n",
                   "voice-mode say 'On it, give me a minute.'", "voice-mode say <<'EOF'\nI'll be a minute.\nEOF"] {
            XCTAssertTrue(VoiceModeCommandGuard.isVoiceControl(ok), ok)
        }
        for no in ["voice-mode stop; rm -rf ~", "voice-mode stop && ls", "voice-mode say \"$(whoami)\"",
                   "voice-mode say 'a' 'b'", "voice-mode say 'it's'", "voice-mode start", "voice-mode stop | sh",
                   "voice-mode say <<'EOF'\nx\nEOF\nrm -rf ~\nEOF", "voice-mode say <<EOF\n$(id)\nEOF", "ls"] {
            XCTAssertFalse(VoiceModeCommandGuard.isVoiceControl(no), no)
        }
    }

    func testFormBodies() {
        XCTAssertEqual(VoiceModeRoutes.form(Data("a=1&b=two%20words&c=x%2By&d".utf8)),
                       ["a": "1", "b": "two words", "c": "x+y", "d": ""])
    }
}

@MainActor
final class VoiceModeTests: XCTestCase {
    private var registered: [String] = []
    private var handsFree: [Bool] = []
    private var spoken: [String] = []
    private var cancelled: [String] = []
    private var cues: [SoundEffect] = []
    private var windows = 0
    private var saved: [VoiceMode.Attachment?] = []
    private var alive: Set<Int32> = [100, 200]
    private var refuse: HandsFreeService.Refusal?
    private var wasIncognito = false

    override func setUp() async throws {
        wasIncognito = Incognito.isOn
        Incognito.isOn = false
    }

    override func tearDown() async throws {
        Incognito.isOn = wasIncognito
    }

    private func make() -> VoiceMode {
        VoiceMode(deps: .init(
            registerHandsFree: { [unowned self] trigger, _ in
                if let refuse { return refuse }
                registered.append(trigger)
                return nil
            },
            setHandsFree: { [unowned self] in handsFree.append($0) },
            unregisterHandsFree: { [unowned self] in registered.append("-") },
            openConversation: { [unowned self] in windows += 1 },
            speak: { [unowned self] text, _ in spoken.append(text); return "job\(spoken.count)" },
            cancelSpeech: { [unowned self] id, _ in cancelled.append(id); return 9 },
            playCue: { [unowned self] in cues.append($0) },
            stopCue: { _ in },
            pidAlive: { [unowned self] in alive.contains($0) },
            save: { [unowned self] in saved.append($0) }))
    }

    private func input(_ session: String, _ fields: [String: Any] = [:]) -> VoiceModeHookInput {
        var o = fields
        o["session_id"] = session
        return VoiceModeHookInput(json: try! JSONSerialization.data(withJSONObject: o))!
    }

    func testAttachTakesHandsFreeAndSaves() throws {
        let mode = make()
        let a = try mode.attach(sessionID: "s1", claudePID: 100, cwd: "/Users/me/game", trigger: nil, voice: nil)
        XCTAssertEqual(a.trigger, "claude")
        XCTAssertEqual(a.project, "game")
        XCTAssertEqual(registered, ["-", "claude"])
        XCTAssertEqual(handsFree, [true])
        XCTAssertEqual(saved.last??.sessionID, "s1")
        XCTAssertEqual(mode.menuTitle, "Claude Voice Mode: game — say “Claude”")
    }

    func testIncognitoRefusesToAttach() {
        Incognito.isOn = true
        XCTAssertThrowsError(try make().attach(sessionID: "s1", claudePID: 1, cwd: "/", trigger: nil, voice: nil)) {
            guard case VoiceMode.AttachError.incognito = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertTrue(registered.isEmpty)
    }

    func testATakenTriggerWordIsRefused() {
        refuse = .init(error: "trigger_taken", detail: "\"control\" belongs to spaceterm")
        XCTAssertThrowsError(try make().attach(sessionID: "s1", claudePID: 1, cwd: "/", trigger: "control", voice: nil))
    }

    func testAConversation() async throws {
        let mode = make()
        _ = try mode.attach(sessionID: "s1", claudePID: 100, cwd: "/g", trigger: nil, voice: nil)
        // The agent's turn ends: its reply is spoken, and the hook waits under turn 1.
        let generation = await mode.turnEnded(input("s1", ["last_assistant_message": "**Hello.** What next?"]))
        XCTAssertEqual(generation, 1)
        XCTAssertEqual(spoken, ["Hello. What next?"])
        XCTAssertEqual(windows, 1, "the reply opens the conversation window: no trigger word needed to answer")
        let waiting = await mode.next(sessionID: "s1", generation: 1, wait: .zero)
        XCTAssertEqual(waiting, .nothingYet)
        // The user speaks.
        mode.handsFree(["type": "cue", "name": "dictationStart"])
        mode.handsFree(["type": "transcript", "text": "Claude, make it jump higher.", "trigger": "claude",
                        "interrupted": false, "reason": "mini", "shutdown": false])
        XCTAssertEqual(cues, [.handsFreeDictationStart])
        let next = await mode.next(sessionID: "s1", generation: 1, wait: .zero)
        XCTAssertEqual(next, .message("[Voice mode] The user said (by voice, transcribed on device): \"Make it jump higher.\""))
        // A later turn's hook replaces this one; another session's is not this one.
        _ = await mode.turnEnded(input("s1", ["last_assistant_message": "Done."]))
        let replaced = await mode.next(sessionID: "s1", generation: 1, wait: .zero)
        XCTAssertEqual(replaced, .gone("superseded"))
        let other = await mode.next(sessionID: "s2", generation: 2, wait: .zero)
        XCTAssertEqual(other, .gone("not_attached"))
        let unattached = await mode.turnEnded(input("s2", ["last_assistant_message": "x"]))
        XCTAssertNil(unattached)
    }

    func testWordsMidTurnGoWithTheNextToolResult() throws {
        let mode = make()
        _ = try mode.attach(sessionID: "s1", claudePID: 100, cwd: "/g", trigger: nil, voice: nil)
        XCTAssertNil(mode.midTurn(input("s1")))
        XCTAssertTrue(mode.simulate("also make it red"))
        XCTAssertNil(mode.midTurn(input("s2")))
        let output = try XCTUnwrap(mode.midTurn(input("s1"))?["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(output["hookEventName"] as? String, "PostToolUse")
        XCTAssertEqual(output["additionalContext"] as? String,
                       "[Voice mode] While you were working, the user said (by voice, transcribed on device): \"Also make it red\"")
        XCTAssertNil(mode.midTurn(input("s1")))
    }

    func testTalkingOverTheReplyStopsItAndSaysHowFarTheyGot() async throws {
        let mode = make()
        _ = try mode.attach(sessionID: "s1", claudePID: 100, cwd: "/g", trigger: nil, voice: nil)
        _ = await mode.turnEnded(input("s1", ["last_assistant_message": "I raised the jump and then some."]))
        mode.handsFree(["type": "cut-in", "msAgo": 300, "at": Date().timeIntervalSince1970 * 1000])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(cancelled, ["job1"])
        mode.handsFree(["type": "transcript", "text": "No wait", "trigger": NSNull(), "interrupted": true,
                        "reason": "silence", "shutdown": false])
        let next = await mode.next(sessionID: "s1", generation: 1, wait: .zero)
        XCTAssertEqual(next, .message("[Voice mode] The user said (by voice, transcribed on device): \"No wait\"\n"
                                      + "They talked over your spoken reply, which they heard up to: \"I raised\"."))
    }

    func testSpaceTermTakingItBackDetachesAndTellsTheSession() throws {
        let mode = make()
        _ = try mode.attach(sessionID: "s1", claudePID: 100, cwd: "/g", trigger: nil, voice: nil)
        mode.handsFree(["type": "session-ended", "why": "restarting"])
        XCTAssertNotNil(mode.attachment, "a restart of this app is not a detach")
        mode.handsFree(["type": "session-ended", "why": "taken", "by": "spaceterm"])
        XCTAssertNil(mode.attachment)
        XCTAssertNil(saved.last!)
        XCTAssertEqual(mode.promptSubmitted(input("s1")),
                       "[Voice mode] Voice mode was turned off: Spaceterm took hands-free back. "
                       + "Your replies are no longer spoken; answer in text as usual.")
        XCTAssertNil(mode.promptSubmitted(input("s1")), "said once")
    }

    func testAnotherSessionReplacesTheFirst() throws {
        let mode = make()
        _ = try mode.attach(sessionID: "s1", claudePID: 100, cwd: "/a", trigger: nil, voice: nil)
        _ = try mode.attach(sessionID: "s2", claudePID: 200, cwd: "/b", trigger: nil, voice: nil)
        XCTAssertEqual(mode.attachment?.sessionID, "s2")
        XCTAssertTrue(mode.promptSubmitted(input("s1"))?.contains("another Claude Code session (b)") == true)
    }

    func testClearFollowsTheProcessToItsNewSession() throws {
        let mode = make()
        _ = try mode.attach(sessionID: "s1", claudePID: 100, cwd: "/a", trigger: nil, voice: nil)
        mode.sessionEnded(input("s1", ["reason": "clear"]))
        XCTAssertNotNil(mode.attachment)
        var start = input("s9", ["source": "clear"])
        start.claudePID = 999
        XCTAssertNil(mode.sessionStarted(start), "another process's /clear")
        start.claudePID = 100
        XCTAssertEqual(mode.sessionStarted(start)?.sessionID, "s9")
        mode.sessionEnded(input("s9", ["reason": "prompt_input_exit"]))
        XCTAssertNil(mode.attachment)
        XCTAssertNil(mode.promptSubmitted(input("s9")), "the session ended itself: no notice")
    }

    func testOnlyItsOwnControlsArePreApproved() throws {
        let mode = make()
        let stop = input("s1", ["tool_name": "Bash", "tool_input": ["command": "voice-mode stop"]])
        XCTAssertNil(mode.preToolUse(stop), "not attached: asked as usual")
        _ = try mode.attach(sessionID: "s1", claudePID: 100, cwd: "/a", trigger: nil, voice: nil)
        XCTAssertNotNil(mode.preToolUse(stop))
        XCTAssertNil(mode.preToolUse(input("s1", ["tool_name": "Bash", "tool_input": ["command": "rm -rf /"]])))
    }

    func testRestoreSkipsAGoneSession() throws {
        let mode = make()
        let gone = VoiceMode.Attachment(sessionID: "s1", claudePID: 4242, cwd: "/a", trigger: "claude", voice: nil,
                                        attachedAt: Date(), generation: 7)
        mode.restore(gone)
        XCTAssertNil(mode.attachment)
        mode.restore(.init(sessionID: "s1", claudePID: 100, cwd: "/a", trigger: "claude", voice: nil,
                           attachedAt: Date(), generation: 7))
        XCTAssertEqual(mode.attachment?.generation, 7, "the hook waiting from before the restart is still the one")
    }

    func testShutdownByVoiceDetaches() throws {
        let mode = make()
        _ = try mode.attach(sessionID: "s1", claudePID: 100, cwd: "/a", trigger: nil, voice: nil)
        mode.handsFree(["type": "transcript", "text": "Let me turn this off", "interrupted": false,
                        "reason": "silence", "shutdown": true])
        XCTAssertNotNil(mode.attachment)
        mode.handsFree(["type": "session-ended", "why": "shutdown"])
        XCTAssertNil(mode.attachment)
        XCTAssertTrue(mode.promptSubmitted(input("s1"))?.contains("by voice") == true)
    }
}

/// Hands-free's Mac microphone is one client's at a time.
final class HandsFreeHandoverTests: XCTestCase {
    final class Recorder: HandsFreeClientLink, @unchecked Sendable {
        var messages: [[String: Any]] = []
        func send(_ message: [String: Any]) { messages.append(message) }
        func isPlaying(tailMs: Double) -> Bool { false }
        var ended: [String: Any]? { messages.last { $0["type"] as? String == "session-ended" } }
    }

    func testStartingOnTheMacTakesItFromWhoeverHadIt() {
        let wasIncognito = Incognito.isOn
        Incognito.isOn = false
        defer { Incognito.isOn = wasIncognito }
        let service = HandsFreeService()
        let spaceterm = Recorder(), claude = Recorder()
        XCTAssertNil(service.registerLocal("spaceterm", trigger: "control", link: spaceterm))
        XCTAssertNil(service.registerLocal("claude-code", trigger: "claude", link: claude))
        XCTAssertEqual(service.registerLocal("other", trigger: "Claude", link: Recorder())?.error, "trigger_taken")
        service.setLocal("spaceterm", on: true)
        service.queue.sync {}
        XCTAssertEqual(spaceterm.messages.first { $0["type"] as? String == "session" }?["source"] as? String, "mac")
        service.setLocal("claude-code", on: true)
        service.queue.sync {}
        XCTAssertEqual(spaceterm.ended?["why"] as? String, "taken")
        XCTAssertEqual(spaceterm.ended?["by"] as? String, "claude-code")
        XCTAssertNil(claude.ended)
        // And back.
        service.setLocal("spaceterm", on: true)
        service.queue.sync {}
        XCTAssertEqual(claude.ended?["why"] as? String, "taken")
        XCTAssertEqual(claude.ended?["by"] as? String, "spaceterm")
        XCTAssertEqual((service.snapshot()["sessions"] as? [[String: Any]])?.map { $0["client"] as? String }, ["spaceterm"])
        service.unregisterLocal("spaceterm")
        service.unregisterLocal("claude-code")
        service.queue.sync {}
        XCTAssertEqual(service.snapshot()["clients"] as? [String], [])
    }
}
