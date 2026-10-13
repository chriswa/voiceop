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
    /// files (e.g. early ones that lacked context/priorSummaries) still load.
    /// Kept at 1 for that reason.
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
        var stt: [STTHistoryEntry] = []
        var commands: [CommandHistoryEntry] = []
    }

    private struct Payload: Codable {
        var version: Int
        var stt: [STTHistoryEntry]
        var commands: [CommandHistoryEntry]

        // Lenient: every list defaults to empty (and the key to nil) if absent, so
        // adding a new field (or reading an older file) never fails the whole decode.
        init(version: Int, stt: [STTHistoryEntry], commands: [CommandHistoryEntry]) {
            self.version = version; self.stt = stt; self.commands = commands
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(Int.self, forKey: .version)
            stt = try c.decodeIfPresent([STTHistoryEntry].self, forKey: .stt) ?? []
            commands = try c.decodeIfPresent([CommandHistoryEntry].self, forKey: .commands) ?? []
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
            return Contents(stt: p.stt, commands: p.commands)
        } catch {
            Log.log("history: could not decode (\(error)); starting empty")
            return Contents()
        }
    }

    /// Refused in incognito mode, whatever the caller: the arbiter files
    /// nothing while it is on, and this is the backstop if that ever slips.
    func save(_ c: Contents) {
        guard Incognito.refusal(AudioArbiter.historyActivity) == nil else { return }
        let payload = Payload(version: Self.version, stt: c.stt, commands: c.commands)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
