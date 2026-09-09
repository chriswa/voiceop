import AVFoundation

/// Holds a Voice Processing I/O ducking lease while narration is active.
///
/// This is intentionally independent of the TTS players. Voice Processing I/O
/// owns a full duplex hardware graph, while the low-latency TTS players have
/// their own proven output graphs. Coupling them made a Voice I/O start failure
/// turn into a silent sentence. Here a failure only means narration proceeds
/// without ducking.
///
/// The lease owns the *input* device, which is the microphone a dictation is
/// about to record from, so its graph work runs on `AudioGraphQueue` alongside
/// the recorder's — see that type for why the two cannot be allowed to race.
/// `start()` and `stop()` therefore only enqueue: they are safe to call from the
/// trigger key's event-tap callback, which `engine.start()`/`stop()` (~600 ms
/// each) would not be.
final class NarrationDucker: @unchecked Sendable {
    /// Both fields are touched only on `AudioGraphQueue.shared`.
    private var engine: AVAudioEngine?
    /// Kept alive by the graph. Its silent render makes Voice Processing I/O an
    /// active output client without adding microphone audio or an audible tone.
    private var silence: AVAudioSourceNode?

    func start() {
        AudioGraphQueue.shared.async { [self] in startOnQueue() }
    }

    /// Release the lease. Ordering, not completion, is what callers rely on: work
    /// enqueued after this — a dictation's tap install, above all — runs after the
    /// teardown has finished.
    func stop() {
        AudioGraphQueue.shared.async { [self] in stopOnQueue() }
    }

    /// Release the lease before returning. Only for `applicationWillTerminate`,
    /// where there is no later turn of the run loop to finish the job in.
    func stopSynchronously() {
        AudioGraphQueue.shared.sync { [self] in stopOnQueue() }
    }

    private func startOnQueue() {
        guard engine == nil else { return }
        let candidate = AVAudioEngine()
        do {
            let input = candidate.inputNode
            // Voice Processing I/O requires the input node's output format and
            // output node's input format to be identical. The built-in mic is
            // mono while the speakers are stereo, so the engine's default graph
            // violates that requirement and fails at output-unit initialization.
            let voiceFormat = input.outputFormat(forBus: 0)
            candidate.connect(candidate.mainMixerNode, to: candidate.outputNode,
                              format: voiceFormat)
            try input.setVoiceProcessingEnabled(true)
            input.isVoiceProcessingInputMuted = true
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                    enableAdvancedDucking: false, duckingLevel: .mid)

            let silence = AVAudioSourceNode(renderBlock: Self.renderSilence)
            candidate.attach(silence)
            candidate.connect(silence, to: candidate.mainMixerNode, format: voiceFormat)
            try candidate.start()
            self.engine = candidate
            self.silence = silence
            Log.log("tts ducking: active (maximum other-audio ducking)")
        } catch {
            candidate.stop()
            Log.log("tts ducking: unavailable; narration continues normally: \(error)")
        }
    }

    private func stopOnQueue() {
        guard let engine else { return }
        engine.stop()
        engine.disconnectNodeInput(engine.mainMixerNode)
        if let silence { engine.detach(silence) }
        self.silence = nil
        self.engine = nil
        Log.log("tts ducking: released")
    }

    /// Core Audio calls a source node on its real-time I/O thread. This must be
    /// nonisolated: accessing the main actor from that thread is a runtime trap,
    /// not merely a concurrency warning.
    nonisolated private static func renderSilence(
        _ isSilence: UnsafeMutablePointer<ObjCBool>,
        _ timestamp: UnsafePointer<AudioTimeStamp>,
        _ frameCount: AVAudioFrameCount,
        _ audioBufferList: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        isSilence.pointee = true
        for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
        }
        return noErr
    }
}
