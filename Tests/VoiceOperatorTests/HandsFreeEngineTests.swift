import XCTest
@testable import VoiceOperator

/// "Speech" is a 200 Hz tone at about −20 dBFS, "quiet" a room's hiss, and
/// "roar" loud white noise. The fake speech detector tells them apart as the
/// real one does: loud and tonal is speech, loud and hissing is not.
/// Ported from Spaceterm's `src/mobile/hands-free.test.ts`.
private enum Sound {
    static let rate = 16_000
    nonisolated(unsafe) static var seed: Int = 7
    static func noise() -> Double {
        seed = (seed * 16807) % 2147483647
        return Double(seed) / 2147483647 * 2 - 1
    }
    static func quiet(_ ms: Int) -> [Int16] { (0..<(ms * rate / 1000)).map { _ in Int16(noise() * 10) } }
    static func roar(_ ms: Int) -> [Int16] { (0..<(ms * rate / 1000)).map { _ in Int16(noise() * 8000) } }
    static func speech(_ ms: Int) -> [Int16] {
        (0..<(ms * rate / 1000)).map { Int16(sin(2 * Double.pi * 200 * Double($0) / Double(rate)) * 4000) }
    }
}

private final class FakeDetector: FrameScorer {
    let name = "fake"
    func score(_ frame: [Int16]) throws -> Float {
        var crossings = 0
        var energy = 0.0
        for i in frame.indices {
            energy += Double(frame[i]) * Double(frame[i])
            if i > 0, (frame[i] >= 0) != (frame[i - 1] >= 0) { crossings += 1 }
        }
        let loud = (energy / Double(frame.count)).squareRoot() > 500
        return loud && Double(crossings) / Double(frame.count) < 0.15 ? 0.95 : 0.03
    }
    func reset() {}
}

private final class Harness {
    /// What Apple's model "hears" in each check, numbered from 0.
    var heard: (Int) -> String = { _ in "Control, what is Kevin doing?" }
    var transcript = "Control, what is Kevin doing?"
    var turn: () -> Double? = { nil }
    /// Hold checks until `answerChecks`: the Mac taking its time.
    var slowChecks = false
    var state = HandsFreeEngine.SourceState()

    var checks: [Int] = []
    var events: [HandsFreeEngine.Outgoing] = []
    var records: [(String, [String: Any])] = []
    var dictations: [FakeDictation] = []
    private var heldChecks: [() -> Void] = []
    private var queued: [() -> Void] = []
    private var timers: [FakeTimer] = []
    private var clock = 1_000_000.0
    var engine: HandsFreeEngine!
    /// turn-1-mini's stand-in, when a test wants one.
    var miniFactory: (() -> HandsFreeEngine.ContinuousTurn)?

    final class FakeDictation: HandsFreeEngine.Dictation {
        let backlogSeconds: Double
        var finished = false
        var cancelled = false
        let text: () -> String
        let run: (@escaping () -> Void) -> Void
        init(backlog: Int, text: @escaping () -> String, run: @escaping (@escaping () -> Void) -> Void) {
            backlogSeconds = Double(backlog) / Double(Sound.rate)
            self.text = text
            self.run = run
        }
        func append(_ pcm: [Int16]) {}
        func finish(_ done: @escaping (Result<String, Error>) -> Void) {
            finished = true
            let text = text()
            run { done(.success(text)) }
        }
        func cancel() { cancelled = true }
    }

    final class FakeTimer: HandsFreeEngine.Timer {
        let due: Double
        let block: () -> Void
        var cancelled = false
        init(due: Double, block: @escaping () -> Void) { self.due = due; self.block = block }
        func cancel() { cancelled = true }
    }

