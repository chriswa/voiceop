import Foundation

/// Fire-and-forget newline-JSON to spaceterm's sockets. Best-effort: if
/// spaceterm isn't running, we silently skip (speaking/focus must never depend
/// on spaceterm being up).
///
/// Two sockets are used (see spaceterm's shared/protocol.ts):
///   • hooks.sock         — ingest events (tts-speaking)
///   • bidirectional.sock — client protocol (focus-surface-request); no handshake
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

    /// Raise/focus a surface by its spaceterm surface (pty session) id.
    static func focusSurface(surfaceId: String) {
        send(["type": "focus-surface-request", "surfaceId": surfaceId],
             to: bidirectionalPath, label: "focus-surface-request")
    }

    /// Send one newline-delimited JSON message. `label` (when set) logs success;
    /// connect failures always log. `shutdown(SHUT_WR)` flushes and signals EOF so
    /// the server processes the line before we close (no close-race).
    private static func send(_ event: [String: Any], to socketPath: String, label: String? = nil) {
        guard let payload = try? JSONSerialization.data(withJSONObject: event) else { return }
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
        shutdown(fd, SHUT_WR)   // flush + EOF so the server reads the line before close
        if let label {
            Log.log("spaceterm: sent \(label) (\(written) bytes) to \((socketPath as NSString).lastPathComponent)")
        }
    }
}
