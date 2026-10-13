import AVFoundation

/// The level speech is played at, for both places it is heard: played here
/// (`StreamingSpeechPlayer` runs `makeLimiter()` live in its graph) and on the
/// phone (`/v1/synthesize` hands over `boosted(_:)`'s WAV, which the client
/// plays as is).
///
/// Kokoro speaks at roughly -24 dBFS RMS with peaks up to about -3 dBFS, well
/// under music at the same volume. Scaling the PCM alone cannot close that gap:
/// any fixed gain past +3 dB clips the hottest sentences. Apple's peak limiter
/// adds `makeupGainDB` ahead of its lookahead limiter, which shaves the speech
/// peaks this pushes past full scale instead of letting them clip.
enum SpeechLoudness {
    /// +12 dB puts speech at about -12 dBFS RMS, level with music on Spotify.
    /// It shaves peaks during ~16% of speech.
    static let makeupGainDB: Float = 12
    /// The limiter's ceiling is 0 dBFS but it can overshoot by a hair (measured
    /// 1.0004); this trim on the mixer after it keeps the output under 1.0.
    static let ceilingTrim: Float = 0.98

    static func makeLimiter() -> AVAudioUnitEffect {
        let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, makeupGainDB, 0)
        return limiter
    }

    /// The same gain and limiter, rendered offline into a new clip of the same
    /// length. The limiter's lookahead delay is trimmed off the front, so word
    /// timings measured against the original still line up.
    static func boosted(_ wav: WAVFile) throws -> WAVFile {
        let count = wav.samples.count / 2
        guard count > 0 else { return wav }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(wav.sampleRate),
                                   channels: 1, interleaved: false)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        input.frameLength = AVAudioFrameCount(count)
        wav.samples.withUnsafeBytes { raw in
            let s16 = raw.bindMemory(to: Int16.self)
            for i in 0..<count { input.floatChannelData![0][i] = Float(Int16(littleEndian: s16[i])) / 32768 }
        }

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let limiter = makeLimiter()
        engine.attach(node)
        engine.attach(limiter)
        engine.connect(node, to: limiter, format: format)
        engine.connect(limiter, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = ceilingTrim
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        defer { engine.stop() }
        node.scheduleBuffer(input)
        node.play()

        let delay = Int((limiter.auAudioUnit.latency * format.sampleRate).rounded())
        let block = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        var rendered: [Float] = []
        rendered.reserveCapacity(count + delay + 4096)
        while rendered.count < count + delay {
            let want = AVAudioFrameCount(min(4096, count + delay - rendered.count))
            guard try engine.renderOffline(want, to: block) == .success else { throw WAVFile.WAVError.malformed }
            rendered += UnsafeBufferPointer(start: block.floatChannelData![0], count: Int(block.frameLength))
        }

        var out = Data(capacity: count * 2)
        for v in rendered[delay..<(delay + count)] {
            let bits = UInt16(bitPattern: Int16(max(-1, min(1, v)) * 32767))
            out.append(UInt8(bits & 0xFF))
            out.append(UInt8(bits >> 8))
        }
        return WAVFile(sampleRate: wav.sampleRate, samples: out)
    }
}
