import Foundation

/// Which TTS server speech goes to — the Text to Speech menu's radio choice.
///
/// Both cases speak the Kokoro HTTP API (`/synthesize`, `/voices`, optionally
/// `/timestamps`; see `KokoroSynthesizer`), so "bring your own" means a
/// Kokoro-compatible server. A different engine joins as a new case with its
/// own `SpeechSynthesizer`.
enum TTSProvider: Equatable, Sendable {
    /// The Kokoro server Voice Operator installs and runs on this Mac
    /// (`KokoroService`). The default.
    case kokoroLocal
    /// A Kokoro-compatible server somewhere else, at `url`.
    case custom(url: String)

    /// Default voice when a caller names none. Kokoro's own default; every
    /// Kokoro-compatible server has it.
    var defaultVoiceID: String { "af_heart" }

    var baseURL: String {
        switch self {
        case .kokoroLocal: return Config.defaultTTSBaseURL
        case .custom(let url): return url
        }
    }

    /// What `config.json` (`tts.provider`) and `/v1/voices` (`provider`) call it.
    var wireName: String {
        switch self {
        case .kokoroLocal: return "kokoro"
        case .custom: return "custom"
        }
    }

    /// Partitions the audio cache. The local Kokoro keeps the namespace the
    /// cache always used, so existing entries stay valid; a custom server gets
    /// its own, so switching servers never replays the other one's audio.
    var cacheNamespace: String {
        switch self {
        case .kokoroLocal: return "kokoro-82m"
        case .custom(let url): return "custom:\(url)"
        }
    }

    /// For log lines and the menu.
    var summary: String {
        switch self {
        case .kokoroLocal: return "Kokoro on this Mac"
        case .custom(let url): return "custom server \(URL(string: url)?.host ?? url)"
        }
    }

    /// The provider a `config.json` `tts` block names.
    ///
    /// Files written before the menu existed have no `provider`; for those a
    /// `url` meant "use this server", so it still does.
    static func resolve(_ tts: Config.File.TTS?) -> TTSProvider {
        let url = tts?.url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if tts?.provider == "kokoro" || url.isEmpty { return .kokoroLocal }
        return .custom(url: url)
    }

    /// A usable custom-server URL from what someone typed, or nil: needs an
    /// http(s) scheme and a host. Trailing slashes are dropped.
    static func normalizedCustomURL(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return text
    }
}