    init(justTurnedOn: Bool = false, configure: (Harness) -> Void = { _ in }) {
        configure(self)
        let deps = HandsFreeEngine.Deps(
            check: { [unowned self] clip, done in
                let n = checks.count
                checks.append(clip.count)
                let answer = HandsFreeEngine.CheckAnswer.heard(heard(n))
                if slowChecks { heldChecks.append { done(answer) } } else { queued.append { done(answer) } }
            },
            beginDictation: { [unowned self] _, backlog in
                let d = FakeDictation(backlog: backlog.count, text: { [unowned self] in transcript },
                                      run: { [unowned self] in queued.append($0) })
                dictations.append(d)
                return d
            },
            turn: { [unowned self] _, done in
                let p = turn()
                queued.append { done(p) }
            },
            after: { [unowned self] ms, block in
                let timer = FakeTimer(due: clock + ms, block: block)
                timers.append(timer)
                return timer
            },
            now: { [unowned self] in clock },
            emit: { [unowned self] in events.append($0) },
            record: { [unowned self] kind, detail in records.append((kind, detail)) },
            log: { _ in },
            continuousTurn: { [unowned self] in miniFactory?() })
        engine = HandsFreeEngine(owner: "spaceterm", trigger: "control", scorer: FakeDetector(), deps: deps)
        engine.sourceState = { [unowned self] in state }
        engine.sourceStarted()
        settle()
        if !justTurnedOn {
            // Let the window that turning it on opened run out, and forget its closing cue.
            let saved = state
            state = .init()
            for _ in 0..<16 { hear(Sound.quiet(1000)) }
            state = saved
            events.removeAll()
            records.removeAll()
        }
    }

    /// Feed audio in microphone-sized blocks, running what the engine's
    /// dependencies answered between them.
    func hear(_ parts: [Int16]...) {
        for part in parts {
            var i = 0
            while i < part.count {
                engine.push(Array(part[i..<min(i + 1600, part.count)]))
                clock += 100
                settle()
                i += 1600
            }
        }
    }

    func settle() {
        while !queued.isEmpty {
            let next = queued.removeFirst()
            next()
        }
        let due = timers.filter { !$0.cancelled && $0.due <= clock }
        timers.removeAll { timer in due.contains { $0 === timer } }
        for timer in due { timer.block() }
        if !queued.isEmpty { settle() }
    }

    /// Let `ms` pass with no audio.
    func elapse(_ ms: Double) {
        clock += ms
        settle()
    }

    func answerChecks() {
        let held = heldChecks
        heldChecks.removeAll()
        for answer in held { answer() }
        settle()
    }

    var cues: [String] {
        events.compactMap { if case .cue(let cue) = $0.event { return cue.rawValue }; return nil }
    }
    var sounds: [String] {
        var out: [String] = []
        var pending = false
        for e in events {
            switch e.event {
            case .cue(let cue): out.append(cue.rawValue)
            case .state(_, _, _, _, let p) where p != pending:
                pending = p
                out.append("pending:\(p ? "on" : "off")")
            default: break
            }
        }
        return out
    }
    var transcripts: [(text: String, interrupted: Bool, shutdown: Bool)] {
        events.compactMap {
            if case .transcript(let text, _, let interrupted, _, let shutdown) = $0.event { return (text, interrupted, shutdown) }
            return nil
        }
    }
    var cutIns: [Int] { events.compactMap { if case .cutIn(let ms) = $0.event { return ms }; return nil } }
    var ducks: [Bool] { events.compactMap { if case .duck(let on) = $0.event { return on }; return nil } }
    var phase: HandsFreeEngine.Phase { engine.phase }
    var lastState: (conversation: Bool, closesAt: Double?)? {
        for e in events.reversed() { if case .state(_, let c, let at, _, _) = e.event { return (c, at) } }
        return nil
    }
    var conversation: Bool { lastState?.conversation ?? false }
    var lastGauge: (turn: Double?, sampling: Bool)? {
        for e in events.reversed() { if case .gauge(let g) = e.event { return (g.turn, g.sampling) } }
        return nil
    }
    func recorded(_ kind: String) -> [[String: Any]] { records.filter { $0.0 == kind }.map(\.1) }
    var turnAsks = 0
}

