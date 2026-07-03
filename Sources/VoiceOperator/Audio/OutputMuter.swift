import CoreAudio
import Foundation

/// Mutes the default system **output** device during dictation, the way Wispr
/// does (DESIGN.md "Mute-during-dictation"): save the device's current mute
/// state, set mute=true, and restore on stop — tracking `wasPreviouslyMuted` so
/// we never unmute audio the user had already muted themselves.
///
/// Wispr additionally gates this on MediaRemote now-playing state ("Skipping
/// mute, media is not playing"); that uses a private framework, so v1 mutes
/// unconditionally and restores. Refinement tracked in DESIGN.md.
final class OutputMuter {
    private var wasPreviouslyMuted: Bool?

    func mute() {
        guard let device = Self.defaultOutputDevice() else { return }
        let current = Self.muteState(device)
        wasPreviouslyMuted = current
        if current == false { Self.setMute(device, true) }
    }

    func restore() {
        defer { wasPreviouslyMuted = nil }
        guard let device = Self.defaultOutputDevice(),
              wasPreviouslyMuted == false else { return }
        Self.setMute(device, false)
    }

    // MARK: - CoreAudio

    private static func defaultOutputDevice() -> AudioObjectID? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// Current mute state, or nil if the device has no mute control.
    private static func muteState(_ device: AudioObjectID) -> Bool? {
        var addr = muteAddress()
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &muted)
        return status == noErr ? (muted != 0) : nil
    }

    private static func setMute(_ device: AudioObjectID, _ on: Bool) {
        var addr = muteAddress()
        guard AudioObjectHasProperty(device, &addr) else { return }
        var value: UInt32 = on ? 1 : 0
        _ = AudioObjectSetPropertyData(
            device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}
