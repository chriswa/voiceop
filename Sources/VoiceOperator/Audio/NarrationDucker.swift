import AVFoundation

/// Holds a Voice Processing I/O ducking lease while narration is active.
///
/// This is intentionally independent of the TTS players. Voice Processing I/O
/// owns a full duplex hardware graph, while the low-latency TTS players have
/// their own proven output graphs. Coupling them made a Voice I/O start failure
/// turn into a silent sentence. Here a failure only means narration proceeds
/// without ducking.
@MainActor
final class NarrationDucker {
    private var engine: AVAudioEngine?
    /// Kept alive by the graph. Its silent render makes Voice Processing I/O an
    /// active output client without adding microphone audio or an audible tone.
    private var silence: AVAudioSourceNode?

    func start() {
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

    func stop() {
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
