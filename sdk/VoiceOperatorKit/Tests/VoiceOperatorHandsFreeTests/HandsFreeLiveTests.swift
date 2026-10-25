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
}
