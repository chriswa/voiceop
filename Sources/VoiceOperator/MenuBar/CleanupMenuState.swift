import Foundation

/// The clean-up checkbox and the lines under it, decided in one pure function
/// so the rules are testable without AppKit. `MenuBarController` only renders it.
struct CleanupMenuState: Equatable {
    var enabled: Bool
    /// The disabled line under the checkbox; nil hides it. Starts with ⚠︎ when
    /// transcripts are being pasted without the clean-up the user asked for.
    var status: String?
    /// "Clean-Up Setup Instructions…": only while the model is missing, the one
    /// step the app can't do for the user.
    var showInstructions: Bool
    var showDelete: Bool

    static func make(enabled: Bool, phase: CleanupServer.Phase, modelPresent: Bool,
                     downloaded: Bool, healthy: Bool) -> CleanupMenuState {
        let status: String?
        switch phase {
        case .working(let step):
            status = "Clean-up: \(step)…"
        case .failed(let reason):
            status = "⚠︎ Clean-up: \(reason) — pasting raw transcripts"
        case .idle where !enabled:
            status = nil
        case .idle:
            status = healthy ? nil : "⚠︎ Clean-up: server not responding — pasting raw transcripts"
        }
        let working: Bool
        if case .working = phase { working = true } else { working = false }
        return CleanupMenuState(enabled: enabled, status: status,
                                showInstructions: !modelPresent,
                                showDelete: !enabled && downloaded && !working)
    }
}
