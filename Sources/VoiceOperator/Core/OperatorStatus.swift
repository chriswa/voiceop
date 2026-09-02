import AppKit

/// The single, user-visible state of the Voice Operator, surfaced in the menu
/// bar. Drives both the icon tint and the status-item accessibility label.
///
/// The icon is a bullhorn (megaphone) silhouette: **red while recording**,
/// **yellow while transcribing**, **green while playing audio**, monochrome
/// otherwise (per product spec).
///
/// The raw value is the name reported by the loopback `/v1/status` endpoint.
enum OperatorStatus: String, Equatable {
    case idle
    case listening        // paste dictation capturing the mic    -> RED
    case commandListening // Ctrl+Fn command dictation capturing   -> MAGENTA
    case transcribing     // audio sent, awaiting text                 -> YELLOW
    case pasting          // inserting text into the focused app
    case summarizing      // waiting on Claude/Haiku (any summary)  -> BLUE
    case requestingTTS    // fetching/synthesizing a clip          -> CYAN
    case speaking         // TTS is playing                        -> GREEN

    /// Tint for the bullhorn silhouette, or nil for the default monochrome
    /// (template) rendering.
    var tint: NSColor? {
        switch self {
        case .listening:        return .systemRed
        case .commandListening: return .magenta
        case .transcribing:     return .systemYellow
        case .summarizing:      return .systemBlue
        case .requestingTTS:    return .systemCyan
        case .speaking:         return .systemGreen
        case .idle, .pasting:   return nil
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .idle:             return "Voice Operator — idle"
        case .listening:        return "Voice Operator — listening"
        case .commandListening: return "Voice Operator — listening (command)"
        case .transcribing:     return "Voice Operator — transcribing"
        case .pasting:          return "Voice Operator — pasting"
        case .summarizing:      return "Voice Operator — summarizing"
        case .requestingTTS:    return "Voice Operator — fetching audio"
        case .speaking:         return "Voice Operator — speaking"
        }
    }
}

extension DictationMode {
    /// The capture status this mode shows in the menu bar.
    var listeningStatus: OperatorStatus { self == .command ? .commandListening : .listening }
}
