import AVFoundation
import XCTest
@testable import VoiceOperator

final class EchoExperimentTests: XCTestCase {
    // MARK: - What our voice just said

    func testARunOfWhatWasJustSaidIsEcho() {
        let recent = RecentSpeech()
        recent.note("Control is waiting for you to choose between the two designs.")
        XCTAssertTrue(recent.isEcho("Control is waiting"))
        XCTAssertTrue(recent.isEcho("choose between the two designs"))
        XCTAssertTrue(recent.isEcho("waiting for you, to choose!"))
    }

    func testWhatWasNotSaidIsNotEcho() {
        let recent = RecentSpeech()
        recent.note("Control is waiting for you to choose between the two designs.")
        XCTAssertFalse(recent.isEcho("Control, stop"))
        XCTAssertFalse(recent.isEcho("waiting designs"))
    }

    func testOneWordCannotSay() {
        let recent = RecentSpeech()
        recent.note("Control is waiting.")
        XCTAssertFalse(recent.isEcho("Control."))
    }

    func testOnlyTheLastMinuteCounts() {
        let recent = RecentSpeech()
        let then = Date()
        recent.note("Done. Three files changed.", at: then)
        XCTAssertTrue(recent.isEcho("three files changed", now: then.addingTimeInterval(30)))
        XCTAssertFalse(recent.isEcho("three files changed", now: then.addingTimeInterval(RecentSpeech.keepSeconds + 1)))
    }

    // MARK: - The canceller

    /// A voice-band noise played into a room that hands it back at half
    /// strength 20 ms later: once adapted, most of it is gone.
    func testTheCancellerTakesOutADelayedEcho() {
        var seed: UInt64 = 42
        func noise() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(Int64(bitPattern: seed >> 11) % 2000) / 1000 - 1
        }
        let rate = 16_000, seconds = 6, delay = 320
        let played: [Int16] = (0..<rate * seconds).map { _ in Int16(noise() * 6000) }
        let mic: [Int16] = played.indices.map { $0 >= delay ? played[$0 - delay] / 2 : 0 }
        let out = EchoCapture.cancel(mic, reference: played)
        func db(_ x: ArraySlice<Int16>) -> Double {
            10 * log10(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count) + 1e-9)
        }
        let lastSecond = (rate * (seconds - 1))..<(rate * seconds)
        XCTAssertLessThan(db(out[lastSecond]), db(mic[lastSecond]) - 15)
    }

    /// The record of a reply finds where the echo sits against the reference,
    /// how much of the reply had one, and how much the canceller took off.
    func testTheReplysRecordFindsTheEchoDelayAndWhatWasTakenOff() {
        var seed: UInt64 = 7
        func noise() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(Int64(bitPattern: seed >> 11) % 2000) / 1000 - 1
        }
        let rate = 16_000, delay = 1_440   // 90 ms
        let played: [Int16] = (0..<rate * 10).map { $0 < rate * 8 ? Int16(noise() * 6000) : 0 }
        let mic: [Int16] = played.indices.map { $0 >= delay ? played[$0 - delay] / 2 : 0 }
        let out = EchoCapture.cancel(mic, reference: played)
        let detail = EchoDiagnostics.analyse(mic: mic, reference: played, out: out)
        XCTAssertEqual(detail["echoDelayMs"] as? Double ?? -1, 90, accuracy: 1)
        XCTAssertGreaterThan(detail["correlation"] as? Double ?? 0, 0.9)
        XCTAssertEqual(detail["refCoveragePercent"] as? Int, 80)
        XCTAssertGreaterThan(detail["erleDb"] as? Double ?? 0, 10)
    }

    func testAReplyWithNoReferenceSaysSo() {
        let mic = [Int16](repeating: 1000, count: 16_000)
        let detail = EchoDiagnostics.analyse(mic: mic, reference: [Int16](repeating: 0, count: 16_000), out: mic)
        XCTAssertEqual(detail["refCoveragePercent"] as? Int, 0)
        XCTAssertNil(detail["erleDb"])
    }

    func testTheReferenceIsLaidOutByHostTime() {
        let reference = EchoReference()
        let start = AVAudioTime.hostTime(forSeconds: 100)
        reference.append([Float](repeating: 0.5, count: 160), at: start)
        // From 5 ms before it began: 80 samples of silence, then it.
        let out = reference.samples(from: AVAudioTime.hostTime(forSeconds: 100 - 0.005), count: 400)
        XCTAssertEqual(out[79], 0)
        XCTAssertEqual(out[80], 0.5)
        XCTAssertEqual(out[239], 0.5)
        XCTAssertEqual(out[240], 0)
    }

    func testTheExperimentIsOffUnlessTurnedOn() {
        let key = "vo.handsFreeEchoExperiment"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(EchoExperiment.isOn)
    }
}