final class HandsFreeEngineTests: XCTestCase {
    private func harness(justTurnedOn: Bool = false, _ configure: (Harness) -> Void = { _ in }) -> Harness {
        Harness(justTurnedOn: justTurnedOn) { h in
            configure(h)
            let turn = h.turn
            h.turn = { [unowned h] in h.turnAsks += 1; return turn() }
        }
    }

    func testDeafSourceIsRecordedAfterFiveSeconds() {
        let h = harness(justTurnedOn: true)
        h.elapse(5000)
        XCTAssertEqual(h.recorded("deaf").count, 1)
        let heard = harness(justTurnedOn: true)
        heard.hear(Sound.quiet(100))
        heard.elapse(5000)
        XCTAssertEqual(heard.recorded("deaf").count, 0)
    }

    func testTriggerSaidStraightThroughIsDictatedFromItsFirstSyllableAndEndedByQuiet() {
        let h = harness()
        XCTAssertEqual(h.phase, .listening)
        h.hear(Sound.quiet(1500), Sound.speech(1500))
        XCTAssertEqual(h.checks.count, 1)
        XCTAssertEqual(h.phase, .hearing)
        XCTAssertGreaterThan(h.dictations[0].backlogSeconds, 1)
        h.hear(Sound.speech(1500), Sound.quiet(3500))
        XCTAssertEqual(h.transcripts.map(\.text), ["Control, what is Kevin doing?"])
        XCTAssertEqual(h.cues, ["dictationStart", "dictationEnd"])
        XCTAssertEqual(HandsFreeEngine.Cue.dictationStart.haptic, "tap")
        XCTAssertEqual(HandsFreeEngine.Cue.dictationEnd.haptic, "double")
        XCTAssertEqual(h.phase, .listening)
    }

    func testEndsAtTheFirstPauseTheTurnModelIsSureOf() {
        let h = harness { $0.turn = { 0.93 } }
        h.hear(Sound.quiet(1500), Sound.speech(2500), Sound.quiet(1000))
        XCTAssertEqual(h.turnAsks, 1)
        XCTAssertEqual(h.transcripts.count, 1)
    }

    func testWaitsThroughAnUnfinishedPauseUntilPatienceRunsOut() {
        let h = harness { $0.turn = { 0.08 } }
        h.hear(Sound.quiet(1500), Sound.speech(2500), Sound.quiet(1000), Sound.speech(1500), Sound.quiet(1000))
        XCTAssertGreaterThanOrEqual(h.turnAsks, 2)
        XCTAssertEqual(h.transcripts.count, 0)
        XCTAssertEqual(h.phase, .hearing)
        h.hear(Sound.quiet(2500))
        XCTAssertEqual(h.transcripts.count, 1)
    }

    func testShowsThePausesOneAnswerAndForgetsItWhenTheyCarryOn() {
        let h = harness { $0.turn = { 0.08 } }
        h.hear(Sound.quiet(1500), Sound.speech(2500), Sound.quiet(1000))
        XCTAssertEqual(h.lastGauge?.turn, 0.08)
        XCTAssertEqual(h.lastGauge?.sampling, false, "answered: no longer being asked")
        h.hear(Sound.speech(500))
        XCTAssertNil(h.lastGauge?.turn)
        XCTAssertEqual(h.lastGauge?.sampling, false)
    }

    /// turn-1-mini's stand-in: low while it hears speech, climbing through silence.
    private final class FakeMini: HandsFreeEngine.ContinuousTurn {
        var quiet = 0
        func push(_ pcm: [Int16]) throws -> [Float] {
            var out: [Float] = []
            for frame in stride(from: 0, to: pcm.count - 319, by: 320) {
                let loud = pcm[frame..<frame + 320].contains { abs(Int($0)) > 1000 }
                quiet = loud ? 0 : quiet + 1
                out.append(min(1, Float(quiet) / 50))
            }
            return out
        }
    }

