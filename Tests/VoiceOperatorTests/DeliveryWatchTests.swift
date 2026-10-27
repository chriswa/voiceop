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
}
