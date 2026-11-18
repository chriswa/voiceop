import XCTest
@testable import VoiceOperator

final class TranscriptionLegTests: XCTestCase {
    func testAudioBeforeTheSessionOpensArrivesFirstAndInOrder() async throws {
        let gate = Gate()
        let session = FakeSession(result: .success("text"))
        let leg = TranscriptionLeg(provider: FakeProvider(session: session, openGate: gate),
                                   target: DictationTarget(), trace: DictationTrace("test"))
        leg.append(Data([1, 2]))
        leg.append(Data([3, 4]))
        await gate.open()
        await Self.until { await session.byteCounts.sent == 4 }
        leg.append(Data([5, 6]))
        let outcome = try await leg.finish(tail: Data([7, 8]), openGrace: .seconds(2), clip: { XCTFail("no fallback"); return Data() })
        XCTAssertEqual(outcome.text, "text")
        XCTAssertNil(outcome.liveFailure)
        let received = await session.received
        XCTAssertEqual(received, Data([1, 2, 3, 4, 5, 6, 7, 8]))
    }

    func testUnsentAudioRidesWithTheCommitWhenTheSessionOpensLate() async throws {
        let session = FakeSession(result: .success("late"))
        let gate = Gate()
        let leg = TranscriptionLeg(provider: FakeProvider(session: session, openGate: gate),
                                   target: DictationTarget(), trace: DictationTrace("test"))
        leg.append(Data([1, 2]))
        Task { try await Task.sleep(for: .milliseconds(50)); await gate.open() }
        let outcome = try await leg.finish(tail: Data([3]), openGrace: .seconds(2), clip: { Data() })
        XCTAssertEqual(outcome.text, "late")
        let received = await session.received
        XCTAssertEqual(received, Data([1, 2, 3]))
    }

    func testOpenFailureIsReportedAtOnceAndFallsBackToTheClip() async throws {
        let reported = expectation(description: "open failure reported")
        let leg = TranscriptionLeg(provider: FakeProvider(openError: FakeError(message: "model missing"),
                                                          fallback: { clip in "fallback \(clip.count)" }),
                                   target: DictationTarget(), trace: DictationTrace("test"),
                                   onOpenFailed: { reason in
            XCTAssertEqual(reason, "model missing")
            reported.fulfill()
        })
        await fulfillment(of: [reported], timeout: 1)
        XCTAssertTrue(leg.isBroken)
        let outcome = try await leg.finish(tail: Data(), openGrace: .seconds(2), clip: { Data(count: 3) })
        XCTAssertEqual(outcome.text, "fallback 3")
        XCTAssertEqual(outcome.liveFailure, "model missing")
    }

    func testAnOpenThatOutlastsTheGraceFallsBack() async throws {
        let leg = TranscriptionLeg(provider: FakeProvider(openGate: Gate(), fallback: { _ in "clip" }),
                                   target: DictationTarget(), trace: DictationTrace("test"))
        let outcome = try await leg.finish(tail: Data(), openGrace: .milliseconds(50), clip: { Data() })
        XCTAssertEqual(outcome.text, "clip")
        XCTAssertEqual(outcome.liveFailure, "session did not open in time")
    }

    func testAFailedCommitReportsItsOwnFailureWithoutARetry() async {
        let session = FakeSession(result: .failure(FakeError(message: "model failed")))
        let leg = TranscriptionLeg(provider: FakeProvider(session: session,
                                                          fallback: { _ in XCTFail("no retry"); return "" }),
                                   target: DictationTarget(), trace: DictationTrace("test"))
        do {
            _ = try await leg.finish(tail: Data([1]), openGrace: .seconds(2), clip: { Data() })
            XCTFail("expected the failure")
        } catch {
            XCTAssertEqual(TranscriptionFailure.message(for: error), "model failed")
        }
    }

    func testCancelReleasesASessionThatOpensAfterwards() async throws {
        let gate = Gate()
        let session = FakeSession(result: .success("unused"))
        let leg = TranscriptionLeg(provider: FakeProvider(session: session, openGate: gate),
                                   target: DictationTarget(), trace: DictationTrace("test"))
        leg.cancel()
        await gate.open()
        await session.waitUntilCancelled()
        leg.append(Data([1]))
        let sent = await session.byteCounts.sent
        XCTAssertEqual(sent, 0)
    }

    private static func until(_ condition: @Sendable () async -> Bool) async {
        for _ in 0 ..< 200 where await !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }
}
