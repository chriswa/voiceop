import CoreAudio
import Foundation

/// The Mac's current default **output** device, and a watcher that says when it
/// changes.
///
/// This exists for one decision: whether to hold the microphone open
/// (`AudioRecorder.setAlwaysOn`). A Bluetooth headset renegotiates its codec
/// whenever an input stream opens or closes — the stall and the audible drop in
/// playback quality at both ends of every dictation — and holding the input open
/// is what avoids that. Nothing else about the device matters here.
///
/// The test is the **transport type**, not the device's name: AirPods can be
/// renamed to anything, and every other Bluetooth headset has exactly the same
/// problem, so matching on "AirPods" would be both leaky and needlessly narrow.
enum OutputDevice {
    /// Whether the default output device is a Bluetooth headset (AirPods & co).
    /// False when there is no output device at all, which is the safe answer:
    /// nothing to hold the microphone open for.
    static var isWireless: Bool {
        guard let device = defaultOutput() else { return false }
        switch transport(device) {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return true
        default: return false
        }
    }

    /// Whether the default output is the Mac's own (speakers, headphone jack).
    static var isBuiltIn: Bool {
        guard let device = defaultOutput() else { return false }
        return transport(device) == kAudioDeviceTransportTypeBuiltIn
    }

    /// `name (transport)` for the log — the one line that explains why the
    /// microphone just opened or closed on its own.
    static var summary: String {
        guard let device = defaultOutput() else { return "(no output device)" }
        return "\(name(device) ?? "unnamed") (\(fourCC(transport(device))))"
    }

    private static func defaultOutput() -> AudioObjectID? {
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

    private static func transport(_ device: AudioObjectID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(device, &addr),
              AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func name(_ device: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectHasProperty(device, &addr),
              AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// CoreAudio transport types are four-character codes; render them as such
    /// ('bltn', 'blue', 'usb ') rather than as an opaque number.
    private static func fourCC(_ value: UInt32) -> String {
        let bytes = [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff),
                     UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? "\(value)"
    }
}

/// Calls back whenever the default output device changes — AirPods connecting or
/// going away, the user picking a different output in Control Center.
///
/// The callback carries nothing: ask `OutputDevice` for the answer when it
/// arrives, so there is one place that decides what "wireless" means and no
/// cached copy of it to go stale.
final class OutputDeviceWatcher: @unchecked Sendable {
    /// Fired **on the main queue**.
    var onChange: (@Sendable () -> Void)?

    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var listener: AudioObjectPropertyListenerBlock?

    func start() {
        guard listener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onChange?()
        }
        listener = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        if status != noErr {
            listener = nil
            Log.log("output watcher: could not observe the default output device (status \(status))")
        }
    }

    func stop() {
        guard let listener else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener)
        self.listener = nil
    }

    deinit { stop() }
}