    func testTurnOneMiniIsShownAndRecordedPerPause_decidingNothing() {
        let h = harness { $0.turn = { 0.1 } }
        h.miniFactory = { FakeMini() }
        h.hear(Sound.quiet(1500), Sound.speech(2000), Sound.quiet(1500))
        var gauge: HandsFreeEngine.Gauge?
        for e in h.events.reversed() { if case .gauge(let g) = e.event { gauge = g; break } }
        XCTAssertNotNil(gauge?.mini)
        XCTAssertGreaterThan(gauge?.miniPeak ?? 0, 0.5, "it climbed through the pause")
        XCTAssertEqual(gauge?.miniThreshold, TurnOneMini.threshold)
        XCTAssertEqual(h.transcripts.count, 0, "turn-1-mini decides nothing: above its threshold, still hearing")
        h.hear(Sound.speech(500))
        let pause = h.recorded("pause").last
        XCTAssertEqual(pause?["outcome"] as? String, "resumed")
        XCTAssertEqual(pause?["smartTurn"] as? Double, 0.1)
        XCTAssertGreaterThan(pause?["miniPeak"] as? Double ?? 0, 0.5)
        XCTAssertNotNil(pause?["silenceMs"])
        h.hear(Sound.quiet(4000))
        XCTAssertEqual(h.recorded("pause").last?["outcome"] as? String, "silence")
    }

    func testAsksExactlyOnceHalfASecondIntoEachPause() {
        var p = 0.08
        let h = harness { $0.turn = { p } }
        h.hear(Sound.quiet(1500), Sound.speech(2500), Sound.quiet(300))
        XCTAssertEqual(h.turnAsks, 0, "not yet: a pause may be ended no sooner than half a second in")
        h.hear(Sound.quiet(300))
        XCTAssertEqual(h.turnAsks, 1, "asked half a second in")
        // A later, surer answer would come too late: it is not asked for.
        p = 0.93
        h.hear(Sound.quiet(1500))
        h.elapse(2000)
        XCTAssertEqual(h.turnAsks, 1)
        XCTAssertEqual(h.transcripts.count, 0)
        XCTAssertEqual(h.lastGauge?.turn, 0.08, "the first answer stays shown")
        // The next pause is asked about afresh.
        h.hear(Sound.speech(800), Sound.quiet(600))
        XCTAssertEqual(h.turnAsks, 2)
        XCTAssertEqual(h.transcripts.count, 1)
    }

    func testNotTheTriggerWordStartsNothing() {
        let h = harness { $0.heard = { _ in "It is under control" } }
        h.hear(Sound.quiet(1500), Sound.speech(1500), Sound.quiet(800))
        XCTAssertEqual(h.checks.count, 1)
        XCTAssertEqual(h.dictations.count, 0)
        XCTAssertEqual(h.cues, ["notWakeWord"])
    }

    func testChecksOnlySpeechAfterAQuietSpell() {
        let h = harness { $0.heard = { _ in "Something else" } }
        h.hear(Sound.quiet(1500), Sound.speech(3000), Sound.quiet(400), Sound.speech(2000), Sound.quiet(300),
               Sound.speech(1000), Sound.quiet(400))
        XCTAssertEqual(h.checks.count, 1)
    }

    func testDeafWhileTheSourceSaysSoAndNeedsAQuietSpellAfter() {
        let h = harness()
        h.state.deaf = "playing"
        h.hear(Sound.quiet(1500), Sound.speech(1500), Sound.quiet(800))
        XCTAssertEqual(h.checks, [])
        h.state.deaf = nil
        h.hear(Sound.speech(1500), Sound.quiet(800))
        XCTAssertEqual(h.checks, [])
        h.hear(Sound.quiet(1000), Sound.speech(1500))
        XCTAssertEqual(h.checks.count, 1)
    }

    func testTheTriggerAloneWaitsForMoreThenSendsIt() {
        let h = harness { $0.transcript = "Control." }
        h.hear(Sound.quiet(1500), Sound.speech(500), Sound.quiet(2500))
        XCTAssertFalse(h.dictations[0].finished)
        h.hear(Sound.quiet(3000))
        XCTAssertTrue(h.dictations[0].finished)
        XCTAssertEqual(h.transcripts.map(\.text), ["Control."])
    }

