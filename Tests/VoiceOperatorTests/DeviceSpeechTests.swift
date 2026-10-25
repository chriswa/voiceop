import Foundation
import XCTest
@testable import VoiceOperator

/// Speech on a device that plays it itself: ported from Spaceterm's
/// `remote-speech.test.ts`, whose `RemoteSpeech` this replaced.
final class DeviceSpeechTests: XCTestCase {
    static let text = "The agent fixed the bug. It also added a test! Anything else?"

    /// What a device was sent, and a clock the test moves.
    final class Harness: @unchecked Sendable {
        let lock = NSLock()
        var _sent: [[String: Any]] = []
        var _synthesized: [(String, String)] = []
        var _now: Double = 1_000_000
        var ids = 0
        var sent: [[String: Any]] { lock.withLock { _sent } }
        var synthesized: [(String, String)] { lock.withLock { _synthesized } }
        var now: Double {
            get { lock.withLock { _now } }
            set { lock.withLock { _now = newValue } }
        }
        var speech: DeviceSpeech!
        var token = 0

        /// `seconds` of audio a sentence; `words` its timings, if any; nil from `fail` for a sentence that cannot be made.
        init(seconds: Double = 0.1, words: (@Sendable (String) -> [RemoteSynthesis.Word])? = nil,
             fail: (@Sendable (String) -> Bool)? = nil,
             makingMs: Int = 0) {
            speech = DeviceSpeech(deps: .init(
                synthesize: { [self] text, voice in
                    lock.withLock { _synthesized.append((text, voice)) }
                    if makingMs > 0 { try? await Task.sleep(for: .milliseconds(makingMs)) }
                    if fail?(text) == true { return nil }
                    let samples = Data(count: Int(seconds * 24_000) * 2)
                    return .init(wav: WAVFile(sampleRate: 24_000, samples: samples), words: words?(text))
                },
                now: { [self] in now },
                log: { _ in },
                newID: { [self] in lock.withLock { ids += 1; return "ds_\(ids)" } }))
            token = speech.connect(client: "spaceterm", device: "phone") { [self] message in
                lock.withLock { _sent.append(message) }
            }
        }

        func speak(_ text: String = DeviceSpeechTests.text) async -> SpeechJobManager.Result? {
            await speak([.init(text: text, voice: "af_heart")])
        }

        func speak(_ parts: [SpeechJobManager.Part]) async -> SpeechJobManager.Result? {
            if case .accepted(let result) = await speech.speak(parts: parts, client: "spaceterm", device: "phone") { return result }
            return nil
        }

        /// A progress report, as the device would send it, at `at` on the test's clock.
        func progress(_ id: String, _ index: Int, _ event: String, at: Double? = nil) {
            let before = now
            if let at { now = at }
            speech.progress(token, id: id, index: index, event: event)
            now = before
        }

        func sentences() -> [String] {
            sent.filter { $0["type"] as? String == "sentence" }.map { "\($0["id"]!):\($0["index"]!)" }
        }

        func status(_ id: String) async -> SpeechJobManager.Result? {
            await speech.status(id: id)
        }

