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

    /// Whether the default output is the Mac's own speakers — where what Voice
    /// Operator says reaches the microphone. The headphone jack is the same
    /// built-in device with a different data source ('hdpn').
    static var isSpeakers: Bool {
        guard let device = defaultOutput(), transport(device) == kAudioDeviceTransportTypeBuiltIn else { return false }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(device, &addr),
              AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return true }
        return fourCC(value) != "hdpn"
    }

    /// Where the Mac's sound goes, for hands-free's button and its echo
    /// experiment (`AudioRoute`). The built-in speakers are `open`, the one
    /// route hands-free stands aside for (`isSpeakers`). The headphone jack is
    /// `ear`, and so is a Bluetooth or USB device that has a microphone too —
    /// AirPods, a headset dongle like the EPOS. Without one (a Bluetooth or USB
    /// speaker), or anything else — a monitor's speakers, AirPlay — it is
    /// `unsure`: the transport cannot say whether the microphone hears it.
    static var route: AudioRoute {
        guard let device = defaultOutput() else { return .unsure }
        switch transport(device) {
        case kAudioDeviceTransportTypeBuiltIn:
            return isSpeakers ? .open : .ear
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeUSB:
            return hasInput(device) ? .ear : .unsure
        default:
            return .unsure
        }
    }

    /// The Mac's own microphone: the built-in device with input streams, if any
    /// (none with the lid shut on some Macs).
    static func builtInMicrophone() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices) == noErr else { return nil }
        return devices.first { transport($0) == kAudioDeviceTransportTypeBuiltIn && hasInput($0) }
    }

    /// `name (transport)` for the log — the one line that explains why the
    /// microphone just opened or closed on its own.
    static var summary: String {
        guard let device = defaultOutput() else { return "(no output device)" }
        return "\(name(device) ?? "unnamed") (\(fourCC(transport(device))))"
    }

    /// `summary` plus the device's current sample rate — a Bluetooth headset
    /// drops from 48 kHz to 24 or 16 kHz when it switches to its call profile.
    static var formatSummary: String {
        guard let device = defaultOutput() else { return summary }
        return "\(summary) at \(Int(sampleRate(device))) Hz"
    }

    static func defaultOutput() -> AudioObjectID? {
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

    private static func hasInput(_ device: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectHasProperty(device, &addr),
              AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
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

    private static func sampleRate(_ device: AudioObjectID) -> Double {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return 0 }
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
/// going away, the user picking a different output in Control Center — and logs
/// every such change, and every sample-rate change of the current device (a
/// headset switching between its music and call profiles), so an audio problem
/// can be lined up against what the hardware was doing.
///
/// The callback carries nothing: ask `OutputDevice` for the answer when it
/// arrives, so there is one place that decides what "wireless" means and no
/// cached copy of it to go stale. All of this runs on the main queue.
final class OutputDeviceWatcher: @unchecked Sendable {
    /// Fired **on the main queue**, after the change is logged.
    var onChange: (@Sendable () -> Void)?

    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var rateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var listener: AudioObjectPropertyListenerBlock?
    /// The sample-rate listener and the device it is on — moved to each new
    /// default output as it arrives.
    private var rateListener: (device: AudioObjectID, block: AudioObjectPropertyListenerBlock)?

    func start() {
        guard listener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Log.log("output device: now \(OutputDevice.formatSummary)")
            self?.watchSampleRate()
            self?.onChange?()
        }
        listener = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        if status != noErr {
            listener = nil
            Log.log("output watcher: could not observe the default output device (status \(status))")
        }
        Log.log("output device: \(OutputDevice.formatSummary)")
        watchSampleRate()
    }

    func stop() {
        unwatchSampleRate()
        guard let listener else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener)
        self.listener = nil
    }

    private func watchSampleRate() {
        unwatchSampleRate()
        guard let device = OutputDevice.defaultOutput() else { return }
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Log.log("output format: \(OutputDevice.formatSummary)")
        }
        if AudioObjectAddPropertyListenerBlock(device, &rateAddress, DispatchQueue.main, block) == noErr {
            rateListener = (device, block)
        }
    }

    private func unwatchSampleRate() {
        guard let rateListener else { return }
        AudioObjectRemovePropertyListenerBlock(rateListener.device, &rateAddress, DispatchQueue.main, rateListener.block)
        self.rateListener = nil
    }

    deinit { stop() }
}