    func testHearsTheTriggerInALoudRoom() {
        let h = harness()
        h.hear(Sound.roar(1500), Sound.speech(600), Sound.roar(800))
        XCTAssertEqual(h.checks.count, 1)
        XCTAssertEqual(h.dictations.count, 1)
    }

    func testAfterTheTriggerAloneTheTurnModelIsNotAskedAboutThePause() {
        let h = harness { $0.turn = { 0.93 }; $0.transcript = "Control. What is Kevin doing?" }
        h.hear(Sound.quiet(1500), Sound.speech(600), Sound.quiet(3000))
        XCTAssertEqual(h.turnAsks, 0)
        XCTAssertEqual(h.phase, .hearing)
        h.hear(Sound.speech(1500), Sound.quiet(1000))
        XCTAssertEqual(h.turnAsks, 1)
        XCTAssertEqual(h.transcripts.count, 1)
    }

    func testRecordsVerdictsNeverWords() {
        let h = harness { $0.heard = { _ in "nope" } }
        h.hear(Sound.quiet(1500), Sound.speech(1500), Sound.quiet(300), Sound.speech(800), Sound.quiet(800))
        XCTAssertEqual(h.recorded("speech").compactMap { $0["verdict"] as? String }, ["checked", "after-speech"])
        XCTAssertEqual(h.recorded("check").first?["match"] as? Bool, false)
        XCTAssertFalse(h.records.contains { $0.1.values.contains { ($0 as? String) == "nope" } })
    }

    func testListensThroughTheClientsVoiceDucksItAndCutsItOff() {
        let h = harness()
        h.state.clientSpeaking = true
        h.hear(Sound.quiet(1500), Sound.speech(1500))
        XCTAssertEqual(h.ducks.first, true)
        XCTAssertEqual(h.cutIns.count, 1)
        h.state.clientSpeaking = false
        h.hear(Sound.speech(1000), Sound.quiet(3500))
        XCTAssertEqual(h.transcripts.first?.interrupted, true)
    }

    func testRecordsPerReplyHowMuchOfTheClientsVoiceGotPastEchoCancellation() {
        // In the conversation window, where any words cut the client off.
        let h = harness(justTurnedOn: true) { $0.heard = { _ in "I hadn't finished." } }
        h.state.clientSpeaking = true
        h.hear(Sound.quiet(700), Sound.speech(1500), Sound.quiet(500))
        h.state.clientSpeaking = false
        h.hear(Sound.quiet(100))
        let echo = h.recorded("echo").first
        XCTAssertEqual(echo?["ducks"] as? Int, 1)
        XCTAssertEqual(echo?["cutIns"] as? Int, 1)
        XCTAssertGreaterThan(echo?["speechPercent"] as? Int ?? 0, 40)
        XCTAssertEqual(Double(echo?["firstSpeechMs"] as? Int ?? 0), 700, accuracy: 70)
        let interrupt = h.recorded("interrupt").first
        XCTAssertEqual(interrupt?["heard"] as? String, "I hadn't finished.")
        XCTAssertEqual(Double(interrupt?["intoReplyMs"] as? Int ?? 0), 700, accuracy: 100)
        // A reply heard in silence: nothing got past.
        h.state.clientSpeaking = true
        h.hear(Sound.quiet(1000))
        h.state.clientSpeaking = false
        h.hear(Sound.quiet(100))
        XCTAssertEqual(h.recorded("echo").last?["speechPercent"] as? Int, 0)
        XCTAssertNil(h.recorded("echo").last?["firstSpeechMs"])
    }

    func testDatesTheCutToWhenTheyBeganTalking() {
        let h = harness { $0.slowChecks = true }
        h.state.clientSpeaking = true
        h.hear(Sound.quiet(1500), Sound.speech(1000))
        h.hear(Sound.speech(2000))
        XCTAssertEqual(h.cutIns, [])
        h.answerChecks()
        XCTAssertEqual(h.cutIns.count, 1)
        XCTAssertGreaterThanOrEqual(h.cutIns[0], 2900)
        XCTAssertLessThanOrEqual(h.cutIns[0], 3200)
    }

