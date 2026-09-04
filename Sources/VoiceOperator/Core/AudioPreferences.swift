import Foundation

/// User-facing choices about how dictation treats the Mac's own audio. Persisted
/// in `UserDefaults` (same store as `HotkeyPreferences` / `OverlayPreferences`)
/// so the choice survives relaunches.
enum AudioPreferences {
    private static let muteSystemAudioKey = "vo.muteSystemAudioWhileDictating"

    /// Whether a dictation hardware-mutes the default output device for its
    /// duration (see `OutputMuter`). Defaults to on — that is what Wispr does and
    /// what keeps a playing video out of the microphone; an explicit `false` is
    /// what a user who turned it off wrote.
    static var muteSystemAudioWhileDictating: Bool {
        get { UserDefaults.standard.object(forKey: muteSystemAudioKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: muteSystemAudioKey) }
    }
}
