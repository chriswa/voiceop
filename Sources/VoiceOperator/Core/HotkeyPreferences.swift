import Foundation

/// User-facing choices about how the trigger key behaves. Persisted in
/// `UserDefaults` (the same lightweight store `LaunchAtLogin` uses) so the
/// choice survives relaunches.
enum HotkeyPreferences {
    private static let tapToToggleKey = "vo.tapToToggleDictation"

    /// When true, the trigger uses the single-tap toggle model instead of the
    /// default hold / double-tap-lock / ⌘-lock model: one press starts, the next
    /// press stops, and holding is just a press. See `HotkeyMonitor.tapToToggle`.
    static var tapToToggle: Bool {
        get { UserDefaults.standard.bool(forKey: tapToToggleKey) }
        set { UserDefaults.standard.set(newValue, forKey: tapToToggleKey) }
    }
}