    func testCutsOffVoiceOperatorsSpeechToo_withNothingToDuck() {
        let h = harness { $0.slowChecks = true }
        h.state.voiceOperatorSpeaking = true
        h.hear(Sound.quiet(1500), Sound.speech(2000))
        h.answerChecks()
        XCTAssertEqual(h.cutIns.count, 1)
        XCTAssertGreaterThanOrEqual(h.cutIns[0], 1900)
        XCTAssertEqual(h.ducks, [])
    }

    func testDucksForAnyoneSpeakingAndBackUpWhenItWasNotForTheClient() {
        let h = harness { $0.heard = { _ in "Something else" } }
        h.state.clientSpeaking = true
        h.hear(Sound.quiet(1500), Sound.speech(1500), Sound.quiet(1000))
        XCTAssertEqual(h.ducks, [true, false])
        XCTAssertEqual(h.cutIns, [])
    }

    func testCutOffThenNothingCaughtTheClientIsToldAndCarriesOn() {
        let h = harness { $0.transcript = "Control." }
        h.state.clientSpeaking = true
        h.hear(Sound.quiet(1500), Sound.speech(600), Sound.quiet(500))
        h.state.clientSpeaking = false
        h.hear(Sound.quiet(6000))
        XCTAssertEqual(h.cutIns.count, 1)
        XCTAssertEqual(h.transcripts.first?.interrupted, true)
    }

    // MARK: The conversation window

    func testWindowOpensAsHandsFreeIsTurnedOn() {
        let h = harness(justTurnedOn: true) { $0.heard = { _ in "What is Kevin doing?" }; $0.transcript = "What is Kevin doing?" }
        XCTAssertTrue(h.conversation)
        XCTAssertEqual(h.cues.first, "ready")
        h.hear(Sound.quiet(1000), Sound.speech(1500), Sound.quiet(3500))
        XCTAssertEqual(h.transcripts.map(\.text), ["What is Kevin doing?"])
    }

    func testWindowLeftQuietClosesAfterConversationMs() {
        let h = harness(justTurnedOn: true)
        h.hear(Sound.quiet(15_500))
        XCTAssertFalse(h.conversation)
        XCTAssertEqual(h.cues.last, "conversationClosed")
        XCTAssertEqual(HandsFreeEngine.Cue.conversationClosed.haptic, "triple")
    }

    private func inConversation(_ h: Harness) {
        h.hear(Sound.quiet(1500), Sound.speech(1500), Sound.quiet(3500))
        XCTAssertEqual(h.transcripts.count, 1)
        XCTAssertTrue(h.conversation)
    }

    func testInTheWindowAnyWordsStartADictation() {
        let h = harness { $0.heard = { $0 == 0 ? "Control, what" : "Yes, and tell Evan" } }
        inConversation(h)
        h.transcript = "Yes, and tell Evan too."
        h.hear(Sound.quiet(1000), Sound.speech(1500), Sound.quiet(3500))
        XCTAssertEqual(h.transcripts.map(\.text).last, "Yes, and tell Evan too.")
    }

    func testIgnoresACoughInTheWindow() {
        let h = harness { $0.heard = { $0 == 0 ? "Control, what" : "Hmm." } }
        inConversation(h)
        h.hear(Sound.quiet(1000), Sound.speech(400), Sound.quiet(2000))
        XCTAssertEqual(h.checks.count, 2)
        XCTAssertEqual(h.dictations.count, 1)
    }

    func testAShortYesIsTheWholeAnswer() {
        let h = harness { $0.turn = { 0.93 }; $0.heard = { $0 == 0 ? "Control, what" : "Yes." } }
        inConversation(h)
        let asked = h.turnAsks
        h.transcript = "Yes."
        h.hear(Sound.quiet(1000), Sound.speech(500), Sound.quiet(1000))
        XCTAssertEqual(h.turnAsks, asked + 1)
        XCTAssertEqual(h.transcripts.last?.text, "Yes.")
    }

