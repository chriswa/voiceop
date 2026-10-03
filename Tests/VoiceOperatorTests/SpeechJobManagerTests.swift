import Foundation
import XCTest
@testable import VoiceOperator

final class SpeechJobManagerTests: XCTestCase {
    func testSentenceSessionIdentityAndNextJobHandoff() async {
        let manager = SpeechJobManager()
        let gate = PlaybackGate()
        let requests = PlaybackRequests()
        await manager.configure(
            play: { request, onStart, _ in
                await requests.append(request)
                return await gate.play(onStart: onStart)
            }, prefetch: { _, _ in }, halt: { nil })
        let first = await manager.enqueue(text: "First sentence. Second sentence.", voice: "af_heart")!
        let second = await manager.enqueue(text: "Another job.", voice: "af_heart")!
        await gate.waitForStarts(1)
        await gate.finishNext()
        await gate.waitForStarts(2)
        await gate.finishNext()
        await gate.waitForStarts(3)
        let seen = await requests.values
        XCTAssertEqual(seen.map(\.jobID), [first.id, first.id, second.id])
        XCTAssertEqual(seen.map(\.isLast), [false, true, true])
        let completed = await manager.result(id: first.id)
        XCTAssertEqual(completed?.state, .completed)
        await gate.finishNext()
    }

    func testQueueRejectsMutedRequests() async {
        let manager = SpeechJobManager()
        await manager.setMuted(true)
        let result = await manager.enqueue(text: "Hello.", voice: "af_heart")
        XCTAssertEqual(result?.error, "speech_muted")
    }

    func testStopSpeakingInterruptsCurrentAndClearsQueue() async {
        let manager = SpeechJobManager()
        let gate = PlaybackGate()
        let halts = Counter()
        await manager.configure(
            play: { _, onStart, _ in await gate.play(onStart: onStart) },
            prefetch: { _, _ in },
            halt: { await halts.increment(); return nil })

        let first = await manager.enqueue(text: "First sentence.", voice: "af_heart")!
        let second = await manager.enqueue(text: "Second sentence.", voice: "af_heart")!
        await gate.waitForStarts(1)
        await gate.startNext()
        try? await Task.sleep(for: .milliseconds(20))

        let stopped = await manager.stopSpeaking()
        XCTAssertTrue(stopped)
        try? await Task.sleep(for: .milliseconds(20))
        let haltCount = await halts.value
        XCTAssertEqual(haltCount, 1)
        let firstState = await manager.result(id: first.id)?.state
        let secondState = await manager.result(id: second.id)?.state
        XCTAssertEqual(firstState, .interruptedByUser)
        XCTAssertEqual(secondState, .interruptedByUser)
        let stoppedAgain = await manager.stopSpeaking()
        XCTAssertFalse(stoppedAgain)
    }

    func testSentenceBoundariesDoNotChangePublicLifecycleOrWakeLongPoll() async {
        let manager = SpeechJobManager()
        let gate = PlaybackGate()
        await manager.configure(
            play: { _, onStart, _ in await gate.play(onStart: onStart) },
            prefetch: { _, _ in },
            halt: { nil })

        let accepted = await manager.enqueue(text: "First sentence. Second sentence.", voice: "af_heart")!
        XCTAssertEqual(accepted.state, .inProgress)
        await gate.waitForStarts(1)

        let waitingForFirstAudio = await manager.result(id: accepted.id)
        XCTAssertEqual(waitingForFirstAudio?.playbackState, .queued)
        await gate.startNext()
        try? await Task.sleep(for: .milliseconds(20))
        let firstPlayback = await manager.result(id: accepted.id)
        XCTAssertEqual(firstPlayback?.state, .inProgress)
        XCTAssertEqual(firstPlayback?.playbackState, .speaking)

        let longPoll = ResultBox()
        Task { await longPoll.store(await manager.wait(id: accepted.id, seconds: 30)) }
        try? await Task.sleep(for: .milliseconds(20))

        await gate.finishNext()
        await gate.waitForStarts(2)
        let waitingForSecondAudio = await manager.result(id: accepted.id)
        XCTAssertEqual(waitingForSecondAudio?.playbackState, .queued)
        await gate.startNext()
        try? await Task.sleep(for: .milliseconds(20))
        let secondPlayback = await manager.result(id: accepted.id)
        XCTAssertEqual(secondPlayback?.state, .inProgress)
        XCTAssertEqual(secondPlayback?.playbackState, .speaking)
        try? await Task.sleep(for: .milliseconds(20))
        let prematurelyCompleted = await longPoll.current()
        XCTAssertNil(prematurelyCompleted)

        await gate.finishNext()
        let terminal = await longPoll.waitForResult()
        XCTAssertEqual(terminal?.state, .completed)
        XCTAssertNil(terminal?.playbackState)
        XCTAssertEqual(terminal?.characterOffset, "First sentence. Second sentence.".unicodeScalars.count)
    }

