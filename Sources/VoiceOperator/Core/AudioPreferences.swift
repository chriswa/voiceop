import Foundation

/// User-facing choices about how dictation treats the Mac's own audio. Persisted
/// in `UserDefaults` (same store as `HotkeyPreferences` / `OverlayPreferences`)
/// so the choice survives relaunches.
enum AudioPreferences {
    private static let muteSystemAudioKey = "vo.muteSystemAudioWhileDictating"
    private static let keepMicrophoneOpenKey = "vo.keepMicrophoneOpen"
    private static let keepMicrophoneOpenForWirelessKey = "vo.keepMicrophoneOpenForWireless"
    private static let macMicrophoneWithHeadsetsKey = "vo.macMicrophoneWithHeadsets"

    /// Whether a dictation hardware-mutes the default output device for its
    /// duration (see `OutputMuter`). Defaults to on — that is what Wispr does and
    /// what keeps a playing video out of the microphone; an explicit `false` is
    /// what a user who turned it off wrote.
    static var muteSystemAudioWhileDictating: Bool {
        get { UserDefaults.standard.object(forKey: muteSystemAudioKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: muteSystemAudioKey) }
    }

    /// Whether the microphone is held open between dictations
    /// (`AudioRecorder.setAlwaysOn`). Defaults to off: it lights the microphone
    /// indicator permanently and pins a Bluetooth headset to its voice profile,
    /// which is a trade only the user can make.
    ///
    /// This is the *manual* choice. What the recorder is actually told is
    /// `AppCoordinator.shouldKeepMicrophoneOpen`, which hands the decision to
    /// `keepMicrophoneOpenForWireless` when that is on.
    static var keepMicrophoneOpen: Bool {
        get { UserDefaults.standard.bool(forKey: keepMicrophoneOpenKey) }
        set { UserDefaults.standard.set(newValue, forKey: keepMicrophoneOpenKey) }
    }

    /// Whether the setting above is driven automatically: on while the default
    /// output is a Bluetooth headset (`OutputDevice.isWireless`), off the moment
    /// it isn't. The stall this avoids is a Bluetooth problem and nothing else,
    /// so on the built-in microphone there is no reason to pay for it.
    static var keepMicrophoneOpenForWireless: Bool {
        get { UserDefaults.standard.bool(forKey: keepMicrophoneOpenForWirelessKey) }
        set { UserDefaults.standard.set(newValue, forKey: keepMicrophoneOpenForWirelessKey) }
    }

    /// Whether, while the output is a Bluetooth headset (`OutputDevice.isWireless`),
    /// Voice Operator records from the Mac's own microphone rather than the
    /// headset's (`AudioRecorder`, `InputDevice.builtInMicrophone`). The headset
    /// then never switches profiles for a dictation — no drop in the music at
    /// either end — whatever the system's input is set to. Default off.
    static var macMicrophoneWithHeadsets: Bool {
        get { UserDefaults.standard.bool(forKey: macMicrophoneWithHeadsetsKey) }
        set { UserDefaults.standard.set(newValue, forKey: macMicrophoneWithHeadsetsKey) }
    }
}
