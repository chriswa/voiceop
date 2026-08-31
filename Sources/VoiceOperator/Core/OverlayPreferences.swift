import Foundation

/// User-facing choices about the on-screen overlays. Persisted in `UserDefaults`
/// (same store as `HotkeyPreferences` / `LaunchAtLogin`) so the choice survives
/// relaunches.
enum OverlayPreferences {
    private static let wordOverlayKey = "vo.wordOverlayEnabled"

    /// Whether the word-highlight bar is shown during TTS playback. Defaults to
    /// on; an explicit `false` is what a user who turned it off wrote.
    static var wordOverlayEnabled: Bool {
        get { UserDefaults.standard.object(forKey: wordOverlayKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: wordOverlayKey) }
    }
}