    /// The opt-in counterpart of the test above: a client that passes a cursor
    /// wants playback transitions, which a terminal-only wait cannot deliver.
    func testCursorLongPollWakesOnPlaybackTransitions() async {
        let manager = SpeechJobManager()
        let gate = PlaybackGate()
        await manager.configure(
            play: { _, onStart, _ in await gate.play(onStart: onStart) },
            prefetch: { _, _ in },
            halt: { nil })

        let accepted = await manager.enqueue(text: "First sentence. Second sentence.", voice: "af_heart")!
        await gate.waitForStarts(1)
        let queued = await manager.result(id: accepted.id)!
        XCTAssertEqual(queued.playbackState, .queued)

        let poll = ResultBox()
        Task { await poll.store(await manager.wait(id: accepted.id, seconds: 30, since: queued.version)) }
        try? await Task.sleep(for: .milliseconds(20))
        let beforeAudio = await poll.current()
        XCTAssertNil(beforeAudio, "nothing changed yet, so the poll must still be parked")

        await gate.startNext()
        let speaking = await poll.waitForResult()
        XCTAssertEqual(speaking?.state, .inProgress)
        XCTAssertEqual(speaking?.playbackState, .speaking)
        XCTAssertGreaterThan(speaking!.version, queued.version)
    }

    /// Without this, a client that was away when the job moved would park for
    /// the full wait on a transition that had already happened — which is the
    /// terminal-only behaviour it was trying to escape.
    func testCursorLongPollReturnsImmediatelyForAChangeAlreadyMissed() async {
        let manager = SpeechJobManager()
        let gate = PlaybackGate()
        await manager.configure(
            play: { _, onStart, _ in await gate.play(onStart: onStart) },
            prefetch: { _, _ in },
            halt: { nil })

        let accepted = await manager.enqueue(text: "First sentence. Second sentence.", voice: "af_heart")!
        await gate.waitForStarts(1)
        let queued = await manager.result(id: accepted.id)!
        await gate.startNext()
        try? await Task.sleep(for: .milliseconds(20))

        // The client only now asks, holding the version from before the change.
        let missed = await manager.wait(id: accepted.id, seconds: 30, since: queued.version)
        XCTAssertEqual(missed?.playbackState, .speaking)
    }

    /// Two clips synthesize at once and no more: the one being played, and one
    /// lookahead. A third would be competing with the sentence the listener is
    /// actually blocked on, at whichever backend they share.
    func testSynthesizesAtMostTwoClipsAtOnce() async {
        let h = await startWindowHarness(sentences: 5)

        // Sentence one synthesizes through `play`; only sentence two is a
        // lookahead, and nothing else has been started.
        await h.assertStarted(["Two."])

        // Settling the lookahead does not buy a third: sentence one still has
        // the other slot, and still has not produced its audio.
        await h.synth.settle("Two.")
        try? await Task.sleep(for: .milliseconds(20))
        await h.assertStarted(["Two."])
    }

    /// The rule that is easy to get wrong. While the sentence being played is
    /// still synthesizing it is the only thing between the listener and sound,
    /// so the window must not spend its free slot looking further ahead — even
    /// though, positionally, it could.
    func testHoldsTheWindowShutWhileTheCurrentSentenceIsStillSynthesizing() async {
        let h = await startWindowHarness(sentences: 5)

        // The backend answers the lookahead first and is still labouring over
        // the sentence being played.
        await h.synth.settle("Two.")
        try? await Task.sleep(for: .milliseconds(20))
        await h.assertStarted(["Two."], "a third clip started while sentence one was still synthesizing")

        // The moment sentence one's audio is in hand, the window opens as far
        // as the budget allows: both free slots go to the next two sentences.
        await h.gate.synthesizeNext()
        await h.synth.waitForStarts(3)
        await h.assertStarted(["Two.", "Three.", "Four."])
    }