    func testWindowClosesOnceBothSidesAreQuietThenNeedsTheTriggerAgain() {
        let h = harness { $0.heard = { $0 == 0 ? "Control, what" : "Yes" } }
        inConversation(h)
        h.hear(Sound.quiet(10_000))
        XCTAssertTrue(h.conversation)
        XCTAssertNotNil(h.lastState?.closesAt)
        h.hear(Sound.quiet(5500))
        XCTAssertFalse(h.conversation)
        XCTAssertEqual(h.cues.last, "conversationClosed")
        h.hear(Sound.quiet(1000), Sound.speech(1500), Sound.quiet(500))
        XCTAssertEqual(h.cues.last, "notWakeWord")
    }

    func testWindowHoldsOpenWhileTheClientSpeaksAndCountsFromWhenItStops() {
        let h = harness()
        inConversation(h)
        h.state.clientSpeaking = true
        h.hear(Sound.quiet(20_000))
        XCTAssertTrue(h.conversation)
        XCTAssertNil(h.lastState?.closesAt)
        h.state.clientSpeaking = false
        h.hear(Sound.quiet(10_000))
        XCTAssertTrue(h.conversation)
        h.hear(Sound.quiet(5500))
        XCTAssertFalse(h.conversation)
    }

    func testWindowWaitsForAStalledSourceButNotForever() {
        let h = harness()
        inConversation(h)
        h.engine.sourceStopped(final: false)
        XCTAssertTrue(h.conversation)
        h.engine.sourceStarted(reopened: true)
        h.elapse(15_000)
        XCTAssertTrue(h.conversation, "a stall from before the source came back does not close it later")

        h.engine.sourceStopped(final: false)
        h.elapse(15_000)
        XCTAssertFalse(h.conversation)
        XCTAssertNotEqual(h.cues.last, "conversationClosed")
    }

    func testWordsInTheWindowCutTheClientsVoiceOff() {
        let h = harness { $0.heard = { $0 == 0 ? "Control, what" : "No, stop." } }
        inConversation(h)
        h.state.clientSpeaking = true
        h.transcript = "No, stop."
        h.hear(Sound.quiet(1000), Sound.speech(1500))
        h.state.clientSpeaking = false
        h.hear(Sound.quiet(3500))
        XCTAssertEqual(h.cutIns.count, 1)
        XCTAssertEqual(h.transcripts.last?.text, "No, stop.")
        XCTAssertEqual(h.transcripts.last?.interrupted, true)
    }

    // MARK: Shutdown

    func testTriggerShutdownIsSentAndClosesTheWindowWithItsCue() {
        let h = harness { $0.transcript = "Control, shut down." }
        h.hear(Sound.quiet(1500), Sound.speech(1500), Sound.quiet(3500))
        XCTAssertEqual(h.transcripts.first?.shutdown, true)
        XCTAssertFalse(h.conversation)
        XCTAssertEqual(h.cues, ["dictationStart", "dictationEnd", "shutdown"])
        h.heard = { _ in "Sure, I can look" }
        h.hear(Sound.quiet(1000), Sound.speech(1500), Sound.quiet(3500))
        XCTAssertEqual(h.cues.last, "notWakeWord")
    }

    func testShutdownInsideALongerRequestDoesNotCount() {
        let h = harness { $0.transcript = "Control, shut down the dev server." }
        h.hear(Sound.quiet(1500), Sound.speech(2500), Sound.quiet(3500))
        XCTAssertEqual(h.transcripts.first?.shutdown, false)
        XCTAssertTrue(h.conversation)
    }

