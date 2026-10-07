import Foundation

/// App settings loaded from
/// `~/Library/Application Support/VoiceOperator/config.json`.
///
/// A GUI app launched via `open` does not inherit the shell environment (same
/// trap as `WisprBasetenKey`), so durable overrides live here. JSON so future
/// settings can join without accreting one flat file per key.
///
/// TTS URL precedence: `$VOICEOP_KOKORO_URL` → the chosen `TTSProvider`'s URL
/// (`http://localhost:56841` for the local Kokoro, `tts.url` for a custom server).
enum Config {
    struct File: Codable, Equatable, Sendable {
        struct TTS: Codable, Equatable, Sendable {
            var url: String?
            var headers: [String: String]?
            /// `"kokoro"` or `"custom"` — see `TTSProvider.resolve`. Absent in
            /// files written before the Text to Speech menu existed.
            var provider: String?
        }
        var tts: TTS?
    }

    static let defaultTTSBaseURL = "http://localhost:56841"

    /// Test seam: when set, `load()` returns this instead of reading disk.
    /// Guarded by `lock` together with `cached`.
    nonisolated(unsafe) private static var _override: File?
    nonisolated(unsafe) private static var cached: File?
    private static let lock = NSLock()

    static var override: File? {
        get { lock.withLock { _override } }
        set {
            lock.withLock {
                _override = newValue
                cached = nil
            }
        }
    }

    /// Test seam: where `setTTSProvider` writes, so tests never touch the real file.
    nonisolated(unsafe) static var fileURLOverride: URL?

    static var fileURL: URL {
        fileURLOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceOperator/config.json")
    }

    /// Drop the in-memory cache (e.g. after a test mutates `override`).
    static func resetCache() {
        lock.withLock { cached = nil }
    }

    static func load() -> File {
        lock.lock()
        defer { lock.unlock() }
        if let _override { return _override }
        if let cached { return cached }
        let file: File
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(File.self, from: data) {
            file = decoded
        } else {
            file = File()
        }
        cached = file
        return file
    }

    /// Which TTS server speech goes to (the Text to Speech menu's choice).
    static var ttsProvider: TTSProvider {
        TTSProvider.resolve(load().tts)
    }

    /// Base URL for Kokoro (`/synthesize`, `/voices`). Trailing slash optional.
    static var ttsBaseURL: String {
        if let env = ProcessInfo.processInfo.environment["VOICEOP_KOKORO_URL"], !env.isEmpty {
            return env
        }
        return ttsProvider.baseURL
    }

    /// Extra HTTP headers for TTS requests (e.g. Cloudflare Access service-token
    /// `CF-Access-Client-Id` / `CF-Access-Client-Secret`).
    static var ttsHeaders: [String: String] {
        load().tts?.headers ?? [:]
    }

    /// Persist the Text to Speech menu's choice. A custom server's URL is kept
    /// when switching back to the local Kokoro, so choosing it again is one click.
    ///
    /// The file is hand-edited and holds secrets (`tts.headers`), so it is
    /// rewritten as raw JSON with every other key left as found, and kept
    /// owner-only. Writing the decoded `File` back would silently drop any key
    /// this build doesn't know about.
    static func setTTSProvider(_ provider: TTSProvider) throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: fileURL) {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: fileURL.path])
            }
            root = object
        }
        var tts = root["tts"] as? [String: Any] ?? [:]
        tts["provider"] = provider.wireName
        if case .custom(let url) = provider { tts["url"] = url }
        root["tts"] = tts
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        resetCache()
        Log.log("tts: provider set to \(provider.summary)")
    }
}
