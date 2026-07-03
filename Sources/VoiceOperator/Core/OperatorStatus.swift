import AppKit

/// The single, user-visible state of the Voice Operator, surfaced in the menu
/// bar. Drives both the icon tint and the status-item accessibility label.
///
/// The icon is a bullhorn (megaphone) silhouette: **red while recording**,
/// **green while playing audio**, monochrome otherwise (per product spec).
enum OperatorStatus: Equatable {
    case idle
    case paused           // user muted the operator (e.g. in a meeting)
    case listening        // dictation is capturing the mic  -> RED
    case transcribing     // audio sent, awaiting text
    case pasting          // inserting text into the focused app
    case speaking         // TTS is playing                  -> GREEN

    /// Tint for the bullhorn silhouette, or nil for the default monochrome
    /// (template) rendering.
    var tint: NSColor? {
        switch self {
        case .listening: return .systemRed
        case .speaking:  return .systemGreen
        case .idle, .paused, .transcribing, .pasting: return nil
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .idle:         return "Voice Operator — idle"
        case .paused:       return "Voice Operator — paused"
        case .listening:    return "Voice Operator — listening"
        case .transcribing: return "Voice Operator — transcribing"
        case .pasting:      return "Voice Operator — pasting"
        case .speaking:     return "Voice Operator — speaking"
        }
    }
}
