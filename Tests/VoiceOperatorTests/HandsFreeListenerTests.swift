import XCTest
@testable import VoiceOperator

/// Frames as the speech detector hands them over: audio, and the probability
/// someone is talking in it. "speech" is p 0.95, "silence" p 0.02, and "noise"
/// is loud but not speech — music, a fan, a room — p 0.05.
private let rate = 16_000.0

private func framesOf(_ ms: Double, _ p: Float, _ amplitude: Double) -> [ScoredFrame] {
    let count = Int((ms / 1000 * rate / Double(HandsFreeAudio.frameSamples)).rounded())
    let pcm = (0..<HandsFreeAudio.frameSamples).map { Int16((sin(Double($0) / 3) * amplitude).rounded()) }
    return Array(repeating: ScoredFrame(pcm: pcm, p: p), count: count)
}

private func speech(_ ms: Double) -> [ScoredFrame] { framesOf(ms, 0.95, 4000) }
private func silence(_ ms: Double) -> [ScoredFrame] { framesOf(ms, 0.02, 10) }
private func noise(_ ms: Double) -> [ScoredFrame] { framesOf(ms, 0.05, 8000) }
private func seconds(_ samples: Int) -> Double { Double(samples) / rate }

private final class Listening {
    var sightings: [SpeechSighting] = []
    private(set) var listener: WakeListener!

    init(tuning: HandsFreeTuning = .standard) {
        listener = WakeListener(tuning: tuning) { [unowned self] in self.sightings.append($0) }
    }

    func hear(_ parts: [ScoredFrame]...) -> [WakeCandidate] {
        listener.push(parts.flatMap { $0 })
    }
}

final class HandsFreeListenerTests: XCTestCase {
    // MARK: WakeListener

    func testHandsOutTheFirstSecondOfSpeechThatFollowsNoSpeechAndRemembersWhereItBegan() throws {
        let l = Listening()
        let candidates = l.hear(silence(1500), speech(3000), silence(500))
        XCTAssertEqual(candidates.count, 1)
        let c = try XCTUnwrap(candidates.first)
        XCTAssertGreaterThan(seconds(c.clip.count), 1.1)
        XCTAssertLessThan(seconds(c.clip.count), 1.4)
        XCTAssertEqual(seconds(c.start), 1.5, accuracy: 0.05)
        XCTAssertGreaterThanOrEqual(c.spokeMs, 1000)
    }

    func testIsNotPutOffByLoudSoundThatIsNotSpeech() {
        let l = Listening()
        let candidates = l.hear(noise(1500), speech(500), noise(800))
        XCTAssertEqual(candidates.count, 1)
        XCTAssertGreaterThanOrEqual(candidates.first?.noSpeechBeforeMs ?? 0, 1400)
    }

    func testHandsOutAWordSaidOnItsOwnAsSoonAsItStopsWithHowLongItWas() throws {
        let l = Listening()
        let c = try XCTUnwrap(l.hear(silence(1500), speech(600), silence(400)).first)
        XCTAssertLessThan(seconds(c.clip.count), 1.1)
        XCTAssertGreaterThan(c.spokeMs, 500)
        XCTAssertLessThan(c.spokeMs, 700)
    }

    func testIgnoresSpeechThatFollowsOtherSpeechTooClosely() {
        let l = Listening()
        let candidates = l.hear(silence(1500), speech(1500), silence(300), speech(1500), silence(300),
                                speech(500), silence(800))
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(l.sightings.map(\.verdict), [.checked, .afterSpeech, .afterSpeech])
    }

    func testRecordsEveryBurstOfSpeechAndWhyItWasOrWasNotChecked() {
        let l = Listening()
        _ = l.hear(silence(1500), speech(100), silence(1000), speech(600), silence(800))
        XCTAssertEqual(l.sightings.map(\.verdict), [.tooShort, .checked])
        XCTAssertGreaterThan(l.sightings[1].durationMs, 500)
        XCTAssertGreaterThan(l.sightings[1].noSpeechBeforeMs, 900)
        XCTAssertGreaterThan(l.sightings[1].peakDb, -25)
    }

    func testTakesItsThresholdsFromTuning() throws {
        var lateStart = HandsFreeTuning.standard
        lateStart.noSpeechBeforeMs = 2000
        let l = Listening(tuning: lateStart)
        XCTAssertTrue(l.hear(silence(1500), speech(2000), silence(800)).isEmpty)
        var shortWindow = HandsFreeTuning.standard
        shortWindow.onsetWindowMs = 500
        l.listener.tuning = shortWindow
        let c = try XCTUnwrap(l.hear(silence(1500), speech(2000), silence(800)).first)
        XCTAssertLessThan(seconds(c.clip.count), 0.8)
    }

    func testNeedsAFullSpellWithoutSpeechFromTheMomentItResumes() {
        let l = Listening()
        _ = l.hear(silence(3000))
        l.listener.resume()
        XCTAssertTrue(l.hear(silence(300), speech(2000), silence(800)).isEmpty)
    }

    func testStillHasEverythingSinceACandidateBeganForADictationThatStartsLate() throws {
        let l = Listening()
        let c = try XCTUnwrap(l.hear(silence(1500), speech(1200)).first)
        _ = l.hear(speech(2000))
        XCTAssertEqual(seconds(l.listener.audioSince(c.start).count), handsFreeLeadMs / 1000 + 3.2, accuracy: 0.05)
    }

    // MARK: UtteranceEndpointer

    private func run(_ endpointer: UtteranceEndpointer, _ parts: [ScoredFrame]...) -> [String] {
        kinds(endpointer.push(parts.flatMap { $0 }))
    }

