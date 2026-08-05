import XCTest
@testable import VoiceOperator

/// The timing rules for deciding paste vs. command, which the user experiences as
/// "does Ctrl+Fn work when I hit Fn a few milliseconds early".
@MainActor
final class DictationModeDecisionTests: XCTestCase {
    func testControlHeldAtKeyDownIsCommandImmediately() {
        let decision = DictationModeDecision(controlAlreadyDown: true)
        XCTAssertTrue(decision.isResolved)
        XCTAssertEqual(decision.mode, .command)
    }

    func testControlWithinTheWindowPromotesToCommand() {
        let decision = DictationModeDecision(controlAlreadyDown: false)
        XCTAssertFalse(decision.isResolved)
        XCTAssertEqual(decision.mode, .paste, "provisional until resolved")

        decision.noteControlPressed()
        XCTAssertTrue(decision.isResolved, "a chord resolves as soon as its second half lands")
        XCTAssertEqual(decision.mode, .command)
    }

    func testControlAfterTheWindowIsIgnored() {
        let decision = DictationModeDecision(controlAlreadyDown: false)
        XCTAssertEqual(decision.resolve(), .paste)

        // Control pressed later belongs to the app being dictated into.
        decision.noteControlPressed()
        XCTAssertEqual(decision.mode, .paste)
    }

    func testWindowClosesOnItsOwnAsPaste() {
        let decision = DictationModeDecision(controlAlreadyDown: false)
        let resolved = expectation(description: "mode resolved")
        decision.whenResolved { mode in
            XCTAssertEqual(mode, .paste)
            resolved.fulfill()
        }
        wait(for: [resolved], timeout: DictationModeDecision.window + 1)
        XCTAssertTrue(decision.isResolved)
    }

    func testObserversRunOnceWithTheFinalMode() {
        let decision = DictationModeDecision(controlAlreadyDown: false)
        var seen: [DictationMode] = []
        decision.whenResolved { seen.append($0) }
        decision.whenResolved { seen.append($0) }
        XCTAssertTrue(seen.isEmpty, "nothing fires while the mode is still open")

        decision.noteControlPressed()
        XCTAssertEqual(seen, [.command, .command])

        // Every later resolve is a no-op, so no cue or tint can be repeated.
        decision.resolve()
        decision.noteControlPressed()
        XCTAssertEqual(seen, [.command, .command])
    }

    func testObserverRegisteredAfterResolutionRunsImmediately() {
        let decision = DictationModeDecision(controlAlreadyDown: true)
        var seen: DictationMode?
        decision.whenResolved { seen = $0 }
        XCTAssertEqual(seen, .command, "a late observer must not miss the answer")
    }

    /// A regression guard on the window itself. The start cue waits for the mode,
    /// and the microphone has never gone live sooner than ~175 ms after key-down,
    /// so at 200 ms the window is all but free. Growing it trades real
    /// "safe to talk" latency for chord tolerance — a deliberate decision, not
    /// something to widen in passing.
    func testWindowStaysWithinAnImperceptibleCueDelay() {
        XCTAssertLessThanOrEqual(DictationModeDecision.window, 0.2)
    }
}