        /// Until every sentence asked for has been sent, or the queue has nothing left to do.
        func settle() async {
            for _ in 0..<50 {
                await speech.queue.asyncIdle()
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
    }

    func testSendsEachSentenceInOrderAsAJob() async {
        let h = Harness()
        let job = await h.speak()
        XCTAssertEqual(job?.id, "ds_1")
        XCTAssertEqual(job?.state, .inProgress)
        XCTAssertEqual(job?.playbackState, .queued)
        await h.settle()
        XCTAssertEqual(h.sentences(), ["ds_1:0", "ds_1:1", "ds_1:2"])
        XCTAssertEqual(h.sent.first?["count"] as? Int, 3)
        XCTAssertEqual(h.sent.first?["sampleRate"] as? Int, 24_000)
    }

    func testSynthesizesADecimalWhole() async {
        let h = Harness()
        _ = await h.speak("Sampling costs 0.18 ms. That is 2.5 times faster.")
        await h.settle()
        XCTAssertEqual(h.synthesized.map { $0.0.trimmingCharacters(in: .whitespaces) },
                       ["Sampling costs 0.18 ms.", "That is 2.5 times faster."])
    }

    func testSpeakingOnceStartedHeardWhatFinishedAndCompletesOnTheLast() async {
        let h = Harness()
        _ = await h.speak()
        await h.settle()
        h.progress("ds_1", 0, "started")
        var status = await h.status("ds_1")
        XCTAssertEqual(status?.playbackState, .speaking)
        h.progress("ds_1", 0, "finished")
        status = await h.status("ds_1")
        XCTAssertEqual(status?.characterOffset, "The agent fixed the bug. ".utf16.count)
        h.progress("ds_1", 1, "finished")
        h.progress("ds_1", 2, "finished")
        status = await h.status("ds_1")
        XCTAssertEqual(status?.state, .completed)
        XCTAssertEqual(status?.characterOffset, Self.text.utf16.count)
        XCTAssertEqual(h.sent.last?["type"] as? String, "ended")
        XCTAssertEqual(h.sent.last?["state"] as? String, "completed")
    }

    func testALongPollWithACursorWakesOnTheNextChange() async {
        let h = Harness()
        let job = await h.speak()!
        async let poll = h.speech.status(id: "ds_1", wait: 30, since: job.version)
        try? await Task.sleep(for: .milliseconds(20))
        h.progress("ds_1", 0, "started")
        let woken = await poll
        XCTAssertEqual(woken?.playbackState, .speaking)
    }

    func testALongPollWithoutACursorWaitsForTheEnd() async {
        let h = Harness()
        _ = await h.speak("One sentence.")
        await h.settle()
        async let poll = h.speech.status(id: "ds_1", wait: 30)
        try? await Task.sleep(for: .milliseconds(20))
        h.progress("ds_1", 0, "started")
        h.progress("ds_1", 0, "finished")
        let ended = await poll
        XCTAssertEqual(ended?.state, .completed)
    }

    func testStoppingStopsTheDeviceAndReportsHowFarTheListenerGot() async {
        let h = Harness()
        _ = await h.speak()
        await h.settle()
        h.progress("ds_1", 0, "finished")
        let dropped = await h.speech.cancel(id: "ds_1")
        XCTAssertEqual(dropped?.state, .cancelledByClient)
        XCTAssertEqual(dropped?.characterOffset, 25)
        XCTAssertEqual(h.sent.last?["type"] as? String, "ended")
        XCTAssertEqual(h.sent.last?["state"] as? String, "cancelled_by_client")
    }

    func testASentenceThatCannotBeMadeFailsTheJob() async {
        let h = Harness(fail: { $0.hasPrefix("It") })
        _ = await h.speak()
        await h.settle()
        let status = await h.status("ds_1")
        XCTAssertEqual(status?.state, .synthesisFailed)
        XCTAssertEqual(h.sentences(), ["ds_1:0"])
    }

    func testASentenceTheDeviceCannotPlayFailsTheJob() async {
        let h = Harness()
        _ = await h.speak()
        await h.settle()
        h.progress("ds_1", 0, "failed")
        let status = await h.status("ds_1")
        XCTAssertEqual(status?.state, .synthesisFailed)
    }

    func testTheDeviceGoingAwayEndsItsJobWhereItGotTo() async {
        let h = Harness()
        _ = await h.speak()
        await h.settle()
        h.progress("ds_1", 0, "finished")
        h.speech.disconnect(h.token)
        let status = await h.status("ds_1")
        XCTAssertEqual(status?.state, .cancelledByClient)
        XCTAssertEqual(status?.characterOffset, 25)
        let again = await h.speech.speak(parts: [.init(text: "Hello.", voice: "af_heart")], client: "spaceterm", device: "phone")
        guard case .unknownDevice = again else { return XCTFail("spoke on a device that had gone") }
    }

    func testANewConnectionForTheSameDeviceReplacesTheOld() async {
        let h = Harness()
        _ = await h.speak()
        await h.settle()
        let newer = h.speech.connect(client: "spaceterm", device: "phone") { _ in }
        XCTAssertNotEqual(newer, h.token)
        XCTAssertTrue(h.sent.contains { $0["type"] as? String == "replaced" })
        let status = await h.status("ds_1")
        XCTAssertEqual(status?.state, .cancelledByClient)
    }

    func testUnknownDevice() async {
        let h = Harness()
        let answer = await h.speech.speak(parts: [.init(text: "Hello.", voice: "af_heart")], client: "spaceterm", device: "ipad")
        guard case .unknownDevice = answer else { return XCTFail("spoke on a device that never connected") }
    }

    func testPartsSentenceBySentenceEachInItsOwnVoice() async {
        let h = Harness()
        let parts: [SpeechJobManager.Part] = [.init(text: "Hello caller. How can I help?", voice: "af_bella"),
                                              .init(text: "Connecting you now.", voice: "am_adam")]
        _ = await h.speak(parts)
        await h.settle()
        XCTAssertEqual(h.synthesized.map { "\($0.0.trimmingCharacters(in: .whitespaces))|\($0.1)" },
                       ["Hello caller.|af_bella", "How can I help?|af_bella", "Connecting you now.|am_adam"])
        h.progress("ds_1", 1, "finished")
        let joined = SpeechJobManager.Part.joined(parts) as NSString
        var status = await h.status("ds_1")
        XCTAssertEqual(joined.substring(to: status!.characterOffset), "Hello caller. How can I help?")
        h.progress("ds_1", 2, "finished")
        status = await h.status("ds_1")
        XCTAssertEqual(status?.state, .completed)
        XCTAssertEqual(status?.characterOffset, joined.length)
    }

    // MARK: - A cut part way through a sentence

    static let question = "That's a change to the app, so an agent should do it. Want me to send it to Tessa, or start a new agent?"

    /// Each word a third of a second, the first at zero: Kokoro's timings, as aligned.
    static func timed(_ text: String) -> [RemoteSynthesis.Word] {
        let ns = text as NSString
        let regex = try! NSRegularExpression(pattern: "[\\w']+")
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).enumerated().map { i, match in
            .init(start: Double(i) / 3, end: Double(i + 1) / 3, characterEnd: NSMaxRange(match.range))
        }
    }

