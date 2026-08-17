import Foundation

/// Minimal append-only file logger at ~/Library/Logs/VoiceOperator.log, so we
/// can diagnose the real menu-bar app (whose NSLog output is otherwise buried in
/// the unified log). Also mirrors to stderr for `swift run`.
enum Log {
    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("VoiceOperator.log")
    }()

    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    /// Short, log-safe identifier for a clip of speech. Enough of the sentence to
    /// correlate a stall with the answer it belonged to, without spilling whole
    /// transcripts into a file that lives forever.
    static func clip(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let head = flat.count <= 48 ? flat : String(flat.prefix(48)) + "…"
        return "\"\(head)\" [\(text.count)ch]"
    }

    static func elapsed(since start: Date) -> String {
        String(format: "%.1fs", Date().timeIntervalSince(start))
    }

    static func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        lock.lock(); defer { lock.unlock() }
        if let h = try? FileHandle(forWritingTo: fileURL) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: fileURL)
        }
    }
}
