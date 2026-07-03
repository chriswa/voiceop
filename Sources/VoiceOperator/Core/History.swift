import Foundation

/// A spoken Claude update, retained for the menu-bar "Recent Updates" list.
/// Replay reuses the audio cache, so it's free.
struct TTSHistoryEntry: Identifiable, Sendable, Codable {
    var id = UUID()
    let name: String
    let body: String
    let voiceID: String
    let sessionKey: String?
    let date: Date
    /// The original Claude turns this summary was generated from — kept so
    /// "More details" can re-run the summarizer on the same context.
    var context: [Turn] = []
    /// Every summary spoken in this depth chain, including `body` — fed back to
    /// the summarizer so "More details" adds new info without repeating.
    var priorSummaries: [String] = []

    var utterance: Utterance {
        Utterance(name: name, body: body, voiceID: voiceID, sessionKey: sessionKey)
    }
    var menuTitle: String { "\(name): \(body.vo_truncated(60))" }
}

extension TTSHistoryEntry {
    // Lenient decode: `context`/`priorSummaries` were added later, so entries
    // written before then simply lack those keys — treat as empty rather than
    // failing the whole file (which would drop all history). In an extension so
    // the memberwise initializer is preserved.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        body = try c.decode(String.self, forKey: .body)
        voiceID = try c.decode(String.self, forKey: .voiceID)
        sessionKey = try c.decodeIfPresent(String.self, forKey: .sessionKey)
        date = try c.decode(Date.self, forKey: .date)
        context = try c.decodeIfPresent([Turn].self, forKey: .context) ?? []
        priorSummaries = try c.decodeIfPresent([String].self, forKey: .priorSummaries) ?? []
    }
}

/// A dictation attempt, retained for the "Recent Dictations" list. The WAV is
/// kept so the transcription can be retried; `transcript` is replaced in place
/// when a retry produces new text.
struct STTHistoryEntry: Identifiable, Sendable, Codable {
    var id = UUID()
    let date: Date
    let duration: TimeInterval
    var transcript: String
    let wavURL: URL?

    var menuTitle: String {
        let secs = String(format: "%.1fs", duration)
        let text = transcript.isEmpty ? "(empty)" : transcript.vo_truncated(50)
        return "\(date.vo_relativeAge) · \(secs) · \(text)"
    }
}

/// A command-mode dictation (Ctrl+Fn), retained for the "Recent Commands" list.
/// Like an STT entry (keeps the WAV for Retry) plus whether a voice tool matched.
struct CommandHistoryEntry: Identifiable, Sendable, Codable {
    var id = UUID()
    let date: Date
    let duration: TimeInterval
    var transcript: String
    var recognized: Bool
    let wavURL: URL?

    var menuTitle: String {
        let secs = String(format: "%.1fs", duration)
        let text = transcript.isEmpty ? "(empty)" : transcript.vo_truncated(46)
        return "\(date.vo_relativeAge) · \(secs) · \(recognized ? "" : "✗ ")\(text)"
    }
}

extension String {
    /// Truncate to `max` characters with an ellipsis, collapsing whitespace.
    func vo_truncated(_ max: Int) -> String {
        let flat = self.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count <= max ? flat : String(flat.prefix(max - 1)) + "…"
    }
}

extension Date {
    /// Compact human-readable age, e.g. "just now", "5m ago", "2h ago".
    var vo_relativeAge: String {
        let s = Int(max(0, Date().timeIntervalSince(self)))
        switch s {
        case 0..<5:      return "just now"
        case 5..<60:     return "\(s)s ago"
        case 60..<3600:  return "\(s / 60)m ago"
        case 3600..<86400: return "\(s / 3600)h ago"
        default:         return "\(s / 86400)d ago"
        }
    }
}
