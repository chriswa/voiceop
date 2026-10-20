import Foundation

/// The clean-up section of the Transcription submenu, decided in one pure
/// function so the rules are testable without AppKit. `MenuBarController` only
/// renders it.
struct CleanupMenuState: Equatable {
    var enabled: Bool
    /// The disabled line under the checkbox; nil hides it. Starts with ⚠︎ when
    /// transcripts are being pasted without the clean-up the user asked for.
    var status: String?
    var showDelete: Bool
    /// False while the server is being set up or taken down: one thing at a time.
    var actionsEnabled: Bool

    static func make(enabled: Bool, phase: CleanupServer.Phase, downloaded: Bool, healthy: Bool) -> CleanupMenuState {
        let status: String?
        switch phase {
        case .working(let step):
            status = "Clean-up: \(step)…"
        case .failed(let reason):
            status = "⚠︎ Clean-up: \(reason) — pasting raw transcripts"
        case .idle where !enabled:
            status = nil
        case .idle:
            status = healthy ? "Clean-up: ready" : "⚠︎ Clean-up: server not responding — pasting raw transcripts"
        }
        let working: Bool
        if case .working = phase { working = true } else { working = false }
        return CleanupMenuState(enabled: enabled, status: status,
                                showDelete: !enabled && downloaded && !working,
                                actionsEnabled: !working)
    }
}
