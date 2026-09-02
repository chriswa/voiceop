import Foundation
import XCTest
@testable import VoiceOperator

/// Drives a `RestartCoordinator` with a hand-cranked clock: `busy` stands in for
/// the arbiter's dictation flag, and every scheduled closure is captured so the
/// test decides when "the cue has finished playing".
@MainActor
final class RestartCoordinatorTests: XCTestCase {
    private var busy = false
    private var cuesPlayed = 0
    private var performed = 0
    private var scheduled: [(delay: TimeInterval, work: @MainActor () -> Void)] = []

    private func makeCoordinator() -> RestartCoordinator {
        RestartCoordinator(
            isBusy: { [unowned self] in busy },
            playCue: { [unowned self] in cuesPlayed += 1; return 0.5 },
            perform: { [unowned self] in performed += 1 },
            schedule: { [unowned self] delay, work in scheduled.append((delay, work)) })
    }

    /// Run everything scheduled so far, as if the delays had elapsed.
    private func elapse() {
        let due = scheduled; scheduled = []
        for item in due { item.work() }
    }

    func testIdleRequestPlaysCueThenRestarts() {
        let c = makeCoordinator()
        XCTAssertEqual(c.request(source: .http), .restarting)
        XCTAssertEqual(cuesPlayed, 1)
        XCTAssertEqual(performed, 0, "the cue must finish before the process goes away")
        XCTAssertEqual(scheduled.count, 1)
        XCTAssertEqual(scheduled[0].delay, 0.5 + RestartCoordinator.cueMargin, accuracy: 0.001)
        elapse()
        XCTAssertEqual(performed, 1)
    }

    func testRequestDuringDictationWaitsForItToEnd() {
        busy = true
        let c = makeCoordinator()
        guard case .pending(let source, _) = c.request(source: .http) else { return XCTFail("expected pending") }
        XCTAssertEqual(source, .http)
        XCTAssertEqual(cuesPlayed, 0)
        XCTAssertTrue(scheduled.isEmpty)

        c.attempt()   // a spurious poke while still dictating changes nothing
        XCTAssertEqual(cuesPlayed, 0)

        busy = false
        c.attempt()   // the dictation ended
        XCTAssertEqual(c.state, .restarting)
        XCTAssertEqual(cuesPlayed, 1)
        elapse()
        XCTAssertEqual(performed, 1)
    }

    func testRepeatRequestsAreIdempotent() {
        busy = true
        let c = makeCoordinator()
        let first = c.request(source: .http)
        let second = c.request(source: .menu)
        XCTAssertEqual(first, second, "a second request must not reset the pending one")

        busy = false
        c.attempt()
        XCTAssertEqual(c.request(source: .http), .restarting)
        XCTAssertEqual(cuesPlayed, 1, "a request while restarting must not replay the cue")
        elapse()
        XCTAssertEqual(performed, 1)
    }

    func testDictationStartedDuringCueDefersTheRestart() {
        let c = makeCoordinator()
        c.request(source: .menu)
        busy = true          // trigger key pressed while the cue was sounding
        elapse()
        XCTAssertEqual(performed, 0)
        guard case .pending = c.state else { return XCTFail("expected to fall back to pending") }

        busy = false
        c.attempt()
        XCTAssertEqual(cuesPlayed, 2)
        elapse()
        XCTAssertEqual(performed, 1)
    }
}