    /// What was heard of `question` by `offset`: the text up to it.
    static func heard(_ offset: Int) -> String {
        (question as NSString).substring(to: offset).trimmingCharacters(in: .whitespaces)
    }

    /// Play the first sentence (four seconds), then cut in `seconds` into the second.
    func cutInto(_ seconds: Double, timed: Bool) async -> String {
        let h = timed ? Harness(seconds: 4, words: { Self.timed($0) }) : Harness(seconds: 4)
        _ = await h.speak(Self.question)
        await h.settle()
        let now = h.now
        h.progress("ds_1", 0, "started", at: now - 4000 - seconds * 1000)
        h.progress("ds_1", 0, "finished", at: now - seconds * 1000)
        h.progress("ds_1", 1, "started", at: now - seconds * 1000)
        let dropped = await h.speech.cancel(id: "ds_1")
        return Self.heard(dropped!.characterOffset)
    }

    func testACutIsHeardUpToTheWordThatWasSounding() async {
        // "Tessa" is the seventh word of the second sentence: it starts at two seconds. The offset
        // lands just past the word sounding, which Spaceterm's `redactUnheard` marks as cut in on.
        let early = await cutInto(2.1, timed: true)
        XCTAssertEqual(early, "That's a change to the app, so an agent should do it. Want me to send it to Tessa")
        let later = await cutInto(2.4, timed: true)
        XCTAssertEqual(later, "That's a change to the app, so an agent should do it. Want me to send it to Tessa, or")
    }

    func testWithoutWordTimingsACutCountsNoneOfTheSentence() async {
        let heard = await cutInto(2.1, timed: false)
        XCTAssertEqual(heard, "That's a change to the app, so an agent should do it.")
    }

