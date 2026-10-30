import AudioToolbox
import AVFoundation
import Foundation

/// `--headset-probe`: what makes a Bluetooth headset rebuild its audio link
/// about 2 s after a dictation's microphone closes, and so drop the music.
///
/// It opens the default input (the AirPods) for 1.5 s, closes it, and watches
/// the devices (`DeviceSettleWatch`) for 4 s, once per way of opening an input:
///
/// - `engine-stop`: an `AVAudioEngine` input tap, then `stop()` — what
///   `AudioRecorder` does. The engine runs input and output through a private
///   aggregate device.
/// - `engine-pause`: the same, `pause()` instead: the engine keeps its
///   resources, the aggregate included.
/// - `audio-queue`: an `AudioQueue` input — no engine, no output, no aggregate.
/// - `auhal-input`: a HAL output unit with only its input enabled, on the
///   input device itself — the lowest level an app can open an input at.
///
/// If the headset rebuilds its link (`out:cfge`, the stream configuration
/// changing) about 2 s after every one of them, it is the Bluetooth stack's
/// own, and nothing about how the microphone is opened will avoid it; if only
/// some do, the others are the way to open it. **It drops the music on the
/// headset several times**: run it while nothing is playing that matters.
enum HeadsetProbe {
    private static func note(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    static func run() async {
        note("headset-probe: output \(OutputDevice.formatSummary). Each way opens the default input for 1.5 s, "
             + "closes it, and watches 4 s. The music will drop.")
        for (name, open) in ways {
            try? await Task.sleep(for: .seconds(4))   // let the last one settle
            let opening = DeviceSettleWatch()
            guard let close = open() else { note("\(name): could not open"); continue }
            try? await Task.sleep(for: .seconds(1.5))
            opening.stop()
            let closing = DeviceSettleWatch()
            let closedAt = Date()
            close()
            let closeMs = Date().timeIntervalSince(closedAt) * 1000
            try? await Task.sleep(for: .seconds(4))
            closing.stop()
            let rebuilt = firstMs(of: "out:cfge", in: closing.summary)
            note(String(format: "%@: closed in %.0f ms; link rebuilt %@", name, closeMs,
                        rebuilt.map { "at +\($0) ms" } ?? "not seen"))
            note("  opening: \(opening.summary)")
            note("  closing: \(closing.summary)")
        }
    }

    private static func firstMs(of what: String, in summary: String) -> Int? {
        let parts = summary.split(separator: " ")
        for (i, part) in parts.enumerated() where part.contains(what) {
            for j in stride(from: i, through: 0, by: -1) where parts[j].hasPrefix("+") { return Int(parts[j].dropFirst()) }
        }
        return nil
    }

    /// Each way: opens, returning how to close.
    private static var ways: [(String, () -> (() -> Void)?)] { [
        ("engine-stop", { engine(pause: false) }),
        ("engine-pause", { engine(pause: true) }),
        ("audio-queue", { audioQueue() }),
        ("auhal-input", { auhal() }),
    ] }

    nonisolated(unsafe) private static var kept: [AVAudioEngine] = []

    private static func engine(pause: Bool) -> (() -> Void)? {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { _, _ in }
        do { try engine.start() } catch { return nil }
        return {
            input.removeTap(onBus: 0)
            if pause { engine.pause() } else { engine.stop() }
            // Kept for the rest of the probe, so `pause` keeps what it keeps.
            kept.append(engine)
        }
    }

    private static func audioQueue() -> (() -> Void)? {
        var format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                                 mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
                                                 mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var queue: AudioQueueRef?
        let callback: AudioQueueInputCallback = { _, queue, buffer, _, _, _ in
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }
        guard AudioQueueNewInput(&format, callback, nil, nil, nil, 0, &queue) == noErr, let queue else { return nil }
        for _ in 0..<3 {
            var buffer: AudioQueueBufferRef?
            if AudioQueueAllocateBuffer(queue, 9_600, &buffer) == noErr, let buffer { AudioQueueEnqueueBuffer(queue, buffer, 0, nil) }
        }
        guard AudioQueueStart(queue, nil) == noErr else { AudioQueueDispose(queue, true); return nil }
        return {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
        }
    }

    private static func auhal() -> (() -> Void)? {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                    componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple,
                                                    componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }
        var unitOut: AudioUnit?
        guard AudioComponentInstanceNew(component, &unitOut) == noErr, let unit = unitOut else { return nil }
        var on: UInt32 = 1, off: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, size)
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, size)
        var device = defaultInput()
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &device, UInt32(MemoryLayout<AudioObjectID>.size))
        // Nothing is read: the device's IO running is what is being tested.
        var callback = AURenderCallbackStruct(inputProc: { _, _, _, _, _, _ in noErr }, inputProcRefCon: nil)
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                             &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard AudioUnitInitialize(unit) == noErr, AudioOutputUnitStart(unit) == noErr else {
            AudioComponentInstanceDispose(unit)
            return nil
        }
        return {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
    }

    private static func defaultInput() -> AudioObjectID {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }
}
