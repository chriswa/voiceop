import XCTest
@testable import VoiceOperator

/// The stall watchdog's arithmetic, against what the EPOS BTD 800 was seen to
/// do on 2026-10-26 when a dictation interrupted our own speech.
final class DeliveryWatchTests: XCTestCase {
    func testAFreshEngineIsGivenTimeForItsFirstBuffer() {
        var watch = DeliveryWatch()
        watch.opened(at: 100)
        // Seen: the first buffer 1.6 s after the engine started, and a normal dictation after it.
        XCTAssertFalse(watch.isStalled(at: 101.6, recording: true))
        XCTAssertTrue(watch.isStalled(at: 103, recording: true))
    }

    func testABurstCoversTheTimeItsAudioLasts() {
        var watch = DeliveryWatch()
        watch.opened(at: 100)
        watch.speechEnded(at: 99.9)
        // Seen: 0.7 s of audio arriving at once, then nothing for 0.41 s.
        watch.delivered(0.7, at: 100.7)
        XCTAssertFalse(watch.isStalled(at: 101.11, recording: true))
        XCTAssertFalse(watch.isStalled(at: 102.1, recording: true))
        XCTAssertTrue(watch.isStalled(at: 102.15, recording: true))
    }

    func testASteadyStreamThatStopsIsAStall() {
        var watch = DeliveryWatch()
        watch.opened(at: 0)
        var t = 0.1
        for _ in 0..<20 {
            watch.delivered(0.085, at: t)
            XCTAssertFalse(watch.isStalled(at: t, recording: true))
            t += 0.085
        }
        XCTAssertFalse(watch.isStalled(at: t + 0.6, recording: true))
        XCTAssertTrue(watch.isStalled(at: t + 0.75, recording: true))
    }

    func testAHeldMicrophoneIsWatchedCloselyAfterOurSpeechButADictationIsNot() {
        var watch = DeliveryWatch()
        watch.opened(at: 0)
        watch.delivered(0.085, at: 0.1)
        watch.speechEnded(at: 1)
        XCTAssertTrue(watch.isStalled(at: 0.185 + 0.45, recording: false))
        XCTAssertFalse(watch.isStalled(at: 0.185 + 0.45, recording: true))
        // Once the close watch has passed, a held microphone gets the usual limit.
        watch.delivered(0.085, at: 5)
        XCTAssertFalse(watch.isStalled(at: 5.085 + 0.45, recording: false))
    }

    func testReopeningStartsAfresh() {
        var watch = DeliveryWatch()
        watch.opened(at: 0)
        watch.delivered(0.085, at: 0.1)
        watch.opened(at: 10)
        XCTAssertFalse(watch.isStalled(at: 11, recording: true))
        XCTAssertEqual(watch.silence(at: 11, recording: true).limit, DeliveryWatch.firstBufferAllowance)
    }

    func testDeliveredReportsTheDrySpellItEnds() {
        var watch = DeliveryWatch()
        watch.opened(at: 0)
        XCTAssertEqual(watch.delivered(0.1, at: 0.5), 0)
        XCTAssertEqual(watch.delivered(0.1, at: 0.6), 0)
        XCTAssertEqual(watch.delivered(0.1, at: 1.4), 0.7, accuracy: 1e-9)
        XCTAssertEqual(watch.dry(at: 1.7), 0.2, accuracy: 1e-9)
    }

    func testARecordingReportsItsLongestGapAndShortfall() {
        var watch = DeliveryWatch()
        var recording = RecordingDelivery()
        watch.opened(at: 0)
        var t = 0.1
        func deliver(_ seconds: Double) {
            recording.buffer(seconds, dry: watch.delivered(seconds, at: t), at: t)
        }
        for _ in 0..<50 { deliver(0.1); t += 0.1 }
        // 0.6 s of audio never arrives: the device went dry, then carried on.
        t += 0.6
        for _ in 0..<44 { deliver(0.1); t += 0.1 }
        let summary = recording.summary(dryAtStop: watch.dry(at: t - 0.1))
        XCTAssertEqual(summary?.longestDry ?? 0, 0.6, accuracy: 1e-6)
        XCTAssertEqual(summary?.delivered ?? 0, 9.4, accuracy: 1e-6)
        XCTAssertEqual(summary?.expected ?? 0, 10.0, accuracy: 1e-6)
        XCTAssertEqual(summary?.shortfallPercent ?? 0, 6, accuracy: 1e-4)
    }

    func testARecordingStoppedByAStallCountsTheStallAsItsLongestGap() {
        var watch = DeliveryWatch()
        var recording = RecordingDelivery()
        watch.opened(at: 0)
        recording.buffer(0.1, dry: watch.delivered(0.1, at: 0.1), at: 0.1)
        recording.buffer(0.1, dry: watch.delivered(0.1, at: 0.2), at: 0.2)
        XCTAssertEqual(recording.summary(dryAtStop: watch.dry(at: 1.08))?.longestDry ?? 0, 0.78, accuracy: 1e-9)
    }

    func testARecordingThatHeardNothingHasNoSummary() {
        XCTAssertNil(RecordingDelivery().summary(dryAtStop: 3))
    }
}
