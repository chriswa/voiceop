import Foundation

/// A dictation attempt, retained for the "Recent Dictations" list. The WAV is
/// kept so the transcription can be retried; `transcript` is replaced in place
/// when a retry produces new text.
struct STTHistoryEntry: Identifiable, Sendable, Codable {
    var id = UUID()
    let date: Date
    let duration: TimeInterval
    var transcript: String
    /// Why the last transcription attempt failed (nil on success) — shown in
    /// the menu so a failure isn't silently indistinguishable from "(empty)".
    var error: String? = nil
    let wavURL: URL?

    var menuTitle: String {
        let secs = String(format: "%.1fs", duration)
        let text = if let error { "⚠️ \(error.vo_truncated(44))" }
                   else if transcript.isEmpty { "(empty)" }
                   else { transcript.vo_truncated(50) }
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
    /// Why the last transcription attempt failed (nil on success).
    var error: String? = nil
    let wavURL: URL?

    var menuTitle: String {
        let secs = String(format: "%.1fs", duration)
        if let error {
            return "\(date.vo_relativeAge) · \(secs) · ⚠️ \(error.vo_truncated(40))"
        }
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
