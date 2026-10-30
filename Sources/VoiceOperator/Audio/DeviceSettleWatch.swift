import CoreAudio
import Foundation

/// Watches the default output and input devices for Core Audio property
/// changes, to tell when a Bluetooth headset has finished switching profiles.
///
/// Opening or closing the AirPods' microphone makes them switch, and the music
/// drops out while they do. Nothing announces the end of a switch, but the
/// devices change properties while it happens (running state, latency, stream
/// formats): `whenQuiet` calls back once they have been still for a while. Every
/// change is kept, with its time, for the log — the record of what a switch
/// actually looks like on this Mac (`summary`).
final class DeviceSettleWatch: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.voiceop.device-settle")
    private let lock = NSLock()
    private let started = Date()
    private var events: [(ms: Int, what: String)] = []
    private var lastChange: Date?
    private var listeners: [(AudioObjectID, AudioObjectPropertyListenerBlock)] = []
    private var stopped = false

    init() {
        let devices = [("out", Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)),
                       ("in", Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice))]
        var seen: Set<AudioObjectID> = []
        for (name, device) in devices {
            guard let device, seen.insert(device).inserted else { continue }
            let block: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
                guard let self else { return }
                let what = (0..<Int(count)).map { "\(name):\(Self.fourCC(addresses[$0].mSelector))" }
                self.note(what.joined(separator: ","))
            }
            var address = Self.wildcard
            if AudioObjectAddPropertyListenerBlock(device, &address, queue, block) == noErr {
                listeners.append((device, block))
            }
        }
    }

    deinit { stop() }

    func stop() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        let installed = listeners
        listeners = []
        lock.unlock()
        guard !wasStopped else { return }
        for (device, block) in installed {
            var address = Self.wildcard
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
        }
    }

    private func note(_ what: String) {
        let now = Date()
        lock.withLock {
            guard !stopped else { return }
            lastChange = now
            if events.count < 60 { events.append((Int(now.timeIntervalSince(started) * 1000), what)) }
        }
    }

    /// `done` on the main queue once, as soon as at least `atLeast` seconds have
    /// passed since the watch began and the devices have reported no change for
    /// `quiet` seconds — or at `cap` regardless. Its argument says which.
    func whenQuiet(quiet: TimeInterval, atLeast: TimeInterval = 0, cap: TimeInterval,
                   _ done: @escaping @MainActor (_ settled: Bool) -> Void) {
        func check() {
            let now = Date()
            let elapsed = now.timeIntervalSince(started)
            let last = lock.withLock { lastChange }
            let still = now.timeIntervalSince(last ?? started)
            if elapsed >= atLeast, still >= quiet { MainActor.assumeIsolated { done(true) }; return }
            if elapsed >= cap { MainActor.assumeIsolated { done(false) }; return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { check() }
        }
        DispatchQueue.main.async { check() }
    }

    /// Every change seen, as `+ms out:sel,in:sel …`; "no device changes" when none were.
    var summary: String {
        let all = lock.withLock { events }
        guard !all.isEmpty else { return "no device changes" }
        return all.map { "+\($0.ms) \($0.what)" }.joined(separator: " ")
    }

    private static var wildcard: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioObjectPropertySelectorWildcard,
                                   mScope: kAudioObjectPropertyScopeWildcard,
                                   mElement: kAudioObjectPropertyElementWildcard)
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    private static func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        let text = String(bytes: bytes, encoding: .ascii) ?? "\(value)"
        return text.allSatisfy { $0.isASCII && !$0.isWhitespace || $0 == " " } ? text : "\(value)"
    }
}
