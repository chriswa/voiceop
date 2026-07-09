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

    struct Contents {
        var tts: [TTSHistoryEntry] = []
        var stt: [STTHistoryEntry] = []
        var commands: [CommandHistoryEntry] = []
        /// The session most recently referenced (last speaker / tool target),
        /// restored so "Focus last speaker" survives a restart. nil until one exists.
        var lastReferencedSessionKey: String? = nil
    }

    private struct Payload: Codable {
        var version: Int
        var tts: [TTSHistoryEntry]
        var stt: [STTHistoryEntry]
        var commands: [CommandHistoryEntry]
        var lastReferencedSessionKey: String?

        // Lenient: every list defaults to empty (and the key to nil) if absent, so
        // adding a new field (or reading an older file) never fails the whole decode.
        init(version: Int, tts: [TTSHistoryEntry], stt: [STTHistoryEntry],
             commands: [CommandHistoryEntry], lastReferencedSessionKey: String?) {
            self.version = version; self.tts = tts; self.stt = stt; self.commands = commands
            self.lastReferencedSessionKey = lastReferencedSessionKey
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(Int.self, forKey: .version)
            tts = try c.decodeIfPresent([TTSHistoryEntry].self, forKey: .tts) ?? []
            stt = try c.decodeIfPresent([STTHistoryEntry].self, forKey: .stt) ?? []
            commands = try c.decodeIfPresent([CommandHistoryEntry].self, forKey: .commands) ?? []
            lastReferencedSessionKey = try c.decodeIfPresent(String.self, forKey: .lastReferencedSessionKey)
        }
    }

    func load() -> Contents {
        guard let data = try? Data(contentsOf: fileURL) else { return Contents() }
        return Self.decode(data)
    }

    /// Failure-tolerant decode (also used by tests): any malformed/incompatible
    /// payload yields empty history instead of throwing.
    static func decode(_ data: Data) -> Contents {
        do {
            let p = try JSONDecoder().decode(Payload.self, from: data)
            guard p.version == version else {
                Log.log("history: ignoring incompatible version \(p.version) (expected \(version))")
                return Contents()
            }
            return Contents(tts: p.tts, stt: p.stt, commands: p.commands,
                            lastReferencedSessionKey: p.lastReferencedSessionKey)
        } catch {
            Log.log("history: could not decode (\(error)); starting empty")
            return Contents()
        }
    }

    func save(_ c: Contents) {
        let payload = Payload(version: Self.version, tts: c.tts, stt: c.stt, commands: c.commands,
                              lastReferencedSessionKey: c.lastReferencedSessionKey)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
