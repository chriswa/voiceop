import XCTest
@testable import VoiceOperator

final class StreamHealthTests: XCTestCase {
    func testOnlyDegradedShowsAWarning() {
        XCTAssertNil(StreamHealth.unverified.menuWarning)
        XCTAssertNil(StreamHealth.streaming.menuWarning)
        XCTAssertFalse(StreamHealth.streaming.isDegraded)
        XCTAssertTrue(StreamHealth.degraded(reason: "network timeout").isDegraded)
    }

    func testWarningNamesTheReason() {
        let warning = StreamHealth.degraded(reason: "network timeout").menuWarning
        XCTAssertEqual(warning, "⚠︎ Dictation is slow: live stream unavailable (network timeout)")
    }

    func testMissingKeyGetsAFixHint() {
        let warning = StreamHealth.degraded(reason: TranscriberError.noBasetenKey.userMessage).menuWarning ?? ""
        XCTAssertTrue(warning.contains("no Baseten key"), warning)
        XCTAssertTrue(warning.contains("baseten-key"), warning)
    }

    func testWireNamesAndReasonForStatusEndpoint() {
        XCTAssertEqual(StreamHealth.unverified.wireName, "unverified")
        XCTAssertEqual(StreamHealth.streaming.wireName, "streaming")
        XCTAssertEqual(StreamHealth.degraded(reason: "x").wireName, "degraded")
        XCTAssertEqual(StreamHealth.degraded(reason: "x").reason, "x")
        XCTAssertNil(StreamHealth.streaming.reason)
    }

    func testSlowFinishCuesKeepTheModeAudible() {
        // The slow variant starts with the normal finish two-tone and adds a tail,
        // so the mode is still recognisable from the first two notes.
        for (normal, slow) in [(SoundEffect.listeningFinished, SoundEffect.listeningFinishedSlow),
                               (.commandListeningFinished, .commandListeningFinishedSlow)] {
            let a = normal.segments, b = slow.segments
            XCTAssertEqual(a.count, 2)
            XCTAssertEqual(Array(b.prefix(2)).map(\.freq), a.map(\.freq))
            XCTAssertGreaterThan(slow.duration, normal.duration)
            XCTAssertLessThan(b.last!.freq, a.last!.freq, "the tail must sit below the finish")
        }
        XCTAssertEqual(DictationMode.paste.slowFinishCue, .listeningFinishedSlow)
        XCTAssertEqual(DictationMode.command.slowFinishCue, .commandListeningFinishedSlow)
    }
}
