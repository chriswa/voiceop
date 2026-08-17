import AVFoundation

/// Plays PCM audio incrementally as it arrives, so playback starts on the first
/// chunk instead of waiting for a complete file (unlike file-based
/// `SpeechPlayer`). Buffers are `schedule`d as they're decoded; the caller signals
/// `endOfStream()` when no more will come. `awaitCompletion()` resolves `true` on
/// natural finish (stream ended *and* every scheduled buffer played) or `false`
/// on `halt()` (barge-in) / `fail()` (synthesis or engine error).
@MainActor
final class StreamingSpeechPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()

    // Completion bookkeeping. Playback is "done" only when the stream has ended
    // AND every scheduled buffer has finished playing — re-checked from both the
    // per-buffer completion callback and `endOfStream()`, so a network underrun
    // (played == scheduled while more is still coming) doesn't finish early, and a
    // stream that ends after the last buffer drained doesn't hang.
    private var scheduled = 0
    private var played = 0
    private var streamEnded = false

    private var continuation: CheckedContinuation<Bool, Never>?
    /// Set once when playback resolves. Lets a resolution that happens before
    /// `awaitCompletion()` is called still be returned (and enforces resolve-once).
    private var settled: Bool?
    private var started = false

    /// Fired the moment the first buffer is scheduled (audio is about to sound).
    var onFirstBuffer: (@MainActor () -> Void)?

    /// Completion bookkeeping as one log-ready line.
    ///
    /// This is what tells a stalled clip's two failure modes apart. `scheduled=0`
    /// means no audio ever arrived from the provider, so the stall is upstream in
    /// synthesis; `played < scheduled` with `streamEnded=true` means the audio
    /// arrived but `AVAudioPlayerNode` stopped delivering its completion
    /// callbacks, which is the engine being torn out from under us.
    var progress: String {
        "scheduled=\(scheduled) played=\(played) streamEnded=\(streamEnded) "
            + "settled=\(settled.map { "\($0)" } ?? "pending")"
    }

    /// Start the engine for `format` (float32 mono). Throws if the audio engine
    /// can't start, so the caller can fall back to the one-shot WAV path.
    func start(format: AVAudioFormat) throws {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()
        node.play()
        started = true
    }

    /// Schedule one decoded buffer for playback. No-op after resolution.
    func schedule(_ buffer: AVAudioPCMBuffer) {
        guard started, settled == nil else { return }
        let isFirst = scheduled == 0
        scheduled += 1
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            // Completion callbacks run off the main actor; hop back to mutate state
            // (mirrors SpeechPlayer.audioPlayerDidFinishPlaying).
            Task { @MainActor in
                guard let self else { return }
                self.played += 1
                self.checkDone()
            }
        }
        if isFirst { onFirstBuffer?() }
    }

    /// No more buffers will be scheduled. May resolve immediately if everything
    /// scheduled has already played (including the empty-clip case).
    func endOfStream() {
        streamEnded = true
        checkDone()
    }

    /// Await natural completion (`true`) or halt/failure (`false`).
    func awaitCompletion() async -> Bool {
        if let settled { return settled }
        return await withCheckedContinuation { continuation = $0 }
    }

    /// Barge-in: stop playback now and resolve `false`.
    func halt() { resolve(false) }

    /// Stream or engine error: stop playback and resolve `false`.
    func fail() { resolve(false) }

    private func checkDone() {
        if streamEnded && played == scheduled { resolve(true) }
    }

    private func resolve(_ ok: Bool) {
        guard settled == nil else { return }
        // Logged at every resolution, not just the unhappy ones: the pairing of
        // "stream: playing" with a resolve line is what proves a clip finished,
        // and its absence is the whole signature of the hang this exists to find.
        Log.log("tts player: resolved \(ok ? "finished" : "stopped") — scheduled=\(scheduled) played=\(played) streamEnded=\(streamEnded)")
        settled = ok
        node.stop()
        engine.stop()
        if let c = continuation { continuation = nil; c.resume(returning: ok) }
    }
}
