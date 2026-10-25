import Foundation
import XCTest
import VoiceOperatorSpeech

final class SpeechDeviceTests: XCTestCase {
    private func device() -> (SpeechDevice, () -> [[String: Any]], () -> [SpeechDeviceEvent]) {
        var lines: [String] = []
        var events: [SpeechDeviceEvent] = []
        let device = SpeechDevice(client: "spaceterm", device: "phone") { lines.append($0) }
        device.onEvent = { events.append($0) }
        let sent = { lines.map { try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] } }
        return (device, sent, { events })
    }

    func testSaysHelloAsASpeakerOnEachOpen() {
        let (device, sent, _) = device()
        device.transportOpened()
        device.transportClosed()
        device.transportOpened()
        XCTAssertEqual(sent().count, 2)
        XCTAssertEqual(sent()[0]["type"] as? String, "hello")
        XCTAssertEqual(sent()[0]["role"] as? String, "speaker")
        XCTAssertEqual(sent()[0]["client"] as? String, "spaceterm")
        XCTAssertEqual(sent()[0]["device"] as? String, "phone")
        XCTAssertEqual(sent()[0]["protocol"] as? Int, 1)
    }

    func testParsesSentencesAndEnds() {
        let (device, _, events) = device()
        let pcm = Data([1, 0, 2, 0])
        device.receive(line: #"{"type":"welcome","protocol":1}"#)
        device.receive(line: #"{"type":"sentence","id":"ds_1","index":0,"count":2,"sampleRate":24000,"pcm":"\#(pcm.base64EncodedString())","sentAt":5}"#)
        device.receive(line: #"{"type":"ended","id":"ds_1","state":"cancelled_by_client","characterOffset":12}"#)
        device.receive(line: #"{"type":"replaced"}"#)
        device.receive(line: #"{"type":"refused","error":"invalid_device"}"#)
        XCTAssertEqual(events(), [
            .welcome,
            .sentence(SpeechSentence(id: "ds_1", index: 0, count: 2, sampleRate: 24_000, pcm: pcm, sentAt: 5)),
            .ended(id: "ds_1", state: "cancelled_by_client", characterOffset: 12),
            .replaced,
            .refused("invalid_device"),
        ])
    }

    func testAMalformedSentenceIsAnError() {
        let (device, _, events) = device()
        device.receive(line: #"{"type":"sentence","id":"ds_1","index":0}"#)
        guard case .error = events().first else { return XCTFail("\(events())") }
    }

    func testReportsProgressOnlyWhileConnected() {
        let (device, sent, _) = device()
        device.started(id: "ds_1", index: 0)
        XCTAssertTrue(sent().isEmpty)
        device.transportOpened()
        device.started(id: "ds_1", index: 0)
        device.finished(id: "ds_1", index: 0)
        device.failed(id: "ds_1", index: 1)
        XCTAssertEqual(sent().dropFirst().map { "\($0["type"]!) \($0["id"]!) \($0["index"]!) \($0["event"]!)" },
                       ["progress ds_1 0 started", "progress ds_1 0 finished", "progress ds_1 1 failed"])
    }
}
