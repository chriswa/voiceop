import Foundation

/// `--hands-free-test [text]`: a hands-free client end to end, against the
/// running app. It registers the trigger word "computer", streams `say`-made
/// speech as a phone would — silence while the conversation window that
/// turning it on opens runs out, then "Computer, <text>" — and prints every
/// message Voice Operator sends back, until the transcript arrives.
///
/// Everything a phone's session exercises runs for real: the socket protocol,
/// Silero, the trigger-word check on Apple's model, the user's transcription
/// provider, and the end-of-turn decision. Nothing is played aloud and the
/// microphone is not touched. One transcription (endpoint etiquette).
enum HandsFreeTestClient {
    static func run(text: String) async -> Int32 {
        let trigger = "computer"
        let speech: [Int16]
        do { speech = try synthesize("\(trigger.capitalized), \(text)") } catch {
            fail("could not synthesize: \(error)")
            return 1
        }
        let socket = HandsFreeService.socketURL.path
        guard let control = LineSocket(path: socket), let stream = LineSocket(path: socket) else {
            fail("no hands-free socket at \(socket) — is Voice Operator running, and new enough?")
            return 1
        }
        control.send(["type": "hello", "protocol": HandsFreeService.protocolVersion, "client": "hands-free-test",
                      "trigger": trigger])
        guard let welcome = control.receive(), welcome["type"] as? String == "welcome" else {
            fail("control hello refused")
            return 1
        }
        stream.send(["type": "hello", "protocol": HandsFreeService.protocolVersion, "client": "hands-free-test",
                     "role": "stream", "device": "test"])
        _ = stream.receive()
        stream.send(["type": "start", "sampleRate": HandsFreeAudio.sampleRate, "codec": "pcm16"])

        let reader = Task.detached { () -> String? in
            while let message = stream.receive() {
                print("← \(compact(message))")
                if message["type"] as? String == "transcript" { return message["text"] as? String ?? "" }
                if message["type"] as? String == "session-ended" { return nil }
            }
            return nil
        }
        // The window that turning it on opens runs out on audio, not the clock: send its silence fast.
        let rate = HandsFreeAudio.sampleRate
        var at = 0
        func send(_ samples: [Int16], realTime: Bool) async {
            var i = 0
            while i < samples.count {
                let chunk = Array(samples[i..<min(i + rate / 10, samples.count)])
                stream.send(["type": "audio", "at": at, "data": HandsFreeService.data(chunk).base64EncodedString()])
                at += chunk.count
                i += chunk.count
                if realTime { try? await Task.sleep(for: .milliseconds(100)) }
            }
        }
        let hiss = { (ms: Int) in (0..<(ms * rate / 1000)).map { _ in Int16.random(in: -8...8) } }
        await send(hiss(16_500), realTime: false)
        await send(hiss(1_500), realTime: true)
        await send(speech, realTime: true)
        let tail = Task { await send(hiss(25_000), realTime: true) }
        let transcript = await reader.value
        tail.cancel()
        stream.send(["type": "stop"])
        control.close()
        stream.close()
        guard let words = transcript, !words.isEmpty else {
            fail("no transcript")
            return 1
        }
        print("transcript: \(words)")
        return 0
    }

    private static func synthesize(_ text: String) throws -> [Int16] {
        let tmp = FileManager.default.temporaryDirectory
        let aiff = tmp.appendingPathComponent("vo-hands-free-\(UUID().uuidString).aiff")
        let wav = aiff.deletingPathExtension().appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: aiff); try? FileManager.default.removeItem(at: wav) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", aiff.path, text]
        try say.run()
        say.waitUntilExit()
        try AudioRecorder.convertToASRWav(from: aiff, to: wav)
        return HandsFreeService.samples(try WAVFile(contentsOf: wav).samples)
    }

    private static func compact(_ message: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\(message)"
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data("hands-free-test: \(message)\n".utf8))
    }
}

/// A blocking newline-JSON client on a Unix socket, for the test client.
final class LineSocket: @unchecked Sendable {
    private let fd: Int32
    private var buffer = Data()
    private let writeLock = NSLock()

    init?(path: String) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        _ = path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: capacity) { strncpy($0, src, capacity - 1) } }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { Darwin.close(fd); return nil }
    }

    func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        writeLock.withLock {
            _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        }
    }

    func receive() -> [String: Any]? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { return message }
                continue
            }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    func close() { Darwin.close(fd) }
}
