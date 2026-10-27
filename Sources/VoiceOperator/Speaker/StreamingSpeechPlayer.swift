import AVFoundation

/// One seekable PCM timeline for an entire speech job. Sentence producers append
/// to it; ending a sentence resolves its waiter but retains the audio for rewind.
/// Cache hits and live streams both enter this graph in the same source format.
@MainActor
final class StreamingSpeechPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    /// Lifts speech to music level; see `SpeechLoudness`.
    private let limiter = SpeechLoudness.makeLimiter()
    private var format: AVAudioFormat!
    private struct Chunk { let start: Int64; let buffer: AVAudioPCMBuffer }
    private var chunks: [Chunk] = []
    private var timeline = PlaybackTimeline()
    /// When the node played, for `position(at:)`.
    private var clock = PlayingClock()
    private(set) var frameCount: Int64 = 0
    private var streamEnded = false
    private var halted = false
    private var running = false
    /// While set, scheduled audio queues up but the node does not start — see `hold()`.
    private var held = false
    private var completed = false
    private var continuation: CheckedContinuation<Bool, Never>?
    private var firstBuffer: (() -> Void)?
    private var manualRendering = false
    private var preSeekRenderTime: AVAudioTime?
    /// A forward seek can run beyond the received PCM. Carry the absolute
    /// source target through subsequent packets/sentences without re-synthesis.
    private var pendingSeekFrame: Int64?
    private(set) var rate: Float = 1
    var onDrain: (() -> Void)?
    private var configurationObserver: NSObjectProtocol?

    var duration: Double { Double(frameCount) / (format?.sampleRate ?? 24_000) }
    var atEnd: Bool { completed }
    var progress: String {
        "frames=\(frameCount) played=\(timeline.acknowledged) ended=\(streamEnded) generation=\(timeline.generation)"
    }
    private var nodeFrame: Int64 {
        guard let render = node.lastRenderTime,
              render.isSampleTimeValid || render.isHostTimeValid else { return 0 }
        // stop() resets player time, but lastRenderTime can still describe the
        // old playback until the next render. Converting that stale timestamp
        // would make the reader jump forward immediately after a rewind.
        if let stale = preSeekRenderTime,
           stale.sampleTime == render.sampleTime && stale.hostTime == render.hostTime { return 0 }
        preSeekRenderTime = nil
        guard let time = node.playerTime(forNodeTime: render), time.isSampleTimeValid else { return 0 }
        return max(0, time.sampleTime)
    }
    var position: Double {
        guard let format else { return 0 }
        if completed { return duration }
        // The source node can be ahead of the loudspeaker by the DSP/output
        // latency. Convert that small delay back into source samples. Clock
        // rate itself comes from the node, not from elapsed wall-clock time.
        let delay = Int64(max(0, node.outputPresentationLatency) * format.sampleRate * Double(rate))
        let frame = max(timeline.acknowledged, timeline.position(nodeFrame: max(0, nodeFrame - delay)))
        return Double(min(frameCount, frame)) / format.sampleRate
    }

    /// The output latency `position` allows for, in seconds: how far the
    /// loudspeaker — or a Bluetooth headset — is behind the node, as Core Audio
    /// reports it.
    var outputLatency: Double { max(0, node.outputPresentationLatency) }

    /// `position` as it would have read at `uptime` (`ProcessInfo.systemUptime`),
    /// earlier than now: where a listener was when they began talking over the
    /// voice, though the stop came later. Counts back only the time the node
    /// was actually playing, and no further than its clock last started from
    /// zero (a seek, a new session); not clamped to what has been acknowledged
    /// as played, since the point is to land before some of it.
    func position(at uptime: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        guard let format else { return 0 }
        let back = clock.playingSeconds(since: uptime, now: now)
        guard back > 0 else { return position }
        let delay = Int64((outputLatency + back) * format.sampleRate * Double(rate))
        let frame = timeline.position(nodeFrame: max(0, nodeFrame - delay))
        return Double(min(frameCount, frame)) / format.sampleRate
    }

    /// Manual rendering is for deterministic, silent transport tests only; it
    /// never opens or changes the user's audio device.
    func start(format: AVAudioFormat, manualRendering: Bool = false) throws {
        self.format = format
        self.manualRendering = manualRendering
        engine.attach(node)
        engine.attach(timePitch)
        engine.attach(limiter)
        engine.connect(node, to: timePitch, format: format)
        engine.connect(timePitch, to: limiter, format: format)
        engine.connect(limiter, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = SpeechLoudness.ceilingTrim
        if manualRendering {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        } else {
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.outputChanged() }
            }
        }
        try engine.start()
        if !manualRendering { AudioRecorder.noteOutputEngineStarted() }
        // Hands-free's echo experiment (or `--echo-capture`): what this plays, for the echo canceller.
        if !manualRendering, EchoReference.shared.wanted {
            let latency = outputLatency
            EchoReference.shared.tap(engine) { latency }
        }
    }

    /// The output device or its format changed under us — AirPods connecting, a
    /// headset switching profile, another output picked. AVAudioEngine stops
    /// itself and drops everything scheduled, so without this the job would sit
    /// at its position until cancelled. Restart on the new hardware and
    /// re-schedule from where the listener was.
    private func outputChanged() {
        // A change the engine rode out (it is still running) needs nothing.
        guard !halted, !engine.isRunning else { return }
        let resumeAt = position
        do { try engine.start() }
        catch {
            Log.log("tts playback: could not restart after an output change: \(error)")
            return
        }
        Log.log(String(format: "tts playback: output changed (%@, engine %.0f Hz) — resuming at %.2fs",
                       OutputDevice.formatSummary, engine.outputNode.outputFormat(forBus: 0).sampleRate, resumeAt))
        if !completed, frameCount > 0 { seek(to: resumeAt) }
    }

    /// Queue audio without starting playback until `release()`. Synthesis keeps
    /// scheduling into the timeline meanwhile, so the wait costs no synthesis
    /// time. `onStart` still fires on the first buffer: that is when the sentence
    /// is ready, which is what the job queue tracks.
    func hold() { held = true }

    func release() {
        guard held else { return }
        held = false
        if !halted, !running, timeline.nodeEnd > 0 { play() }
    }

    func beginSentence(onStart: @escaping () -> Void) {
        guard !halted else { return }
        streamEnded = false
        completed = false
        firstBuffer = onStart
    }

    func schedule(_ buffer: AVAudioPCMBuffer) {
        guard !halted, buffer.frameLength > 0 else { return }
        let start = frameCount
        chunks.append(Chunk(start: start, buffer: buffer))
        frameCount += Int64(buffer.frameLength)
        if let target = pendingSeekFrame, target >= frameCount {
            timeline.reset(at: frameCount)
        } else if let target = pendingSeekFrame {
            pendingSeekFrame = nil
            timeline.reset(at: target)
            enqueueSlice(buffer, start: start, from: target)
        } else {
            enqueue(buffer, sourceStart: start)
        }
        if let firstBuffer { self.firstBuffer = nil; firstBuffer() }
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer, sourceStart: Int64) {
        // Explicit node times let us exclude underrun silence from the source
        // playhead. Leave two render quanta when resuming a starved node.
        let current = nodeFrame
        let start = current > timeline.nodeEnd
            ? current + 1024 : timeline.nodeEnd
        timeline.schedule(sourceStart: sourceStart, count: Int64(buffer.frameLength), nodeStart: start)
        let generation = timeline.generation
        let end = sourceStart + Int64(buffer.frameLength)
        node.scheduleBuffer(buffer, at: AVAudioTime(sampleTime: start, atRate: format.sampleRate),
                            options: [], completionCallbackType: manualRendering ? .dataRendered : .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.halted,
                      self.timeline.acknowledge(end: end, generation: generation) else { return }
                self.checkDone()
            }
        }
        if !running && !held { play() }
    }

    private func play() {
        node.play()
        clock.started(at: ProcessInfo.processInfo.systemUptime)
        running = true
    }

    func endOfStream() { streamEnded = true; checkDone() }

    @discardableResult
    func skipAhead(seconds: Double) -> Bool {
        let target = pendingSeekFrame.map { Double($0) / format.sampleRate } ?? position
        return seek(to: target + seconds)
    }

    func awaitCompletion() async -> Bool {
        if halted { return false }
        if completed { return true }
        return await withCheckedContinuation { continuation = $0 }
    }

    /// Rebuild only the node's scheduled audio, leaving the synthesis producer,
    /// the sentence waiter and all already-received PCM intact.
    @discardableResult
    func seek(to seconds: Double) -> Bool {
        guard !halted, frameCount > 0 else { return false }
        let frame = max(0, Int64(seconds * format.sampleRate))
        pendingSeekFrame = frame >= frameCount ? frame : nil
        preSeekRenderTime = node.lastRenderTime
        timeline.reset(at: min(frame, frameCount)) // invalidate callbacks BEFORE stop emits them
        node.stop()
        clock.reset()
        timePitch.auAudioUnit.reset()
        running = false
        completed = false
        if pendingSeekFrame != nil {
            checkDone()
            return true
        }
        for chunk in chunks {
            let end = chunk.start + Int64(chunk.buffer.frameLength)
            guard end > frame else { continue }
            enqueueSlice(chunk.buffer, start: chunk.start, from: frame)
        }
        return true
    }

    private func enqueueSlice(_ buffer: AVAudioPCMBuffer, start: Int64, from frame: Int64) {
        let skip = max(0, frame - start)
        guard skip > 0 else { enqueue(buffer, sourceStart: start); return }
        let count = buffer.frameLength - AVAudioFrameCount(skip)
        guard let slice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
              let dst = slice.floatChannelData, let src = buffer.floatChannelData else { return }
        slice.frameLength = count
        memcpy(dst[0], src[0].advanced(by: Int(skip)), Int(count) * MemoryLayout<Float>.size)
        enqueue(slice, sourceStart: frame)
    }

    func setRate(_ value: Float) {
        rate = min(5, max(0.5, value))
        timePitch.rate = rate
    }

    func halt() {
        guard !halted else { return }
        halted = true
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        timeline.reset(at: 0)
        node.stop()
        clock.reset()
        engine.stop()
        chunks.removeAll()
        if let continuation { self.continuation = nil; continuation.resume(returning: false) }
    }
    func fail() { halt() }

    private func checkDone() {
        guard !halted, !completed, streamEnded, timeline.acknowledged >= frameCount else { return }
        completed = true
        node.pause()
        clock.paused(at: ProcessInfo.processInfo.systemUptime)
        running = false
        // Keep the graph warm and PCM retained until the job's two-second grace
        // expires (or a replacement job/dictation/cancellation invalidates it).
        if let continuation { self.continuation = nil; continuation.resume(returning: true) }
        onDrain?()
    }

    /// Exercise the real time-pitch graph without touching CoreAudio hardware.
    func renderOffline(frames: AVAudioFrameCount, into buffer: AVAudioPCMBuffer) throws -> AVAudioEngineManualRenderingStatus {
        try engine.renderOffline(frames, to: buffer)
    }
}
