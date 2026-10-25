import Foundation
import XCTest
import VoiceOperatorHandsFree

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

/// Against the running Voice Operator, when there is one. Sends only silence.
final class HandsFreeLiveTests: XCTestCase {
    func testStreamSessionAgainstVoiceOperator() throws {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoiceOperator/hands-free.sock").path
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("Voice Operator's hands-free socket is not there") }
        guard let control = LineSocket(path: path) else { throw XCTSkip("Voice Operator is not listening on \(path)") }
        control.send(#"{"type":"hello","protocol":1,"client":"sdk-test","trigger":"computer"}"#)
        let welcome = try XCTUnwrap(control.readLine(), "no answer to the control hello")
        guard welcome.contains("\"welcome\"") else { throw XCTSkip("control hello not welcomed: \(welcome)") }

        let socket = try XCTUnwrap(LineSocket(path: path))
        let stream = HandsFreeStream(client: "sdk-test", device: "sdk-test-stream") { socket.send($0) }
        var events: [HandsFreeEvent] = []
        stream.onEvent = { events.append($0) }

        stream.start()
        stream.transportOpened()
        func pump(until done: () -> Bool) {
            while !done(), let line = socket.readLine() { stream.receive(line: line) }
        }
        pump { stream.sessionID != nil || events.contains { if case .ended = $0 { true } else { false } } }
        if case .ended("incognito") = events.last { throw XCTSkip("Voice Operator is in incognito mode") }
        XCTAssertNotNil(stream.sessionID, "no session: \(events)")

        // One second of silence, a tenth at a time.
        for _ in 0..<10 { stream.audio(Data(count: 3200)) }
        pump { events.contains { if case .state = $0 { true } else { false } } }
        XCTAssertTrue(events.contains { if case .session = $0 { true } else { false } }, "\(events)")
        XCTAssertTrue(events.contains { if case .state = $0 { true } else { false } }, "\(events)")

        stream.stop()
        pump { events.contains { if case .ended = $0 { true } else { false } } }
    }

    /// Speech through the stream end to end, with the connection dropped and
    /// resumed mid-sentence: `say`-made "Computer, …" must come back as the
    /// transcript. One real transcription, so only when asked:
    /// `VOICEOP_SDK_SPEECH_TEST=1 swift test --filter testSpeechWithADropoutComesBackAsTheTranscript`.
    func testSpeechWithADropoutComesBackAsTheTranscript() throws {
        guard ProcessInfo.processInfo.environment["VOICEOP_SDK_SPEECH_TEST"] == "1" else {
            throw XCTSkip("set VOICEOP_SDK_SPEECH_TEST=1 to run a real transcription")
        }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoiceOperator/hands-free.sock").path
        let control = try XCTUnwrap(LineSocket(path: path))
        control.send(#"{"type":"hello","protocol":1,"client":"sdk-speech","trigger":"computer"}"#)
        XCTAssertTrue(try XCTUnwrap(control.readLine()).contains("welcome"))

        // "Computer, what is Kevin working on?", 16 kHz s16le.
        let dir = FileManager.default.temporaryDirectory
        let aiff = dir.appendingPathComponent("sdk-speech.aiff"), wav = dir.appendingPathComponent("sdk-speech.wav")
        for (tool, args) in [("/usr/bin/say", ["-o", aiff.path, "Computer, what is Kevin working on?"]),
                             ("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path])] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
            try p.run(); p.waitUntilExit()
        }
        let speech = try Data(contentsOf: wav).dropFirst(44)
        func hiss(_ ms: Int) -> Data {
            var d = Data(count: ms * 32)
            d.withUnsafeMutableBytes { raw in for i in 0..<(ms * 16) { raw.storeBytes(of: Int16.random(in: -8...8), toByteOffset: i * 2, as: Int16.self) } }
            return d
        }

        // The stream is confined to one queue; each connection's reader hops onto it.
        final class Shared: @unchecked Sendable {
            var socket: LineSocket
            var transcript: String?
            var resumed = false
            var generation = 0
            var stream: HandsFreeStream!
            init(_ socket: LineSocket) { self.socket = socket }
        }
        let queue = DispatchQueue(label: "sdk-speech")
        let shared = Shared(try XCTUnwrap(LineSocket(path: path, timeoutSeconds: 1)))
        shared.stream = HandsFreeStream(client: "sdk-speech", device: "sdk-speech") { line in shared.socket.send(line) }
        shared.stream.onEvent = { event in
            if case .transcript(let text, _, _, _, _) = event { shared.transcript = text }
        }
        func read(_ connection: LineSocket, _ mine: Int) {
            Thread.detachNewThread {
                while true {
                    let line = connection.readLine()
                    let current = queue.sync { shared.generation == mine }
                    if !current { return }
                    guard let line else { continue }
                    queue.sync {
                        if line.contains("\"resumed\"") { shared.resumed = true }
                        shared.stream.receive(line: line)
                    }
                }
            }
        }
        queue.sync { shared.stream.start(); shared.stream.transportOpened() }
        read(shared.socket, 0)
        func send(_ data: Data, realTime: Bool) {
            var i = data.startIndex
            while i < data.endIndex {
                let chunk = Data(data[i..<min(i + 3200, data.endIndex)])
                queue.sync { shared.stream.audio(chunk) }
                i += chunk.count
                if realTime { Thread.sleep(forTimeInterval: 0.1) }
            }
        }
        send(hiss(16_500), realTime: false)
        send(hiss(1_500), realTime: true)
        let half = speech.startIndex + (speech.count / 2) & ~1
        send(Data(speech[..<half]), realTime: true)
        // The phone's connection drops mid-sentence; audio keeps coming, buffered, and the SDK resumes on a new one.
        queue.sync {
            shared.generation += 1
            shared.stream.transportClosed()
        }
        send(Data(speech[half...]), realTime: true)
        let next = try XCTUnwrap(LineSocket(path: path, timeoutSeconds: 1))
        queue.sync { shared.socket = next; shared.stream.transportOpened() }
        read(next, 1)
        for _ in 0..<150 where queue.sync(execute: { shared.transcript == nil }) { send(hiss(100), realTime: true) }
        XCTAssertTrue(queue.sync { shared.resumed }, "the stream did not resume")
        XCTAssertEqual(queue.sync { shared.transcript }, "Computer, what is Kevin working on?")
        queue.sync { shared.stream.stop(); shared.generation += 1 }
    }
}
