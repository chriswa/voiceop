import XCTest
@testable import VoiceOperator

final class HandsFreePhrasesTests: XCTestCase {
    func testTriggerIsTheFirstWordOnly() {
        let triggers = ["control", "jarvis"]
        XCTAssertEqual(HandsFreePhrases.trigger(in: "Control, what is", among: triggers), "control")
        XCTAssertEqual(HandsFreePhrases.trigger(in: "Control.", among: triggers), "control")
        XCTAssertEqual(HandsFreePhrases.trigger(in: "Jarvis, lights", among: triggers), "jarvis")
        XCTAssertNil(HandsFreePhrases.trigger(in: "It is under control", among: triggers))
        XCTAssertNil(HandsFreePhrases.trigger(in: "Controller", among: triggers))
        XCTAssertNil(HandsFreePhrases.trigger(in: "", among: triggers))
    }

    func testWordsInTheConversationWindow() {
        XCTAssertTrue(HandsFreePhrases.judge("Yes.", triggers: ["control"]).words)
        XCTAssertTrue(HandsFreePhrases.judge("No, tell Evan.", triggers: ["control"]).words)
        let control = HandsFreePhrases.judge("Control.", triggers: ["control"])
        XCTAssertTrue(control.words)
        XCTAssertEqual(control.trigger, "control")
    }

    func testFillerIsNotWords() {
        XCTAssertFalse(HandsFreePhrases.judge("Hmm.", triggers: []).words)
        XCTAssertFalse(HandsFreePhrases.judge("Uh, um", triggers: []).words)
        XCTAssertFalse(HandsFreePhrases.judge("", triggers: []).words)
    }

    func testIgnoredPhrasesComeOutWhole() {
        let ignored = ["thank you"]
        XCTAssertEqual(HandsFreePhrases.withoutIgnored(["thank", "you"], ignored: ignored), [])
        XCTAssertEqual(HandsFreePhrases.withoutIgnored(["thank", "kevin"], ignored: ignored), ["thank", "kevin"])
    }

    func testShutdownHoweverDictationWritesIt() {
        for text in ["Control, shutdown.", "Control shut down", "control. Shut down!", "Control — shut-down", "CONTROL, SHUTDOWN"] {
            XCTAssertTrue(HandsFreePhrases.isShutdown(text, trigger: "control"), text)
        }
        XCTAssertTrue(HandsFreePhrases.isShutdown("Shutdown.", trigger: "control"))
        XCTAssertTrue(HandsFreePhrases.isShutdown("shut down", trigger: "control"))
    }

    func testLetMeTurnThisOffWithOrWithoutTheTrigger() {
        for text in ["Let me turn this off.", "let me turn this off", "Lemme turn this off.", "Control, let me turn this off.", "Let me turn this off!"] {
            XCTAssertTrue(HandsFreePhrases.isShutdown(text, trigger: "control"), text)
        }
    }

    func testShutdownNeverInsideALongerRequest() {
        for text in ["Control, shut down the server.", "Did Kevin shut down the build?", "shutdown now",
                     "Control, shutdown, then tell Kevin", "", "Let me turn this off and on again.",
                     "let me turn this off for you", "So let me turn this off.", "Let me turn it off.",
                     "Control.", "Control, control."] {
            XCTAssertFalse(HandsFreePhrases.isShutdown(text, trigger: "control"), text)
        }
    }

    func testStopListeningWithOrWithoutTheTrigger() {
        for text in ["Stop listening.", "stop listening", "Control, stop listening.", "STOP LISTENING!", "Control — stop listening"] {
            XCTAssertTrue(HandsFreePhrases.isStopListening(text, trigger: "control"), text)
        }
        for text in ["Stop listening to Kevin.", "Tell Kevin to stop listening.", "Stop.", "Listening", "",
                     "Control, control, stop listening", "Don't stop listening"] {
            XCTAssertFalse(HandsFreePhrases.isStopListening(text, trigger: "control"), text)
        }
        XCTAssertFalse(HandsFreePhrases.isShutdown("Stop listening.", trigger: "control"))
    }

    func testWakeFreeShutdown() {
        XCTAssertEqual(HandsFreePhrases.wakeFreeShutdown("Let me turn this off."), .whole)
        XCTAssertEqual(HandsFreePhrases.wakeFreeShutdown("Lemme turn this off"), .whole)
        for heard in ["Let me", "Let me turn", "let me turn this", "Lemme turn"] {
            XCTAssertEqual(HandsFreePhrases.wakeFreeShutdown(heard), .start, heard)
        }
        for heard in ["", "Let", "Control.", "Shutdown.", "Control, let me turn this off.", "Let me think",
                      "Let us turn", "Let me turn this off now", "Please let me"] {
            XCTAssertNil(HandsFreePhrases.wakeFreeShutdown(heard), heard)
        }
    }
}
