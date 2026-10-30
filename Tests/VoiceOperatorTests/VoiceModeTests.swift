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
        XCTAssertEqual(VoiceModeText.withoutTrigger("Clod, add a boss", trigger: "claude"), "Add a boss")
        XCTAssertEqual(VoiceModeText.withoutTrigger("clawed. add a boss", trigger: "claude"), "Add a boss")
        XCTAssertEqual(VoiceModeText.withoutTrigger("make it red", trigger: nil), "Make it red")
    }

    func testWhatTheUserSaidIsTheirOwnPrompt() {
        XCTAssertEqual(VoiceModeText.prompt(said: "Hi", interrupted: false, heard: nil), "Hi")
        XCTAssertEqual(VoiceModeText.prompt(said: "Stop", interrupted: true, heard: "…the jump"),
                       "Stop\n\n(I talked over your spoken reply. I'd heard up to “…the jump”.)")
        XCTAssertEqual(VoiceModeText.prompt(said: "", interrupted: true, heard: nil),
                       "(I talked over your spoken reply, but my words weren't caught. What were you saying?)")
        XCTAssertEqual(VoiceModeText.midTurn(said: "Also red", interrupted: false, heard: nil),
                       "[Hands-free] While you were working, the user said, by voice: “Also red”")
        XCTAssertEqual(VoiceModeText.tail("one two three", words: 2), "…two three")
    }

    func testHookInput() throws {
        let json = #"{"session_id":"s1","hook_event_name":"Stop","last_assistant_message":"Hi"}"#
        let input = try XCTUnwrap(VoiceModeHookInput(json: Data(json.utf8)))
        XCTAssertEqual(input.sessionID, "s1")
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
        XCTAssertEqual(mode.menuTitle, "Claude Hands-Free: game — say “Claude”")
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
        XCTAssertEqual(next, .message("Make it jump higher."))
        // A later turn's hook replaces this one; another session's is not this one.
        _ = await mode.turnEnded(input("s1", ["last_assistant_message": "Done."]))
        let replaced = await mode.next(sessionID: "s1", generation: 1, wait: .zero)
        XCTAssertEqual(replaced, .gone("superseded"))
        let other = await mode.next(sessionID: "s2", generation: 2, wait: .zero)
        XCTAssertEqual(other, .gone("not_attached"))
        let unattached = await mode.turnEnded(input("s2", ["last_assistant_message": "x"]))
        XCTAssertNil(unattached)
    }

    func testASonarPlaysWhileTheAgentWorks() async throws {
        let mode = make()
        mode.sonarTiming = (.milliseconds(10), .milliseconds(20))
        _ = try mode.attach(sessionID: "s1", claudePID: 100, cwd: "/g", trigger: nil, voice: nil)
        XCTAssertFalse(mode.setWorking(sessionID: "s2", true), "another session's turn")
        mode.handsFree(["type": "state", "phase": "listening", "pending": false])
        XCTAssertTrue(mode.setWorking(sessionID: "s1", true))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertGreaterThanOrEqual(cues.filter { $0 == .handsFreeSonar }.count, 2)
        // The user talking holds it off; the turn's end stops it.
        mode.handsFree(["type": "state", "phase": "hearing", "pending": false])
        try await Task.sleep(for: .milliseconds(30))
        let held = cues.count
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(cues.count, held)
        _ = await mode.turnEnded(input("s1", ["last_assistant_message": "Done."]))
        XCTAssertFalse(mode.isWorking)
    }

    func testWatchAnswersWhenTheWindowOpensOrCloses() async throws {
        let mode = make()
        _ = try mode.attach(sessionID: "s1", claudePID: 100, cwd: "/g", trigger: nil, voice: nil)
        let start = mode.version
        let unchanged = await mode.watch(since: start, wait: .milliseconds(150))
        XCTAssertEqual(unchanged["version"] as? Int, start, "nothing changed: it waits, then says so")
        mode.handsFree(["type": "state", "phase": "listening", "conversation": true, "pending": false])
        let open = await mode.watch(since: start, wait: .seconds(1))
        XCTAssertEqual(open["conversation"] as? Bool, true)
        XCTAssertGreaterThan(open["version"] as? Int ?? 0, start)
        // Speech outside the window without the trigger word: alarm bells, until a dictation starts.
        mode.handsFree(["type": "state", "phase": "listening", "conversation": false, "pending": false])
        mode.handsFree(["type": "cue", "name": "notWakeWord"])
        XCTAssertEqual(mode.status["missed_trigger"] as? Bool, true)
        mode.handsFree(["type": "cue", "name": "dictationStart"])
        mode.handsFree(["type": "state", "phase": "hearing", "conversation": false, "pending": false])
        XCTAssertEqual(mode.status["missed_trigger"] as? Bool, false)
        XCTAssertEqual(mode.status["transcribing"] as? Bool, true)
        mode.speechActivity(true)
        XCTAssertEqual(mode.status["speaking"] as? Bool, true)
        mode.detach(.asked)
        let off = await mode.watch(since: open["version"] as? Int ?? 0, wait: .seconds(1))
        XCTAssertEqual(off["attached"] as? Bool, false)
    }

    func testWordsMidTurnGoWithTheNextToolResult() throws {
        let mode = make()
        _ = try mode.attach(sessionID: "s1", claudePID: 100, cwd: "/g", trigger: nil, voice: nil)
        XCTAssertNil(mode.midTurn(input("s1")))
        XCTAssertFalse(mode.simulate(sessionID: "s2", "not for this session"), "a test's words never reach another session")
        XCTAssertTrue(mode.simulate(sessionID: "s1", "also make it red"))
        XCTAssertNil(mode.midTurn(input("s2")))
        let output = try XCTUnwrap(mode.midTurn(input("s1"))?["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(output["hookEventName"] as? String, "PostToolUse")
        XCTAssertEqual(output["additionalContext"] as? String,
                       "[Hands-free] While you were working, the user said, by voice: “Also make it red”")
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
        XCTAssertEqual(next, .message("No wait\n\n(I talked over your spoken reply. I'd heard up to “I raised”.)"))
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
                       "[Hands-free] Hands-free was turned off: Spaceterm took hands-free back. "
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
