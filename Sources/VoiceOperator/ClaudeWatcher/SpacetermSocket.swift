import Foundation

/// Fire-and-forget newline-JSON to spaceterm's sockets. Best-effort: if
/// spaceterm isn't running, we silently skip (speaking/focus must never depend
/// on spaceterm being up).
///
/// Two sockets are used (see spaceterm's shared/protocol.ts):
///   • hooks.sock         — ingest events (tts-speaking)
///   • bidirectional.sock — client protocol (focus-claude-session); no handshake
enum SpacetermSocket {
    private static var dir: String {
        ProcessInfo.processInfo.environment["SPACETERM_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".spaceterm")
    }
    private static var hooksPath: String { (dir as NSString).appendingPathComponent("hooks.sock") }
    private static var bidirectionalPath: String { (dir as NSString).appendingPathComponent("bidirectional.sock") }

    static func speakingStarted(_ u: Utterance) {
        var event: [String: Any] = ["type": "tts-speaking", "speaking": true, "text": u.spokenText]
        if let key = u.sessionKey { event["claudeSessionId"] = key }
        send(event, to: hooksPath)
    }

    static func speakingStopped(sessionKey: String?) {
        var event: [String: Any] = ["type": "tts-speaking", "speaking": false]
        if let key = sessionKey { event["claudeSessionId"] = key }
        send(event, to: hooksPath)
    }

    /// Broadcast the full Claude-session→call-sign map. Sent whole (no diffing)
    /// on every change and once on startup; the receiver replaces its copy each
    /// time. `names` maps a Claude session id → its assigned display name.
    static func sessionNames(_ names: [String: String]) {
        send(["type": "session-names", "names": names], to: hooksPath, label: "session-names")
    }

    /// Raise/focus the spaceterm surface hosting a Claude session. We send the
    /// CLAUDE SESSION ID and let spaceterm resolve it to a surface against its own
    /// state — voiceop deliberately knows nothing about spaceterm's surface/node
    /// ids (mirrors the `tts-speaking` boundary, which is also keyed by session).
    static func focusClaudeSession(_ claudeSessionId: String) {
        send(["type": "focus-claude-session", "claudeSessionId": claudeSessionId],
             to: bidirectionalPath, label: "focus-claude-session session=\(claudeSessionId.prefix(8))")
    }

    /// Serializes sends off the main thread; a serial queue also preserves message
    /// order (e.g. speaking start→stop) that concurrent sends could scramble.
    private static let queue = DispatchQueue(label: "com.voiceop.spaceterm-socket")

    /// Send one newline-delimited JSON message. `label` (when set) logs success;
    /// connect failures always log.
    ///
    /// The send runs on `queue` because it must DRAIN the socket before closing:
    /// spaceterm pushes greeting state (saved-viewports, session-names, usage) to
    /// every new connection, and we never read it. Closing with those bytes still
    /// unread makes the kernel send an RST instead of a FIN, and the RST causes
    /// the server to discard any of OUR bytes it hasn't read yet — so the message
    /// is silently lost. This raced intermittently under the old
    /// `shutdown(SHUT_WR)` + immediate-close approach (verified: an abrupt close
    /// dropped the line; draining first delivered it reliably). Reading to
    /// EOF/idle-timeout first turns the close into a graceful FIN, so the server
    /// always processes the line. The drain (~250 ms) is why this is off-main.
    private static func send(_ event: [String: Any], to socketPath: String, label: String? = nil) {
        guard let payload = try? JSONSerialization.data(withJSONObject: event) else { return }
        queue.async {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return }
            defer { close(fd) }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: addr.sun_path)
            _ = socketPath.withCString { src in
                withUnsafeMutablePointer(to: &addr.sun_path) {
                    $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
                        strncpy($0, src, capacity - 1)
                    }
                }
            }
            let len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
            }
            guard ok == 0 else {
                if label != nil {
                    Log.log("spaceterm: connect failed to \((socketPath as NSString).lastPathComponent) (errno \(errno))")
                }
                return
            }
            var line = payload; line.append(0x0A)
            let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            shutdown(fd, SHUT_WR)      // signal EOF: we have nothing more to write
            drain(fd)                  // consume the server's greeting so close() is a FIN, not an RST
            if let label {
                Log.log("spaceterm: sent \(label) (\(written) bytes) to \((socketPath as NSString).lastPathComponent)")
            }
        }
    }

    /// Read and discard until the server closes (EOF) or goes idle for the read
    /// timeout. Draining the receive buffer is what makes the subsequent close a
    /// graceful FIN rather than an RST — see `send`. The idle timeout bounds this:
    /// the server sends its greeting immediately, then stays quiet, so one timeout
    /// (~250 ms) after the last byte ends the loop.
    private static func drain(_ fd: Int32) {
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 4096)
        while read(fd, &buf, buf.count) > 0 {}   // 0 = EOF, <0 = timeout/error → stop
    }
}
