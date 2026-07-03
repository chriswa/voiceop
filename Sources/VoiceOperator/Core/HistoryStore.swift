import Foundation

/// Persists the menu-bar history (Recent Updates + Recent Dictations) across
/// runs, in Application Support (survives restarts and Cache purges).
///
/// Loading is deliberately failure-tolerant: any decode problem — including a
/// format change from an older build, or a version bump — yields empty history
/// rather than throwing. Better to lose history than to fail to launch.
struct HistoryStore {
    /// Bump only for an INCOMPATIBLE shape change. Additive fields don't count —
    /// TTSHistoryEntry decodes new fields leniently (decodeIfPresent), so older
    /// files (e.g. pre-"More details", which lacked context/priorSummaries) still
    /// load. Kept at 1 for that reason.
    private static let version = 1

    /// Shared app-support directory (also used for the STT clip store).
    static var supportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceOperator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var fileURL: URL { Self.supportDir.appendingPathComponent("history.json") }

    private struct Payload: Codable {
        var version: Int
        var tts: [TTSHistoryEntry]
        var stt: [STTHistoryEntry]
    }

    func load() -> (tts: [TTSHistoryEntry], stt: [STTHistoryEntry]) {
        guard let data = try? Data(contentsOf: fileURL) else { return ([], []) }
        return Self.decode(data)
    }

    /// Failure-tolerant decode (also used by tests): any malformed/old/incompatible
    /// payload yields empty history instead of throwing.
    static func decode(_ data: Data) -> (tts: [TTSHistoryEntry], stt: [STTHistoryEntry]) {
        do {
            let p = try JSONDecoder().decode(Payload.self, from: data)
            guard p.version == version else {
                Log.log("history: ignoring incompatible version \(p.version) (expected \(version))")
                return ([], [])
            }
            return (p.tts, p.stt)
        } catch {
            Log.log("history: could not decode (\(error)); starting empty")
            return ([], [])
        }
    }

    func save(tts: [TTSHistoryEntry], stt: [STTHistoryEntry]) {
        let payload = Payload(version: Self.version, tts: tts, stt: stt)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
