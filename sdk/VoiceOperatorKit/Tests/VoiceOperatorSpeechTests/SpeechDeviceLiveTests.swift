import Foundation
import XCTest
import VoiceOperatorSpeech

/// A tiny blocking newline-JSON connection to a Unix socket, for the live test.
private final class LineSocket {
    private let fd: Int32
    private var pending = Data()

    init?(path: String, timeoutSeconds: Int = 5) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, byte) in bytes.enumerated() { raw[i] = byte }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { close(fd); return nil }
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit { close(fd) }

    func send(_ line: String) {
        let data = Array((line + "\n").utf8)
        var offset = 0
        while offset < data.count {
            let n = data[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { return }
            offset += n
        }
    }

    /// The next line, or nil on timeout or close.
    func readLine() -> String? {
        while true {
            if let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<newline]
                pending = Data(pending[(newline + 1)...])
                return String(decoding: line, as: UTF8.self)
            }
            var buffer = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { return nil }
            pending.append(contentsOf: buffer[0..<n])
        }
    }
}

/// Against the running Voice Operator, when there is one: a job spoken on a
/// device that only says it played it. Kokoro makes the audio; nothing is heard.
final class SpeechDeviceLiveTests: XCTestCase {
    private let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/VoiceOperator")

    private func http(_ method: String, _ path: String, _ body: [String: Any]? = nil) throws -> (Int, [String: Any]) {
        let discovery = try JSONSerialization.jsonObject(with: Data(contentsOf: support.appendingPathComponent("speech-service.json"))) as! [String: Any]
        guard (discovery["version"] as? Int ?? 0) >= 17 else { throw XCTSkip("this Voice Operator predates speech on a device") }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(discovery["port"]!)\(path)")!)
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var answer: (Int, [String: Any]) = (0, [:])
        URLSession.shared.dataTask(with: request) { data, response, _ in
            answer = ((response as? HTTPURLResponse)?.statusCode ?? 0,
                      data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:])
            done.signal()
        }.resume()
        done.wait()
        return answer
    }

    private func speaker() throws -> (SpeechDevice, LineSocket, () -> [SpeechDeviceEvent]) {
        let path = support.appendingPathComponent("hands-free.sock").path
        guard let socket = LineSocket(path: path, timeoutSeconds: 30) else { throw XCTSkip("Voice Operator is not listening on \(path)") }
        var events: [SpeechDeviceEvent] = []
        let device = SpeechDevice(client: "sdk-test", device: "sdk-test-speaker") { socket.send($0) }
        device.onEvent = { events.append($0) }
        device.transportOpened()
        guard let line = socket.readLine() else { throw XCTSkip("no answer to the speaker's hello") }
        device.receive(line: line)
        guard events.first == .welcome else { throw XCTSkip("speaker hello not welcomed: \(line)") }
        return (device, socket, { events })
    }

    func testAJobPlayedToTheEndCompletes() throws {
        let (device, socket, events) = try speaker()
        let text = "One small sentence. And a second one."
        let (status, job) = try http("POST", "/v1/speech", ["text": text, "client": "sdk-test", "device": "sdk-test-speaker"])
        if status == 403 { throw XCTSkip("Voice Operator is in incognito mode") }
        XCTAssertEqual(status, 202, "\(job)")
        let id = try XCTUnwrap(job["id"] as? String)
        XCTAssertTrue(id.hasPrefix("ds_"))
        var played = 0
        while played < 2, let line = socket.readLine() {
            device.receive(line: line)
            guard case .sentence(let sentence) = events().last else { continue }
            XCTAssertEqual(sentence.id, id)
            XCTAssertEqual(sentence.count, 2)
            XCTAssertGreaterThan(sentence.pcm.count, 1000)
            device.started(id: id, index: sentence.index)
            device.finished(id: id, index: sentence.index)
            played += 1
        }
        let (code, done) = try http("GET", "/v1/speech/\(id)?wait=5")
        XCTAssertEqual(code, 200, "\(done)")
        XCTAssertEqual(done["state"] as? String, "completed")
        XCTAssertEqual(done["character_offset"] as? Int, text.utf16.count)
    }

    func testAJobStoppedPartWayReportsWhatWasHeard() throws {
        let (device, socket, events) = try speaker()
        let (status, job) = try http("POST", "/v1/speech", ["text": "First sentence here. Second sentence never heard.",
                                                           "client": "sdk-test", "device": "sdk-test-speaker"])
        if status == 403 { throw XCTSkip("Voice Operator is in incognito mode") }
        let id = try XCTUnwrap(job["id"] as? String)
        while let line = socket.readLine() {
            device.receive(line: line)
            if case .sentence(let sentence) = events().last, sentence.index == 0 { break }
        }
        device.started(id: id, index: 0)
        device.finished(id: id, index: 0)
        Thread.sleep(forTimeInterval: 0.2)
        let (code, stopped) = try http("DELETE", "/v1/speech/\(id)")
        XCTAssertEqual(code, 410, "\(stopped)")
        XCTAssertEqual(stopped["state"] as? String, "cancelled_by_client")
        XCTAssertEqual(stopped["character_offset"] as? Int, "First sentence here. ".utf16.count)
        while let line = socket.readLine() {
            device.receive(line: line)
            if case .ended = events().last { break }
        }
        XCTAssertEqual(events().last, .ended(id: id, state: "cancelled_by_client", characterOffset: "First sentence here. ".utf16.count))
    }

    func testAnUnknownDeviceIs404() throws {
        let (status, body) = try http("POST", "/v1/speech", ["text": "Nobody hears this.", "client": "sdk-test", "device": "no-such-device"])
        if status == 403 { throw XCTSkip("Voice Operator is in incognito mode") }
        XCTAssertEqual(status, 404)
        XCTAssertEqual(body["error"] as? String, "unknown_device")
    }
}
