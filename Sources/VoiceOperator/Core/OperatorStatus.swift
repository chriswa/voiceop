import AppKit

/// The single, user-visible state of the Voice Operator, surfaced in the menu
/// bar. Drives both the icon tint and the status-item accessibility label.
///
/// The icon is a bullhorn (megaphone) silhouette: **red while recording**,
/// **green while playing audio**, monochrome otherwise (per product spec).
/// How a dictation is interpreted: Fn = paste the transcript; Ctrl+Fn = run the
/// transcript through the voice-tool router (focus/repeat/more-details) only.
enum DictationMode { case paste, command }

enum OperatorStatus: Equatable {
    case idle
    case listening        // paste dictation capturing the mic    -> RED
    case commandListening // Ctrl+Fn command dictation capturing   -> MAGENTA
    case transcribing     // audio sent, awaiting text
    case pasting          // inserting text into the focused app
    case requestingTTS    // fetching/synthesizing a clip          -> CYAN
    case speaking         // TTS is playing                        -> GREEN

    /// Tint for the bullhorn silhouette, or nil for the default monochrome
    /// (template) rendering.
    var tint: NSColor? {
        switch self {
        case .listening:        return .systemRed
        case .commandListening: return .magenta
        case .requestingTTS:    return .systemCyan
        case .speaking:         return .systemGreen
        case .idle, .transcribing, .pasting: return nil
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .idle:             return "Voice Operator — idle"
        case .listening:        return "Voice Operator — listening"
        case .commandListening: return "Voice Operator — listening (command)"
        case .transcribing:     return "Voice Operator — transcribing"
        case .pasting:          return "Voice Operator — pasting"
        case .requestingTTS:    return "Voice Operator — fetching audio"
        case .speaking:         return "Voice Operator — speaking"
        }
    }
}
