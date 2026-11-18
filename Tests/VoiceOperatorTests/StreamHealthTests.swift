import XCTest
@testable import VoiceOperator

final class StreamHealthTests: XCTestCase {
    func testOnlyDegradedShowsAWarning() {
        XCTAssertNil(StreamHealth.unverified.menuWarning)
        XCTAssertNil(StreamHealth.streaming.menuWarning)
        XCTAssertFalse(StreamHealth.streaming.isDegraded)
        XCTAssertTrue(StreamHealth.degraded(reason: "the Parakeet model is still loading").isDegraded)
    }

    func testWarningNamesTheReason() {
        let health = StreamHealth.degraded(reason: "the Parakeet model is still loading")
        XCTAssertEqual(health.menuWarning, "⚠︎ Parakeet is failing: the Parakeet model is still loading")
        XCTAssertTrue(health.logLine.contains("Parakeet dictations are failing"), health.logLine)
    }

    func testWireNamesAndReasonForStatusEndpoint() {
        XCTAssertEqual(StreamHealth.unverified.wireName, "unverified")
        XCTAssertEqual(StreamHealth.streaming.wireName, "streaming")
        XCTAssertEqual(StreamHealth.degraded(reason: "x").wireName, "degraded")
        XCTAssertEqual(StreamHealth.degraded(reason: "x").reason, "x")
        XCTAssertNil(StreamHealth.streaming.reason)
    }
}
