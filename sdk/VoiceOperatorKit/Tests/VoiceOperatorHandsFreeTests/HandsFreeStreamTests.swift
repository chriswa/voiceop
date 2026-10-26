import Foundation
import XCTest
@testable import VoiceOperatorHandsFree

/// A transport that records what the stream sends.
private final class FakeTransport {
    var lines: [[String: Any]] = []
    lazy var stream = HandsFreeStream(client: "spaceterm", device: "iPhone") { [unowned self] line in
        XCTAssertFalse(line.contains("\n"))
        self.lines.append(try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any])
    }
    var events: [HandsFreeEvent] = []
    var raw: [String] = []

    init() {
        stream.onEvent = { [unowned self] in self.events.append($0) }
        stream.onRawEvent = { [unowned self] in self.raw.append($0) }
    }

    func take() -> [[String: Any]] { defer { lines = [] }; return lines }
    func types(_ sent: [[String: Any]]) -> [String] { sent.map { $0["type"] as! String } }
    func vo(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        stream.receive(line: String(data: data, encoding: .utf8)!)
    }
    func audioAts(_ sent: [[String: Any]]) -> [Int] { sent.filter { $0["type"] as? String == "audio" }.map { $0["at"] as! Int } }
}

/// `n` samples of value `v`, s16le.
private func pcm(_ n: Int, _ v: Int16 = 0) -> Data {
    var data = Data()
    for _ in 0..<n { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    return data
}

final class HandsFreeStreamTests: XCTestCase {
    func testHelloThenStartThenSession() {
        let t = FakeTransport()
        t.stream.start()
        XCTAssertTrue(t.stream.isOn)
        XCTAssertTrue(t.take().isEmpty, "nothing goes before the transport is open")
        t.stream.transportOpened()
        let sent = t.take()
        XCTAssertEqual(t.types(sent), ["hello", "start"])
        XCTAssertEqual(sent[0]["protocol"] as? Int, 1)
        XCTAssertEqual(sent[0]["client"] as? String, "spaceterm")
        XCTAssertEqual(sent[0]["role"] as? String, "stream")
        XCTAssertEqual(sent[0]["device"] as? String, "iPhone")
        XCTAssertEqual(sent[1]["sampleRate"] as? Int, 16000)
        XCTAssertEqual(sent[1]["codec"] as? String, "pcm16")
        t.vo(["type": "welcome", "protocol": 1])
        t.vo(["type": "session", "source": "stream", "session": "abc"])
        XCTAssertEqual(t.stream.sessionID, "abc")
        XCTAssertEqual(t.events, [.session("abc")])
        XCTAssertEqual(t.raw.count, 1, "welcome is bookkeeping, not forwarded")
    }

    func testStartWhileConnectedSendsStartOnly() {
        let t = FakeTransport()
        t.stream.transportOpened()
        XCTAssertEqual(t.types(t.take()), ["hello"])
        t.stream.start()
        XCTAssertEqual(t.types(t.take()), ["start"])
        t.stream.start()
        XCTAssertTrue(t.take().isEmpty, "already on")
    }

    func testOtherSampleRatesAreRefused() {
        let t = FakeTransport()
        t.stream.transportOpened()
        _ = t.take()
        t.stream.start(sampleRate: 48000)
        XCTAssertFalse(t.stream.isOn)
        XCTAssertTrue(t.take().isEmpty)
        guard case .error = t.events.first else { return XCTFail("expected an error event") }
    }

    func testAudioIsNumberedAndWaitsForTheSession() {
        let t = FakeTransport()
        t.stream.transportOpened()
        t.stream.start()
        _ = t.take()
        t.stream.audio(pcm(1600))
        t.stream.audio(pcm(1600))
        XCTAssertTrue(t.take().isEmpty, "no session yet")
        t.vo(["type": "session", "source": "stream", "session": "s1"])
        XCTAssertEqual(t.audioAts(t.take()), [0, 1600], "what was waiting goes as soon as the session is there")
        t.stream.audio(pcm(800))
        t.stream.audio(pcm(1600))
        let sent = t.take()
        XCTAssertEqual(t.audioAts(sent), [3200, 4000])
        let data = Data(base64Encoded: sent[0]["data"] as! String)!
        XCTAssertEqual(data.count, 1600)
    }

    func testOddByteChunksCarryOver() {
        let t = FakeTransport()
        t.stream.transportOpened()
        t.stream.start()
        t.vo(["type": "session", "source": "stream", "session": "s1"])
        _ = t.take()
        t.stream.audio(Data([1, 2, 3]))
        t.stream.audio(Data([4, 5, 6]))
        let sent = t.take()
        XCTAssertEqual(t.audioAts(sent), [0, 1])
        XCTAssertEqual(Data(base64Encoded: sent[1]["data"] as! String), Data([3, 4, 5, 6]))
    }

    func testAckTrimsAndResumeReplaysFromAt() {
        let t = FakeTransport()
        t.stream.transportOpened()
        t.stream.start()
        t.vo(["type": "session", "source": "stream", "session": "s1"])
        for _ in 0..<4 { t.stream.audio(pcm(1600)) }   // 0, 1600, 3200, 4800
        t.vo(["type": "ack", "at": 3200])
        XCTAssertEqual(t.raw.count, 1, "ack is not forwarded")
        t.stream.transportClosed()
        t.stream.audio(pcm(1600))                       // 6400, while away
        _ = t.take()
        XCTAssertEqual(t.stream.sessionID, "s1", "a dropout keeps the session")

        t.stream.transportOpened()
        let reopened = t.take()
        XCTAssertEqual(t.types(reopened), ["hello", "resume"])
        XCTAssertEqual(reopened[1]["session"] as? String, "s1")
        t.stream.audio(pcm(1600))                       // 8000, before `resumed`
        XCTAssertTrue(t.take().isEmpty, "audio waits for resumed")

        // VO got part of the chunk at 3200.
        t.vo(["type": "resumed", "session": "s1", "at": 4000])
        let replay = t.take()
        XCTAssertEqual(t.audioAts(replay), [4000, 4800, 6400, 8000])
        XCTAssertEqual(Data(base64Encoded: replay[0]["data"] as! String)!.count, 800 * 2, "the chunk's front, already received, is not sent")
        XCTAssertFalse(t.raw.contains { $0.contains("resumed") })
    }

    func testResumeBeforeTheAckedPointSendsFromTheOldestKept() {
        let t = FakeTransport()
        t.stream.transportOpened()
        t.stream.start()
        t.vo(["type": "session", "source": "stream", "session": "s1"])
        for _ in 0..<3 { t.stream.audio(pcm(1600)) }
        t.vo(["type": "ack", "at": 3200])
        t.stream.transportClosed()
        t.stream.transportOpened()
        _ = t.take()
        t.vo(["type": "resumed", "session": "s1", "at": 3200])
        XCTAssertEqual(t.audioAts(t.take()), [3200])
    }

    func testBufferIsCappedAtSixtySeconds() {
        let t = FakeTransport()
        t.stream.transportOpened()
        t.stream.start()
        t.vo(["type": "session", "source": "stream", "session": "s1"])
        t.stream.transportClosed()
        for _ in 0..<700 { t.stream.audio(pcm(1600)) }   // 70 s while away
        t.stream.transportOpened()
        _ = t.take()
        t.vo(["type": "resumed", "session": "s1", "at": 0])
        let ats = t.audioAts(t.take())
        XCTAssertEqual(ats.count, 600)
        XCTAssertEqual(ats.first, 100 * 1600, "the oldest ten seconds were dropped")
        XCTAssertEqual(ats.last, 699 * 1600)
    }

    func testPlayingSentOnChangeAndAgainAfterResume() {
        let t = FakeTransport()
        t.stream.playing(on: true, speech: true, echoCancelled: true)
        t.stream.transportOpened()
        t.stream.start()
        XCTAssertEqual(t.types(t.take()), ["hello", "start"], "playing waits for a session")
        t.vo(["type": "session", "source": "stream", "session": "s1"])
        let first = t.take()
        XCTAssertEqual(t.types(first), ["playing"], "a new session hears what is playing")
        XCTAssertEqual(first[0]["speech"] as? Bool, true)
        t.stream.playing(on: true, speech: true, echoCancelled: true)
        XCTAssertTrue(t.take().isEmpty, "unchanged")
        t.stream.playing(on: false, speech: false, echoCancelled: true)
        XCTAssertEqual(t.types(t.take()), ["playing"])
        t.stream.playing(on: true, speech: false, echoCancelled: false)
        t.stream.transportClosed()
        t.stream.transportOpened()
        _ = t.take()
        t.vo(["type": "resumed", "session": "s1", "at": 0])
        let after = t.take()
        XCTAssertEqual(t.types(after), ["playing"])
        XCTAssertEqual(after[0]["on"] as? Bool, true)
        XCTAssertEqual(after[0]["echoCancelled"] as? Bool, false)
    }

    func testSessionEndedClearsTheSession() {
        let t = FakeTransport()
        t.stream.transportOpened()
        t.stream.start()
        t.vo(["type": "session", "source": "stream", "session": "s1"])
        _ = t.take()
        // Ended by Voice Operator while live (not a resume refused: that starts afresh).
        t.vo(["type": "session-ended", "why": "lost"])
        XCTAssertNil(t.stream.sessionID)
        XCTAssertFalse(t.stream.isOn)
        XCTAssertEqual(t.events.last, .ended("lost"))
        t.stream.audio(pcm(1600))
        XCTAssertTrue(t.take().isEmpty, "off: audio is not kept or sent")
        // A later reconnect neither resumes nor starts.
        t.stream.transportClosed()
        t.stream.transportOpened()
        XCTAssertEqual(t.types(t.take()), ["hello"])
    }

    func testVoiceOperatorRestartingKeepsItOnAndStartsAfreshOnTheNextConnection() {
        let t = FakeTransport()
        t.stream.transportOpened()
        t.stream.start()
        t.vo(["type": "session", "source": "stream", "session": "s1"])
        t.vo(["type": "session-ended", "why": "restarting"])
        XCTAssertNil(t.stream.sessionID)
        XCTAssertTrue(t.stream.isOn)
        t.stream.transportClosed()
        _ = t.take()
        t.stream.transportOpened()
        XCTAssertEqual(t.types(t.take()), ["hello", "start"])
    }

    func testAResumeTooLateStartsAFreshSessionWithoutTellingTheApp() {
        let t = FakeTransport()
        t.stream.transportOpened()
        t.stream.start()
        t.vo(["type": "session", "source": "stream", "session": "s1"])
        t.stream.transportClosed()
        t.stream.transportOpened()
        XCTAssertEqual(t.types(t.take()).suffix(1), ["resume"])
        let events = t.events.count
        t.vo(["type": "session-ended", "why": "lost"])
        XCTAssertTrue(t.stream.isOn)
        XCTAssertEqual(t.types(t.take()), ["start"])
        XCTAssertEqual(t.events.count, events, "the app is not told hands-free ended")
        t.vo(["type": "session", "source": "stream", "session": "s2"])
        XCTAssertEqual(t.stream.sessionID, "s2")
    }

    func testStopSendsStopAndForgets() {
        let t = FakeTransport()
        t.stream.transportOpened()
        t.stream.start()
        t.vo(["type": "session", "source": "stream", "session": "s1"])
        t.stream.audio(pcm(1600))
        _ = t.take()
        t.stream.stop()
        XCTAssertEqual(t.types(t.take()), ["stop"])
        XCTAssertNil(t.stream.sessionID)
        XCTAssertFalse(t.stream.isOn)
        t.stream.stop()
        XCTAssertTrue(t.take().isEmpty)
        // On again: a new session, numbered from 0.
        t.stream.start()
        t.vo(["type": "session", "source": "stream", "session": "s2"])
        _ = t.take()
        t.stream.audio(pcm(1600))
        XCTAssertEqual(t.audioAts(t.take()), [0])
    }

    func testStopWhileAwaitingSessionSendsStop() {
        let t = FakeTransport()
        t.stream.transportOpened()
        t.stream.start()
        _ = t.take()
        t.stream.stop()
        XCTAssertEqual(t.types(t.take()), ["stop"])
    }

    func testRestartAfterADropBeforeTheSessionCame() {
        let t = FakeTransport()
        t.stream.transportOpened()
        t.stream.start()
        t.stream.transportClosed()
        _ = t.take()
        t.stream.transportOpened()
        XCTAssertEqual(t.types(t.take()), ["hello", "start"])
    }

    func testEventsAreParsed() {
        let t = FakeTransport()
        t.vo(["type": "state", "phase": "hearing", "conversation": true, "closesAt": NSNull(), "checking": false, "pending": true])
        t.vo(["type": "state", "phase": "listening", "conversation": false, "closesAt": NSNull(), "checking": false,
              "pending": false, "standingAside": "speech"])
        t.vo(["type": "gauge", "quietSince": 1000.5, "patienceMs": 1200, "mini": 0.31, "miniPeak": NSNull(), "miniThreshold": 0.5])
        t.vo(["type": "cue", "name": "dictationStart", "haptic": "tap"])
        t.vo(["type": "cue", "name": "ready"])
        t.vo(["type": "duck", "on": true])
        t.vo(["type": "cut-in", "msAgo": 300, "at": 12345.0])
        t.vo(["type": "transcript", "text": "control hello", "trigger": "control", "interrupted": false, "reason": "turn", "shutdown": false])
        t.vo(["type": "transcript", "text": "", "trigger": NSNull(), "interrupted": true, "reason": "silence", "shutdown": true])
        t.vo(["type": "refused", "error": "no_client", "detail": "x"])
        t.vo(["type": "error", "error": "bad_json"])
        t.vo(["type": "something-new"])
        XCTAssertEqual(t.events, [
            .state(phase: "hearing", conversation: true, closesAt: nil, checking: false, pending: true),
            .state(phase: "listening", conversation: false, closesAt: nil, checking: false, pending: false, standingAside: "speech"),
            .gauge(quietSince: 1000.5, patienceMs: 1200, mini: 0.31, miniPeak: nil, miniThreshold: 0.5),
            .cue(name: "dictationStart", haptic: "tap"),
            .cue(name: "ready", haptic: nil),
            .duck(true),
            .cutIn(msAgo: 300, at: 12345),
            .transcript(text: "control hello", trigger: "control", interrupted: false, reason: "turn", shutdown: false),
            .transcript(text: "", trigger: nil, interrupted: true, reason: "silence", shutdown: true),
            .refused("no_client"),
            .error("bad_json"),
        ])
        XCTAssertEqual(t.raw.count, 12, "every line but bookkeeping is forwarded raw, unknown ones too")
    }
}
