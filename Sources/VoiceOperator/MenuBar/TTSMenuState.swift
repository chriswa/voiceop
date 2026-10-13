import Foundation

/// Everything the Text to Speech submenu shows, decided in one pure function so
/// the rules are testable without AppKit. `MenuBarController` only renders it.
struct TTSMenuState: Equatable {
    enum InstallItem: Equatable { case install, cancel, hidden }

    /// The disabled first line. Starts with ⚠︎ when speech is not going to work.
    var status: String
    /// "Memory: 1.8 GB" for the local server once it has reported; nil hides it.
    var memory: String?
    var install: InstallItem
    var showUpdate: Bool
    var showRestart: Bool
    var showUninstall: Bool
    /// False while a service action runs: one thing at a time.
    var actionsEnabled: Bool

    var isWarning: Bool { status.hasPrefix("⚠︎") }

    static func make(phase: KokoroService.Phase,
                     installed: Bool,
                     updateAvailable: Bool,
                     canCancel: Bool,
                     health: KokoroService.Health?) -> TTSMenuState {
        let working: Bool
        let status: String
        switch phase {
        case .working(let step):
            working = true
            status = "Kokoro: \(step)…"
        case .failed(let reason):
            working = false
            status = "⚠︎ Kokoro: \(reason)"
        case .idle:
            working = false
            if health != nil {
                status = installed ? "Kokoro: running" : "Kokoro: running (not installed by Voice Operator)"
            } else {
                status = installed ? "⚠︎ Kokoro: not responding" : "⚠︎ Kokoro: not installed — speech is off"
            }
        }
        let install: InstallItem = canCancel ? .cancel : (installed ? .hidden : .install)
        return TTSMenuState(
            status: status,
            memory: health?.memoryMB.map { "Memory: \(formatMemory($0))" },
            install: install,
            showUpdate: installed && updateAvailable,
            showRestart: installed,
            showUninstall: installed,
            actionsEnabled: !working)
    }

    static func formatMemory(_ mb: Int) -> String {
        mb < 1024 ? "\(mb) MB" : String(format: "%.1f GB", Double(mb) / 1024)
    }
}
