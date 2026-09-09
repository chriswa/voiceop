import Foundation

/// The one queue every `AVAudioEngine` graph mutation in this process runs on —
/// tap install and removal, `start()`, `stop()`, node attach and detach — for
/// both the capture graph (`AudioRecorder`) and the narration ducker's Voice
/// Processing I/O graph (`NarrationDucker`).
///
/// **Two engines, one queue, because they share one piece of hardware.** Voice
/// Processing I/O owns the input device, so bringing it down reconfigures the
/// microphone: Core Audio then tears down every other engine on that device and
/// posts `AVAudioEngineConfigurationChange`. Run on separate queues, a dictation
/// that barges in on narration starts its capture graph and has the ducker's
/// teardown demolish it a few tens of milliseconds later — capture that never
/// delivers a single buffer, which reaches the user as a dictation that records
/// nothing and does not even chirp. Serialized here, the teardown is always
/// enqueued ahead of the tap install and has finished before capture begins.
///
/// It is also why neither engine's lifecycle may run on the main thread:
/// stopping the ducker's engine blocks for ~600 ms, and the dictation trigger
/// key is handled from an event tap that macOS disables if its callback is that
/// slow.
enum AudioGraphQueue {
    static let shared = DispatchQueue(label: "com.voiceoperator.audio-graph",
                                      qos: .userInitiated)
}