    func testAStatusMidSpeechReportsTheWordSoundingNow() async {
        let h = Harness(seconds: 4, words: { Self.timed($0) })
        _ = await h.speak(Self.question)
        await h.settle()
        let now = h.now
        h.progress("ds_1", 0, "started", at: now - 4000 - 2400)
        h.progress("ds_1", 0, "finished", at: now - 2400)
        h.progress("ds_1", 1, "started", at: now - 2400)
        let live = await h.status("ds_1")
        XCTAssertEqual(live?.state, .inProgress)
        XCTAssertEqual(Self.heard(live!.characterOffset), "That's a change to the app, so an agent should do it. Want me to send it to Tessa, or")
    }

    func testACutDatedBackCountsWhatWasHeardByThen() async {
        let h = Harness(seconds: 4, words: { Self.timed($0) })
        _ = await h.speak(Self.question)
        await h.settle()
        let now = h.now
        // The first sentence finished, and the second began, while the Mac was still checking what they said over it.
        h.progress("ds_1", 0, "started", at: now - 6400)
        h.progress("ds_1", 0, "finished", at: now - 2400)
        h.progress("ds_1", 1, "started", at: now - 2400)
        // They began 3.4 s into the first sentence, as "do" (3.33 s) was sounding.
        let dropped = await h.speech.cancel(id: "ds_1", heardUntil: now - 3000)
        XCTAssertEqual(Self.heard(dropped!.characterOffset), "That's a change to the app, so an agent should do")
    }

    func testACutDatedBeforeTheReplyBeganCountsNoneOfIt() async {
        let h = Harness(seconds: 4, words: { Self.timed($0) })
        _ = await h.speak(Self.question)
        await h.settle()
        let now = h.now
        h.progress("ds_1", 0, "started", at: now - 1000)
        let dropped = await h.speech.cancel(id: "ds_1", heardUntil: now - 1500)
        XCTAssertEqual(dropped?.characterOffset, 0)
    }

    func testAnotherConnectionCannotReportOnAJobItDoesNotOwn() async {
        let h = Harness()
        _ = await h.speak()
        await h.settle()
        let other = h.speech.connect(client: "spaceterm", device: "ipad") { _ in }
        h.speech.progress(other, id: "ds_1", index: 0, event: "started")
        let status = await h.status("ds_1")
        XCTAssertEqual(status?.playbackState, .queued)
    }

    // MARK: - Two jobs at once

    func testTheSecondJobIsSentOnlyAfterEverySentenceOfTheFirst() async {
        let h = Harness()
        async let first = h.speak("Let me check. One moment.")
        async let second = h.speak("Kevin finished. The tests pass.")
        _ = await (first, second)
        await h.settle()
        let order = h.sentences()
        XCTAssertEqual(order.count, 4)
        XCTAssertEqual(Set(order.prefix(2).map { $0.prefix(4) }).count, 1, "one job's sentences together: \(order)")
    }

    func testAJobStoppedWhileItWaitedIsNeverMade() async {
        let h = Harness(makingMs: 100)
        _ = await h.speak("Let me check.")
        let second = await h.speak("Never heard.")!
        _ = await h.speech.cancel(id: second.id)
        await h.settle()
        XCTAssertEqual(h.synthesized.map { $0.0 }, ["Let me check."])
    }

    // MARK: - A restart waits

    func testBusyWhileAJobIsInProgress() async {
        let h = Harness()
        XCTAssertFalse(h.speech.isSpeaking)
        _ = await h.speak("One sentence.")
        XCTAssertTrue(h.speech.isSpeaking)
        await h.settle()
        h.progress("ds_1", 0, "finished")
        _ = await h.status("ds_1")
        XCTAssertFalse(h.speech.isSpeaking)
    }
}

extension DispatchQueue {
    /// Returns once everything queued before it has run.
    func asyncIdle() async {
        await withCheckedContinuation { continuation in async { continuation.resume() } }
    }
}
