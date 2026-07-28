import Foundation

/// Minimal fire-and-forget bridge to Spaceterm's external ingest socket.
enum SpacetermSocket {
    private static var path: String {
        let dir = ProcessInfo.processInfo.environment["SPACETERM_HOME"] ?? (NSHomeDirectory() as NSString).appendingPathComponent(".spaceterm")
        return (dir as NSString).appendingPathComponent("hooks.sock")
    }
    private static let queue = DispatchQueue(label: "com.voiceop.spaceterm-socket")
    static func voiceCommand(_ text: String, completion: @escaping @Sendable (Bool) -> Void) {
        guard let payload = try? JSONSerialization.data(withJSONObject: ["type": "voice-command", "text": text]) else { completion(false); return }
        queue.async {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { completion(false); return }
            defer { close(fd) }
            var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
            let socketPath = path
            let capacity = MemoryLayout.size(ofValue: addr.sun_path)
            _ = socketPath.withCString { src in
                withUnsafeMutablePointer(to: &addr.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: capacity) { strncpy($0, src, capacity - 1) } }
            }
            let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard ok == 0 else { completion(false); return }
            var line = payload; line.append(0x0A)
            let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            shutdown(fd, SHUT_WR)
            completion(written == line.count)
        }
    }
}
