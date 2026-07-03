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