    func testLetMeTurnThisOffWithoutTheTriggerIsCheckedWholeOnceItEnds() {
        let h = harness { $0.heard = { $0 == 0 ? "Let me turn" : "Let me turn this off." } }
        h.state.clientSpeaking = true
        h.hear(Sound.quiet(1500), Sound.speech(1500), Sound.quiet(1000))
        XCTAssertEqual(h.checks.count, 2)
        XCTAssertGreaterThan(h.checks[1], h.checks[0])
        XCTAssertEqual(h.dictations.count, 0)
        XCTAssertEqual(h.transcripts.map(\.text), ["let me turn this off"])
        XCTAssertEqual(h.transcripts.first?.shutdown, true)
        XCTAssertEqual(h.cutIns, [], "over the client's voice, cutting it off is left to the client letting go")
        XCTAssertEqual(h.cues.last, "shutdown")
        // Kept turned down from the first syllable until then.
        XCTAssertEqual(h.ducks, [true, false])
    }

    func testLetMeTurnThisOffThatWasSomethingElseGetsTheSadTune() {
        let h = harness { $0.heard = { $0 == 0 ? "Let me turn" : "Let me turn the page" } }
        h.hear(Sound.quiet(1500), Sound.speech(1500), Sound.quiet(1000))
        XCTAssertEqual(h.transcripts.count, 0)
        XCTAssertEqual(h.cues, ["notWakeWord"])
    }

    func testLetMeTurnThisOffThatRunsOnIsLetGo() {
        let h = harness { $0.heard = { _ in "Let me turn" } }
        h.hear(Sound.quiet(1500), Sound.speech(6000), Sound.quiet(1000))
        XCTAssertEqual(h.checks.count, 1)
        XCTAssertEqual(h.cues, ["notWakeWord"])
    }

    // MARK: The pending beep

    func testPendingWhileDecidingThenOffBeforeTheChirp() {
        let h = harness()
        h.hear(Sound.quiet(1500), Sound.speech(1500), Sound.quiet(3500))
        XCTAssertEqual(h.sounds, ["pending:on", "pending:off", "dictationStart", "dictationEnd"])
    }

    func testNotPendingInTheWindow() {
        let h = harness(justTurnedOn: true) { $0.heard = { _ in "What is" } }
        h.events.removeAll()
        h.hear(Sound.quiet(1000), Sound.speech(1500), Sound.quiet(3500))
        XCTAssertEqual(h.sounds, ["dictationStart", "dictationEnd"])
    }

    func testPendingThroughASlowCheckThenTheSadTune() {
        let h = harness { $0.slowChecks = true; $0.heard = { _ in "Something" } }
        h.hear(Sound.quiet(1500), Sound.speech(1500), Sound.quiet(800))
        XCTAssertEqual(h.sounds, ["pending:on"])
        h.answerChecks()
        h.hear(Sound.quiet(100))
        XCTAssertEqual(h.sounds, ["pending:on", "pending:off", "notWakeWord"])
        XCTAssertEqual(h.dictations.count, 0)
    }

    func testACoughTooShortToBeWordsStopsThePendingBeepUnchecked() {
        let h = harness()
        h.hear(Sound.quiet(1500), Sound.speech(150), Sound.quiet(1000))
        XCTAssertEqual(h.checks.count, 0)
        XCTAssertEqual(h.sounds, ["pending:on", "pending:off"])
    }

    func testStopsWhenTheSourceGoesMidSpeech() {
        let h = harness()
        h.hear(Sound.quiet(1500), Sound.speech(300))
        XCTAssertEqual(h.sounds, ["pending:on"])
        h.engine.sourceStopped(final: true)
        XCTAssertEqual(h.sounds, ["pending:on", "pending:off"])
        XCTAssertEqual(h.phase, .off)
    }

    // MARK: Several clients on one source

    func testTheTriggerWordPicksTheClient() {
        let h = harness { $0.heard = { _ in "Jarvis, lights" }; $0.transcript = "Jarvis, lights on." }
        h.engine.addClient("home", trigger: "jarvis")
        h.hear(Sound.quiet(1500), Sound.speech(1500), Sound.quiet(3500))
        XCTAssertEqual(h.events.first { if case .transcript = $0.event { return true }; return false }?.client, "home")
    }
}