    /// A budget rather than a fixed distance. Short sentences settle quickly and
    /// the window walks forward through them, so a long sentence further down
    /// the answer starts while there is still speech left to cover it — instead
    /// of waiting for playback to reach its immediate predecessor.
    func testWalksTheWindowForwardThroughShortSentences() async {
        let h = await startWindowHarness(sentences: 5)

        // Sentence one's audio arrives; sentence two is long and stays in
        // flight for the rest of this test, holding one slot throughout.
        await h.gate.synthesizeNext()
        await h.synth.waitForStarts(2)

        // The other slot now walks: each short sentence settles and frees it.
        await h.synth.settle("Three.")
        await h.synth.waitForStarts(3)
        await h.synth.settle("Four.")
        await h.synth.waitForStarts(4)

        // Sentence five is under way while sentence one is still playing — the
        // whole point. A one-ahead window would not have reached it until
        // playback was on sentence four.
        await h.assertStarted(["Two.", "Three.", "Four.", "Five."])
        let playback = await h.manager.result(id: h.jobId)?.playbackState
        XCTAssertEqual(playback, .queued, "playback should still be on sentence one")
    }

    /// The window has to stop at the end of the answer rather than running off
    /// the end of the segment list.
    func testDoesNotLookPastTheLastSentence() async {
        let h = await startWindowHarness(sentences: 1)
        await h.gate.synthesizeNext()
        try? await Task.sleep(for: .milliseconds(20))

        await h.assertStarted([])
    }
}

/// One job, `sentences` sentences long, with both halves of synthesis under the
/// test's control: `gate` owns the sentence being played (its `onSynthesized`),
/// `synth` owns every lookahead.
private struct WindowHarness {
    let manager: SpeechJobManager
    let gate: PlaybackGate
    let synth: SynthesisGate
    let jobId: String

    /// Awaiting actor state inside an `XCTAssert` autoclosure does not compile,
    /// so every check of what reached the synthesizer goes through here. `line`
    /// keeps a failure reported against the calling test.
    func assertStarted(_ expected: [String], _ message: String = "",
                       file: StaticString = #filePath, line: UInt = #line) async {
        let started = await synth.startedTexts
        XCTAssertEqual(started, expected, message, file: file, line: line)
    }
}

/// Enqueue one job and wait until sentence one has been handed to playback and
/// its lookahead, if any, has actually reached the synthesizer. Both barriers
/// matter: the window is opened synchronously, but starts its requests in
/// detached tasks.
private func startWindowHarness(sentences: Int) async -> WindowHarness {
    let manager = SpeechJobManager()
    let gate = PlaybackGate()
    let synth = SynthesisGate()
    let words = ["One.", "Two.", "Three.", "Four.", "Five."]
    await manager.configure(
        play: { _, onStart, onSynthesized in
            await gate.play(onStart: onStart, onSynthesized: onSynthesized)
        },
        prefetch: { text, _ in await synth.synthesize(text) },
        halt: { nil })
    let accepted = await manager.enqueue(
        text: words.prefix(sentences).joined(separator: " "), voice: "af_heart")!
    await gate.waitForStarts(1)
    if sentences > 1 { await synth.waitForStarts(1) }
    return WindowHarness(manager: manager, gate: gate, synth: synth, jobId: accepted.id)
}