    private func kinds(_ events: [UtteranceEvent]) -> [String] {
        events.map {
            switch $0 {
            case .ended(let reason): return "ended:\(reason.rawValue)"
            case .pause(_, let wakeWordOnly): return wakeWordOnly ? "pause:wake-word-only" : "pause"
            case .resumed: return "resumed"
            }
        }
    }

    func testReportsEachPauseOnceAndSpeechResumingAfterIt() {
        let events = run(UtteranceEndpointer(tuning: .standard, alreadyMs: 0, alreadySpokeMs: 1000),
                         speech(2000), silence(1000), speech(1000), silence(1000))
        XCTAssertEqual(events, ["pause", "resumed", "pause"])
    }

    func testTreatsThePauseAfterControlAloneAsNoTimeToAskAndWaitsForTheRest() {
        // The wake word, 0.6 s of it, was said before the dictation began; the check took a second.
        let endpointer = UtteranceEndpointer(tuning: .standard, alreadyMs: 1800, alreadySpokeMs: 600)
        XCTAssertEqual(run(endpointer, silence(3000)), ["pause:wake-word-only"])
        // Still waiting at three seconds — a short request's patience would be up by now.
        XCTAssertEqual(run(endpointer, speech(2000), silence(1000)), ["resumed", "pause"])
    }

    func testGivesUpOnAWakeWordLeftAloneAfterAfterWakeWordMs() {
        let endpointer = UtteranceEndpointer(tuning: .standard, alreadyMs: 1000, alreadySpokeMs: 600)
        XCTAssertEqual(run(endpointer, silence(5500)), ["pause:wake-word-only", "ended:silence"])
    }

    func testEndsAShortRequestAfterEndSilenceMinMsButNotOnAShorterPause() {
        XCTAssertFalse(run(UtteranceEndpointer(tuning: .standard, alreadyMs: 0, alreadySpokeMs: 2000),
                           speech(2000), silence(1000), speech(1000), silence(1000)).contains("ended:silence"))
        XCTAssertTrue(run(UtteranceEndpointer(tuning: .standard, alreadyMs: 0, alreadySpokeMs: 2000),
                          speech(2000), silence(3500)).contains("ended:silence"))
    }

    func testSaysHowFarTheQuietHasGotTowardsEndingIt() {
        let endpointer = UtteranceEndpointer(tuning: .standard, alreadyMs: 0, alreadySpokeMs: 2000)
        _ = run(endpointer, speech(2000))
        XCTAssertEqual(endpointer.silence(), 0)
        XCTAssertEqual(endpointer.quietMs, 0)
        _ = run(endpointer, silence(1500))
        // Half of a short request's three seconds.
        XCTAssertGreaterThan(endpointer.silence(), 0.4)
        XCTAssertLessThan(endpointer.silence(), 0.6)
        XCTAssertEqual(endpointer.silence(), endpointer.quietMs / endpointer.patienceMs, accuracy: 1e-9)
        _ = run(endpointer, speech(500))
        XCTAssertEqual(endpointer.silence(), 0)
        XCTAssertTrue(run(endpointer, silence(3500)).contains("ended:silence"))
        XCTAssertEqual(endpointer.silence(), 1)
    }

    func testMeasuresTheQuietAfterControlAloneAgainstTheLongerWaitForTheRest() {
        let endpointer = UtteranceEndpointer(tuning: .standard, alreadyMs: 1800, alreadySpokeMs: 600)
        _ = run(endpointer, silence(2500))
        XCTAssertEqual(endpointer.silence(), 0.5, accuracy: 0.05)
    }

    func testDoesNotHearLoudSoundThatIsNotSpeechAsTalking() {
        XCTAssertTrue(run(UtteranceEndpointer(tuning: .standard, alreadyMs: 0, alreadySpokeMs: 2000),
                          speech(2000), noise(3500)).contains("ended:silence"))
    }

    func testWaitsFarLongerForTheNextThoughtDeepIntoAMonologue() {
        XCTAssertEqual(run(UtteranceEndpointer(tuning: .standard, alreadyMs: 300_000, alreadySpokeMs: 200_000),
                           speech(1000), silence(10_000)), ["pause"])
    }

    func testStopsAtTheCapAndOnlyEndsOnce() {
        var tuning = HandsFreeTuning.standard
        tuning.maxUtteranceMs = 3000
        let endpointer = UtteranceEndpointer(tuning: tuning)
        XCTAssertEqual(run(endpointer, speech(5000), silence(6000)), ["ended:too-long"])
    }

    // MARK: endSilenceFor

    func testEndSilenceGrowsFromTheMinimumToTheMaximumAtTheRampAndNoFurther() {
        XCTAssertEqual(endSilenceFor(talkMs: 0, tuning: .standard), 3000)
        XCTAssertEqual(endSilenceFor(talkMs: 150_000, tuning: .standard), 11_500)
        XCTAssertEqual(endSilenceFor(talkMs: 300_000, tuning: .standard), 20_000)
        XCTAssertEqual(endSilenceFor(talkMs: 900_000, tuning: .standard), 20_000)
    }

    // MARK: EnergyScorer, the fallback

    func testEnergyScorerHearsAVoiceOverAQuietRoomAsSpeechAndTheRoomAsNot() {
        let scorer = EnergyScorer()
        let quiet = (0..<HandsFreeAudio.frameSamples).map { Int16($0 % 2 == 1 ? 8 : -8) }
        let loud = (0..<HandsFreeAudio.frameSamples).map { Int16((sin(Double($0) / 3) * 4000).rounded()) }
        for _ in 0..<20 { _ = scorer.score(quiet) }
        XCTAssertLessThan(scorer.score(quiet), 0.5)
        XCTAssertGreaterThan(scorer.score(loud), 0.5)
    }
}
