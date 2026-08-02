import Foundation

/// App settings loaded from
/// `~/Library/Application Support/VoiceOperator/config.json`.
///
/// A GUI app launched via `open` does not inherit the shell environment (same
/// trap as `WisprBasetenKey`), so durable overrides live here. JSON so future
/// settings can join without accreting one flat file per key.
///
/// TTS URL precedence: `$VOICEOP_KOKORO_URL` → `tts.url` → `http://localhost:56841`.
enum Config {
    struct File: Codable, Equatable, Sendable {
        struct TTS: Codable, Equatable, Sendable {
            var url: String?
            var headers: [String: String]?
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

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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

    /// Base URL for Kokoro (`/synthesize`, `/voices`). Trailing slash optional.
    static var ttsBaseURL: String {
        if let env = ProcessInfo.processInfo.environment["VOICEOP_KOKORO_URL"], !env.isEmpty {
            return env
        }
        if let url = load().tts?.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            return url
        }
        return defaultTTSBaseURL
    }

    /// Extra HTTP headers for TTS requests (e.g. Cloudflare Access service-token
    /// `CF-Access-Client-Id` / `CF-Access-Client-Secret`).
    static var ttsHeaders: [String: String] {
        load().tts?.headers ?? [:]
    }
}