/// Stands in for the synthesizer behind `prefetch`: records what was asked for,
/// and holds each request open until the test settles it by name.
private actor SynthesisGate {
    private var started: [String] = []
    private var pending: [String: CheckedContinuation<Void, Never>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    /// Sentence segments carry their trailing space; tests name them without.
    private static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func synthesize(_ text: String) async {
        let name = Self.key(text)
        started.append(name)
        let ready = waiters.filter { $0.0 <= started.count }
        waiters.removeAll { $0.0 <= started.count }
        ready.forEach { $0.1.resume() }
        await withCheckedContinuation { pending[name] = $0 }
    }

    var startedTexts: [String] { started }

    func settle(_ name: String) { pending.removeValue(forKey: name)?.resume() }

    func waitForStarts(_ count: Int) async {
        guard started.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor PlaybackRequests {
    private(set) var values: [SpeechJobManager.SentencePlayback] = []
    func append(_ request: SpeechJobManager.SentencePlayback) { values.append(request) }
}

/// `character_offset` at word resolution. A listener who cuts a long sentence
/// off three words from its end heard nearly all of it, and a client told only
/// "the last sentence did not finish" cannot tell that from hearing none of it.
extension SpeechJobManagerTests {
    private func interrupted(
        text: String, stoppingAt stoppedAt: SpokenPosition?, afterSentences played: Int
    ) async -> (offset: Int, boundary: Int) {
        await interrupted(parts: [.init(text: text, voice: "af_heart")], stoppingAt: stoppedAt, afterSentences: played)
    }

    private func interrupted(
        parts: [SpeechJobManager.Part], stoppingAt stoppedAt: SpokenPosition?, afterSentences played: Int
    ) async -> (offset: Int, boundary: Int) {
        let manager = SpeechJobManager()
        let gate = PlaybackGate()
        await manager.configure(
            play: { _, onStart, _ in await gate.play(onStart: onStart) },
            prefetch: { _, _ in },
            halt: { stoppedAt })
        let job = await manager.enqueue(parts: parts)!
        for n in 0..<played {
            await gate.waitForStarts(n + 1)
            await gate.startNext()
            await gate.finishNext()
        }
        await gate.waitForStarts(played + 1)
        await gate.startNext()
        let boundary = await manager.result(id: job.id)!.characterOffset
        _ = await manager.stopSpeaking()
        let after = await manager.result(id: job.id)!
        XCTAssertEqual(after.state, .interruptedByUser)
        return (after.characterOffset, boundary)
    }

    func testInterruptionReportsTheWordTheVoiceReached() async {
        let result = await interrupted(
            text: "First sentence. Second sentence.",
            stoppingAt: SpokenPosition(sentence: 1, characterOffset: 6),
            afterSentences: 1)
        XCTAssertEqual(result.offset, result.boundary + 6,
                       "the word offset is measured from the interrupted sentence's start")
    }

    /// Nothing to report — timings that never arrived, or a build of the player
    /// that does not track words — has to leave the old contract intact rather
    /// than collapse the offset to zero.
    func testFallsBackToSentenceResolutionWithoutAWordPosition() async {
        let result = await interrupted(
            text: "First sentence. Second sentence.",
            stoppingAt: nil,
            afterSentences: 1)
        XCTAssertEqual(result.offset, result.boundary)
    }

    /// A rewind leaves the voice in a sentence the queue has already finished
    /// with. The position says which sentence it was actually in, and that is
    /// the one its offset is measured against — adding it to the *queue's*
    /// sentence would report more heard than was ever spoken.
    func testMeasuresFromTheSentenceTheVoiceWasIn() async {
        let result = await interrupted(
            text: "First sentence. Second sentence.",
            stoppingAt: SpokenPosition(sentence: 0, characterOffset: 5),
            afterSentences: 1)
        XCTAssertEqual(result.offset, 5)
        XCTAssertLessThan(result.offset, result.boundary)
    }

    /// A position pointing past the job's sentences is not something to pass on
    /// to a client, whatever produced it.
    func testIgnoresAPositionThatIsNotInTheJob() async {
        let result = await interrupted(
            text: "First sentence. Second sentence.",
            stoppingAt: SpokenPosition(sentence: 9, characterOffset: 3),
            afterSentences: 1)
        XCTAssertEqual(result.offset, result.boundary)
    }
}

/// A multi-voice reply is one job: a narrator and the agents it quotes, each in
/// their own voice. Every voice change has to be invisible to the queue's
/// mechanics — lookahead, offsets, interruption — or it would be cheaper to send
/// separate jobs, which is exactly what this exists to avoid.
extension SpeechJobManagerTests {
    /// Narration, then Kevin. The emoji keeps the UTF-16 arithmetic honest: it
    /// is two code units, one scalar, one Character.
    private static let reply: [SpeechJobManager.Part] = [
        .init(text: "Kevin says 👋.", voice: "af_heart"),
        .init(text: "Kevin here. I finished the pressure solver.", voice: "am_michael"),
    ]
    private static var joined: NSString { SpeechJobManager.Part.joined(reply) as NSString }

    func testEachSentenceIsSpokenAndPrefetchedInItsOwnVoice() async {
        let manager = SpeechJobManager()
        let gate = PlaybackGate()
        let requests = PlaybackRequests()
        let prefetched = Prefetches()
        await manager.configure(
            play: { request, onStart, onSynthesized in
                await requests.append(request)
                return await gate.play(onStart: onStart, onSynthesized: onSynthesized)
            },
            prefetch: { text, voice in await prefetched.append(text, voice) },
            halt: { nil })
        let job = await manager.enqueue(parts: Self.reply)!
        await gate.waitForStarts(1)

        // The lookahead crosses the change of speaker while the narrator's
        // sentence is still being synthesized: no gap at the switch.
        await prefetched.waitFor(1)
        await gate.synthesizeNext()
        await prefetched.waitFor(2)
        let ahead = await prefetched.values
        XCTAssertEqual(ahead.map(\.voice), ["am_michael", "am_michael"])
        XCTAssertEqual(ahead.map { $0.text.trimmingCharacters(in: .whitespaces) },
                       ["Kevin here.", "I finished the pressure solver."])

        for n in 1...3 {
            await gate.waitForStarts(n)
            await gate.startNext()
            await gate.finishNext()
        }
        try? await Task.sleep(for: .milliseconds(20))
        let played = await requests.values
        XCTAssertEqual(played.map(\.voice), ["af_heart", "am_michael", "am_michael"])
        XCTAssertEqual(played.map(\.isLast), [false, false, true])
        XCTAssertEqual(played.map(\.jobID), [job.id, job.id, job.id])
        let done = await manager.result(id: job.id)!
        XCTAssertEqual(done.state, .completed)
        XCTAssertEqual(done.characterOffset, Self.joined.length)
    }

    /// No sentence spans two voices, even where the parts' punctuation would
    /// let the detector run them together.
    func testSentencesNeverCrossAVoiceBoundary() async {
        let manager = SpeechJobManager()
        let gate = PlaybackGate()
        let requests = PlaybackRequests()
        await manager.configure(
            play: { request, onStart, _ in
                await requests.append(request)
                return await gate.play(onStart: onStart)
            }, prefetch: { _, _ in }, halt: { nil })
        _ = await manager.enqueue(parts: [.init(text: "Kevin says", voice: "af_heart"),
                                          .init(text: "done", voice: "am_michael")])!
        for n in 1...2 {
            await gate.waitForStarts(n)
            await gate.finishNext()
        }
        let played = await requests.values
        XCTAssertEqual(played.map(\.text), ["Kevin says", "done"])
        XCTAssertEqual(played.map(\.voice), ["af_heart", "am_michael"])
    }

    func testSentenceResolutionOffsetsAreIntoTheJoinedText() async {
        // Interrupted with no word position once the narrator has finished:
        // everything up to the end of part one, not counting the separator.
        let result = await interrupted(parts: Self.reply, stoppingAt: nil, afterSentences: 1)
        XCTAssertEqual(result.offset, ("Kevin says 👋." as NSString).length)
        XCTAssertEqual(result.offset, Self.joined.range(of: " Kevin here.").location)
    }

    /// The first sentence of a later part starts after the separator, so its
    /// word offset cannot be added to the previous sentence's end.
    func testAMidSentenceInterruptionInALaterPartLandsOnTheRightWord() async {
        let first = await interrupted(
            parts: Self.reply, stoppingAt: SpokenPosition(sentence: 1, characterOffset: 5), afterSentences: 1)
        XCTAssertEqual(Self.joined.substring(to: first.offset), "Kevin says 👋. Kevin")

        let second = await interrupted(
            parts: Self.reply, stoppingAt: SpokenPosition(sentence: 2, characterOffset: 10), afterSentences: 2)
        XCTAssertEqual(Self.joined.substring(to: second.offset), "Kevin says 👋. Kevin here. I finished")
    }
}

/// `POST /v1/speech` body validation.
extension SpeechJobManagerTests {
    private func parse(_ json: String) -> Swift.Result<[SpeechJobManager.Part], SpeechRequestBody.Rejection> {
        SpeechRequestBody.parts(from: Data(json.utf8))
    }

    func testTheSingleVoiceShapeIsUnchanged() {
        XCTAssertEqual(try parse(#"{"text":"Hello.","voice":"am_adam"}"#).get(), [.init(text: "Hello.", voice: "am_adam")])
        XCTAssertEqual(try parse(#"{"text":"Hello."}"#).get(), [.init(text: "Hello.", voice: "af_heart")])
        XCTAssertEqual(parse(#"{"text":"  "}"#), .failure(.init(status: 400, error: "text_required")))
        XCTAssertEqual(parse(#"{}"#), .failure(.init(status: 400, error: "text_required")))
        XCTAssertEqual(parse("not json"), .failure(.init(status: 400, error: "text_required")))
    }

    func testPartsShapeWithADefaultVoice() {
        let parts = try? parse(#"{"parts":[{"text":"Kevin says.","voice":"af_bella"},{"text":"Done."}]}"#).get()
        XCTAssertEqual(parts, [.init(text: "Kevin says.", voice: "af_bella"), .init(text: "Done.", voice: "af_heart")])
    }

    func testRejectsMalformedParts() {
        XCTAssertEqual(parse(#"{"text":"Hi.","parts":[{"text":"Hi."}]}"#),
                       .failure(.init(status: 400, error: "text_and_parts_exclusive")))
        XCTAssertEqual(parse(#"{"parts":[]}"#), .failure(.init(status: 400, error: "parts_empty")))
        XCTAssertEqual(parse(#"{"parts":"Hi."}"#), .failure(.init(status: 400, error: "parts_invalid")))
        XCTAssertEqual(parse(#"{"parts":[{"text":"Hi."},{"text":" "}]}"#),
                       .failure(.init(status: 400, error: "part_text_required", index: 1)))
        XCTAssertEqual(parse(#"{"parts":[{"voice":"am_adam"}]}"#),
                       .failure(.init(status: 400, error: "part_text_required", index: 0)))
    }

    /// The limit is on what would be spoken, so it counts the joined text —
    /// separators included — not any one part.
    func testLengthLimitAppliesToTheJoinedText() {
        let half = String(repeating: "a", count: SpeechRequestBody.maxScalars / 2)
        let fits = #"{"parts":[{"text":"\#(half)"},{"text":"\#(half.dropLast())"}]}"#
        XCTAssertNoThrow(try parse(fits).get())
        let over = #"{"parts":[{"text":"\#(half)"},{"text":"\#(half)"}]}"#
        XCTAssertEqual(parse(over), .failure(.init(status: 422, error: "text_too_long")))
    }
}

private actor Prefetches {
    private(set) var values: [(text: String, voice: String)] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func append(_ text: String, _ voice: String) {
        values.append((text, voice))
        let ready = waiters.filter { $0.0 <= values.count }
        waiters.removeAll { $0.0 <= values.count }
        ready.forEach { $0.1.resume() }
    }
    func waitFor(_ count: Int) async {
        guard values.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

/// Dictation stops the voice itself, ahead of telling the queue, so the player
/// can report the interruption before — or instead of — the interrupt path. The
/// job has to settle the same way either way; the alternative is what a
/// listener actually hit, which was a job filed as a synthesis failure with no
/// offset and an error put in front of every client watching it.
extension SpeechJobManagerTests {
    private func playerReported(
        _ outcome: SpeechJobManager.SentenceOutcome
    ) async -> SpeechJobManager.Result {
        let manager = SpeechJobManager()
        let gate = PlaybackGate()
        await manager.configure(
            play: { _, onStart, _ in await gate.play(onStart: onStart) },
            prefetch: { _, _ in },
            halt: { nil })
        let job = await manager.enqueue(text: "First sentence. Second sentence.", voice: "af_heart")!
        await gate.waitForStarts(1)
        await gate.startNext()
        await gate.finish(outcome)
        try? await Task.sleep(for: .milliseconds(20))
        return await manager.result(id: job.id)!
    }

    func testAPlayerReportedInterruptSettlesTheJobItself() async {
        let result = await playerReported(.interrupted(SpokenPosition(sentence: 0, characterOffset: 5)))
        XCTAssertEqual(result.state, .interruptedByUser)
        XCTAssertEqual(result.characterOffset, 5,
                       "the position the player carried has to survive to the client")
    }

    func testAPlayerReportedInterruptWithNoPositionStillReadsAsAnInterrupt() async {
        let result = await playerReported(.interrupted(nil))
        XCTAssertEqual(result.state, .interruptedByUser)
        XCTAssertEqual(result.characterOffset, 0)
    }

    /// Still distinguishable from an interrupt, which is the whole point of
    /// splitting them: a client that sees this one really should complain.
    func testABrokenSentenceStillFailsTheJob() async {
        let result = await playerReported(.failed)
        XCTAssertEqual(result.state, .synthesisFailed)
    }

    /// The other order: the interrupt path gets there first. Its state and its
    /// position win, and the player's later report must not overwrite either.
    func testTheInterruptPathWinsWhenItGetsThereFirst() async {
        let manager = SpeechJobManager()
        let gate = PlaybackGate()
        await manager.configure(
            play: { _, onStart, _ in await gate.play(onStart: onStart) },
            prefetch: { _, _ in },
            halt: { SpokenPosition(sentence: 0, characterOffset: 11) })
        let job = await manager.enqueue(text: "First sentence. Second sentence.", voice: "af_heart")!
        await gate.waitForStarts(1)
        await gate.startNext()

        _ = await manager.stopSpeaking()
        await gate.finish(.interrupted(SpokenPosition(sentence: 0, characterOffset: 5)))
        try? await Task.sleep(for: .milliseconds(20))

        let result = await manager.result(id: job.id)!
        XCTAssertEqual(result.state, .interruptedByUser)
        XCTAssertEqual(result.characterOffset, 11)
    }
}

private actor PlaybackGate {
    private var starts = 0
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var completions: [CheckedContinuation<SpeechJobManager.SentenceOutcome, Never>] = []
    private var onStarts: [@Sendable () -> Void] = []
    private var onSyntheses: [@Sendable () -> Void] = []

    func play(onStart: @escaping @Sendable () -> Void,
              onSynthesized: @escaping @Sendable () -> Void = {}) async -> SpeechJobManager.SentenceOutcome {
        await withCheckedContinuation { continuation in
            completions.append(continuation)
            onStarts.append(onStart)
            onSyntheses.append(onSynthesized)
            starts += 1
            let ready = startWaiters.filter { $0.0 <= starts }
            startWaiters.removeAll { $0.0 <= starts }
            ready.forEach { $0.1.resume() }
        }
    }

    func startNext() {
        precondition(!onStarts.isEmpty)
        onStarts.removeFirst()()
    }

    /// Report that the sentence now playing has all of its audio — a distinct
    /// moment from `startNext` (sound began) and `finishNext` (sound ended).
    func synthesizeNext() {
        precondition(!onSyntheses.isEmpty)
        onSyntheses.removeFirst()()
    }

    func waitForStarts(_ count: Int) async {
        guard starts < count else { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func finish(_ outcome: SpeechJobManager.SentenceOutcome) {
        precondition(!completions.isEmpty)
        completions.removeFirst().resume(returning: outcome)
    }

    func finishNext() {
        precondition(!completions.isEmpty)
        completions.removeFirst().resume(returning: .finished)
    }
}

private actor ResultBox {
    private var result: SpeechJobManager.Result?
    private var waiters: [CheckedContinuation<SpeechJobManager.Result?, Never>] = []

    func store(_ result: SpeechJobManager.Result?) {
        self.result = result
        let waiters = self.waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume(returning: result) }
    }

    func current() -> SpeechJobManager.Result? { result }

    func waitForResult() async -> SpeechJobManager.Result? {
        if let result { return result }
        return await withCheckedContinuation { waiters.append($0) }
    }
}
