import AppKit

/// Coordinates microphone dictation with the shared speech queue. Dictation has
/// priority: starting it immediately stops the audible sentence and prevents a
/// subsequent sentence from starting until transcription has finished.
///
/// Dictation is **streamed**, the way Wispr Flow does it. The moment the trigger
/// key goes down three things start at once: the microphone, the gRPC stream to
/// Baseten, and an upload pump. The pump encodes each new slice of captured PCM
/// into 20 ms opus packets and pushes them up the already-open stream while the
/// user is still speaking, so when the key comes up all that is left to do is
/// commit and wait for the tail plus the formatting pass.
///
/// The previous design did none of this: it recorded to a file, and only after
/// the key came up did it fetch a token, encode the whole clip, dial a fresh TLS
/// connection and issue a *unary* call carrying every packet at once. Server-side
/// ASR time therefore scaled with clip length and landed entirely after the user
/// stopped talking, which is why a 25-second dictation took five seconds to come
/// back and anything over 28 seconds was cut into sequential round trips.
@MainActor
final class AudioArbiter {
    private let recorder = AudioRecorder()
    private let muter = OutputMuter()
    private let transcriber: Transcriber
    private let liveTranscriber: LiveTranscriber?
    private let tts = TTSEngine()
    private let historyStore = HistoryStore()
    private let sttDir: URL

    var onStatus: ((OperatorStatus) -> Void)?
    var onHistoryChanged: (() -> Void)?
    var onCommand: ((String, DictationContext) -> Void)?
    var onDictationBegan: (() -> Void)?
    var onDictationEnded: (() -> Void)?

    private(set) var sttHistory: [STTHistoryEntry] = []
    private(set) var commandHistory: [CommandHistoryEntry] = []
    private var lastPastedText: String?
    private var isDictating = false
    private var mode: DictationMode = .paste
    private var transcriptionProgressTask: Task<Void, Never>?
    private var live: LiveDictation?

    /// Voice-energy thresholds below which a clip counts as "said nothing".
    private static let silencePeak: Float = 0.025
    private static let silenceRMS: Float = 0.005

    /// A silent clip no longer than this is treated as an accidental brush of the
    /// trigger key and discarded in complete silence — no cue, no history entry.
    /// Recording now starts on key-down rather than after a hold threshold, so
    /// stray taps do produce (empty) recordings, and they should be invisible.
    /// Must exceed the hotkey's lock window, since a lone quick tap always records
    /// for at least that long.
    private static let accidentalTapSeconds: Double = 0.8

    /// How often the upload pump drains newly captured audio into the stream.
    /// Wispr's renderer hands over a chunk every 40 ms; we poll a shared buffer
    /// instead, and 100 ms keeps the server within a couple of frames of live
    /// while costing one cheap encode per tick.
    private static let uploadInterval: TimeInterval = 0.1

    /// Slack added to the start cue's own length when deciding how much audio to
    /// keep out of the silence gate. The window is anchored at the moment the cue
    /// is triggered, so this only has to cover `AVAudioPlayer` start-up, the
    /// speaker-to-microphone path, and ring-out.
    private static let cueCaptureMargin: Double = 0.2

    /// How long, after key-up, to keep waiting for a stream that is still opening
    /// before giving up on it and transcribing the recorded clip instead.
    private static let streamOpenGrace: Duration = .seconds(2)

    /// If no microphone buffer has arrived by now, something is wrong with
    /// capture (permissions, a device that never started). Wispr has the same
    /// watchdog — `NoAudioDuringDictationError` at 5 s.
    private static let noAudioWarningSeconds: TimeInterval = 3

    /// Tunable timing for the audible indication that transcription is ongoing.
    /// The cue itself is synthesized to last `cueDuration` (see SoundEffects).
    private enum TranscriptionProgressCue {
        static let initialDelay: Duration = .milliseconds(1_500)
        static let cueDuration: Duration = .milliseconds(1_500)
        static let repeatGap: Duration = .seconds(1)
    }

    init(transcriber: Transcriber = WisprFlowTranscriber()) {
        self.transcriber = transcriber
        self.liveTranscriber = transcriber as? LiveTranscriber
        let loaded = historyStore.load()
        sttHistory = loaded.stt
        commandHistory = loaded.commands
        sttDir = HistoryStore.supportDir.appendingPathComponent("stt-history", isDirectory: true)
        try? FileManager.default.createDirectory(at: sttDir, withIntermediateDirectories: true)
    }

    /// Establish the warm gRPC connection and pre-fetch the credentials dictation
    /// needs, so the first dictation of a session is as quick as the tenth.
    func prewarm() {
        FlowChannel.shared.warmUp()
        Task { await WisprToken.shared.prewarm() }
        Task { _ = await WisprDictionary.shared.contextWords() }
        // Synthesizing the cue bank happens on first use and is not instant. Do it
        // now: the start cue is on the critical path for "safe to talk", and the
        // silence-gate exclusion window is anchored the moment we ask for it.
        _ = SoundBank.shared
    }

    // MARK: - Live dictation state

    /// Everything belonging to the dictation currently in flight.
    @MainActor
    private final class LiveDictation {
        let trace: DictationTrace
        let mode: DictationMode
        /// One encoder for the whole dictation: opus is stateful across frames,
        /// so a fresh encoder mid-stream would corrupt the audio.
        let encoder: OpusEncoder?
        var session: FlowSession?
        var opening: Task<Void, Never>?
        /// Packets encoded before the stream finished opening.
        var pending: [Data] = []
        /// Captured PCM bytes already handed to the encoder.
        var offset = 0
        var pump: Timer?
        /// Sends are chained rather than fired concurrently — audio packet order
        /// is load-bearing and two tasks racing into the actor could reorder them.
        var sendChain: Task<Void, Never>?
        /// Set when the stream is unusable, so we stop feeding a dead socket and
        /// fall back once the user finishes.
        var broken = false
        /// Set once this dictation is definitively over and its stream should be
        /// thrown away. Distinct from "no longer the *current* dictation": the
        /// arbiter clears `live` at key-up while the commit is still in flight, so
        /// identity against `AudioArbiter.live` is not a liveness test.
        var abandoned = false
        var heardAudio = false
        /// PCM captured but not yet encoded, snapshotted synchronously at key-up.
        /// Read from the recorder later would race the *next* dictation's
        /// `start()`, which resets the shared capture buffer.
        var tailPCM = Data()

        init(trace: DictationTrace, mode: DictationMode, encoder: OpusEncoder?) {
            self.trace = trace
            self.mode = mode
            self.encoder = encoder
        }
    }

    // MARK: - Begin

    func beginDictation(mode: DictationMode, trace: DictationTrace = DictationTrace()) {
        guard !recorder.isRecording else { return }
        self.mode = mode
        isDictating = true
        onDictationBegan?()

        let encoder = try? OpusEncoder()
        if encoder == nil { Log.log("dictation: opus encoder unavailable — live upload disabled") }
        let live = LiveDictation(trace: trace, mode: mode, encoder: encoder)
        self.live = live

        // The start cue means "it is safe to talk now", so it must wait for the
        // microphone to actually deliver samples rather than fire on key-down.
        // Fires on the audio thread; hop to main before touching anything.
        recorder.onFirstAudio = { [weak self] in
            DispatchQueue.main.async { self?.captureBecameLive() }
        }
        do {
            try recorder.start(trace: trace)
        } catch {
            Log.log("recorder start failed: \(error)")
            trace.note("recorder start failed: \(error)")
            trace.flush()
            self.live = nil
            isDictating = false
            onDictationEnded?()
            onStatus?(.idle)
            return
        }
        onStatus?(mode == .command ? .commandListening : .listening)

        // Open the stream concurrently with microphone start-up — neither waits
        // for the other, and by the time the first packet is encoded the socket
        // is usually already handshaked.
        openStream(for: live)
        startUploadPump(for: live)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noAudioWarningSeconds) { [weak self] in
            guard let self, let current = self.live, current === live, !current.heardAudio else { return }
            Log.log("dictation: WARNING no microphone audio after \(Self.noAudioWarningSeconds)s — check mic permission/device")
            current.trace.note("no audio within \(Self.noAudioWarningSeconds)s")
        }
    }

    /// The microphone is genuinely capturing. Chirp now, then mute background
    /// output — in that order, so the system-output mute cannot swallow our own
    /// cue. The chirp does land in the recording (the mic is live by definition),
    /// but it is a fraction of a second of pure tone at the very start and the
    /// ASR ignores it; trimming it would risk cutting a word from anyone who
    /// starts speaking over the cue.
    private func captureBecameLive() {
        guard let live, !live.heardAudio else { return }
        live.heardAudio = true
        live.trace.mark("chirp")
        let cue: SoundEffect = live.mode == .command ? .commandListeningStarted : .listeningStarted
        // Anchor the metering exclusion here, at the instant we ask for the cue,
        // rather than at a fixed offset from sample zero: how long CoreAudio took
        // to hand over that first buffer is exactly the thing we cannot predict.
        recorder.excludeFromMetering(seconds: cue.duration + Self.cueCaptureMargin)
        cue.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.recorder.isRecording else { return }
            self.muter.mute()
        }
    }

    private func openStream(for live: LiveDictation) {
        guard let liveTranscriber, live.encoder != nil else {
            live.broken = true
            return
        }
        // Nudge the pooled connection in case it dropped while the Mac slept.
        FlowChannel.shared.warmUp()
        let app = FlowAppTarget(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                name: NSWorkspace.shared.frontmostApplication?.localizedName)
        live.opening = Task { [weak self] in
            do {
                let session = try await liveTranscriber.openLiveSession(app: app, trace: live.trace)
                // Test `abandoned`, NOT `self.live === live`: the arbiter clears
                // `live` at key-up while this dictation is still being committed,
                // so identity would reject a stream that opened a moment late and
                // silently drop every such dictation back to the slow path.
                guard let self, !live.abandoned else {
                    await session.cancel()
                    return
                }
                live.session = session
                self.flushPending(for: live)
            } catch {
                // We cancelled it ourselves because the grace period expired —
                // that path already logged, and `CancellationError` renders as
                // noise. Don't report it twice under a different name.
                guard !Task.isCancelled else { return }
                let reason = TranscriberError.userMessage(for: error)
                Log.log("dictation: live stream unavailable (\(reason)) — will transcribe the clip afterwards")
                live.trace.note("stream open failed: \(reason)")
                live.broken = true
            }
        }
    }

    // MARK: - Upload pump

    private func startUploadPump(for live: LiveDictation) {
        let timer = Timer.scheduledTimer(withTimeInterval: Self.uploadInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pumpAudio(live)
            }
        }
        // .common so uploads keep flowing while the menu is open (menu tracking
        // parks the run loop outside the default mode).
        RunLoop.main.add(timer, forMode: .common)
        live.pump = timer
    }

    /// Encode whatever new audio the recorder has captured and hand it to the
    /// stream. Only whole 20 ms frames are consumed; a trailing partial frame is
    /// left in place and re-offered next tick, so no silence is ever spliced into
    /// the middle of the stream.
    private func pumpAudio(_ live: LiveDictation) {
        guard recorder.isRecording, live === self.live, !live.broken,
              let encoder = live.encoder else { return }
        let packets: [Data]
        do {
            let slice = unencodedPCM(for: live)
            guard !slice.isEmpty else { return }
            let (audio, consumed) = try encoder.encodeWholeFrames(pcm: slice)
            live.offset += consumed
            packets = audio.packets
        } catch {
            Log.log("dictation: opus encode failed: \(error)")
            live.broken = true
            return
        }
        guard !packets.isEmpty else { return }
        deliver(packets, to: live)
    }

    /// Captured bytes the encoder has not seen yet. Only valid while this
    /// dictation is the one recording — the capture buffer is shared and reset by
    /// the next `start()`.
    private func unencodedPCM(for live: LiveDictation) -> Data {
        let available = recorder.capturedByteCount
        guard available > live.offset else { return Data() }
        return recorder.capturedData(offset: live.offset, maxCount: available - live.offset)
    }

    private func deliver(_ packets: [Data], to live: LiveDictation) {
        guard let session = live.session else {
            live.pending.append(contentsOf: packets)
            return
        }
        let batch = live.pending.isEmpty ? packets : live.pending + packets
        live.pending = []
        let previous = live.sendChain
        live.sendChain = Task {
            _ = await previous?.value
            await session.send(packets: batch)
        }
    }

    private func flushPending(for live: LiveDictation) {
        guard !live.pending.isEmpty else { return }
        deliver([], to: live)
    }

    // MARK: - End

    /// Capture command routing context at stop, not at key-down: this is the app
    /// the user intentionally had selected when they finished speaking.
    func endDictation(context: DictationContext? = nil) {
        guard recorder.isRecording else { return }
        let isCommand = mode == .command
        let live = self.live
        self.live = nil
        live?.trace.mark("key-up")
        live?.pump?.invalidate()
        live?.pump = nil

        let wav: URL
        let pcm: Data
        do { (wav, pcm) = try recorder.stop() }
        catch {
            Log.log("recorder stop failed: \(error)")
            if let live { cancelStream(live) }
            live?.trace.flush()
            muter.restore(); finishDictation(); return
        }
        live?.trace.mark("recorder-stop")
        // Snapshot the un-encoded remainder now, synchronously. Reading it later
        // from the commit task would race a new dictation's `start()`, which
        // resets the shared capture buffer — at best losing the tail, at worst
        // splicing the next utterance's audio onto this one.
        if let live { live.tailPCM = unencodedPCM(for: live) }
        let duration = recorder.lastDurationSeconds
        let peak = recorder.lastPeak
        let rms = recorder.lastRMS
        muter.restore()

        if let live { noteLeadingLevels(live, pcm: pcm) }

        let silent = peak < Self.silencePeak && rms < Self.silenceRMS
        if silent {
            if let live { cancelStream(live) }
            // A stray brush of the trigger key: stay completely quiet about it.
            if duration <= Self.accidentalTapSeconds {
                live?.trace.note(String(format: "discarded silent %.2fs tap", duration))
                live?.trace.flush()
                try? FileManager.default.removeItem(at: wav)
                finishDictation()
                return
            }
            SoundEffect.silenceSkipped.play()
            live?.trace.note("no speech detected")
            live?.trace.flush()
            record(wav: wav, duration: duration, transcript: "", command: isCommand,
                   error: "no speech detected")
            finishDictation()
            return
        }

        (isCommand ? SoundEffect.commandListeningFinished : .listeningFinished).play()
        onStatus?(.transcribing)
        startTranscriptionProgressCue()
        // Bind mode and routing context to *this* dictation rather than reading
        // the arbiter's own `mode`/context when the transcript lands. The user can
        // start a new dictation while this one is still transcribing, and the
        // instance properties will by then describe that newer one — which would
        // paste a command, or dispatch a plain dictation as one, and file either in
        // the wrong history list.
        let routingContext = context
        Task { [weak self] in
            guard let self else { return }
            defer { live?.trace.flush() }
            do {
                let text = try await self.transcribe(live, wavURL: wav)
                self.stopTranscriptionProgressCue()
                self.record(wav: wav, duration: duration, transcript: text, command: isCommand, error: nil)
                if isCommand {
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let routingContext { self.onCommand?(text, routingContext) }
                } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.pasteAndRemember(text)
                }
                live?.trace.mark("done")
            } catch {
                self.stopTranscriptionProgressCue()
                Log.log("transcribe failed: \(error)")
                live?.trace.note("failed: \(TranscriberError.userMessage(for: error))")
                SoundEffect.transcriptionFailed.play()
                self.record(wav: wav, duration: duration, transcript: "", command: isCommand,
                            error: TranscriberError.userMessage(for: error))
            }
            self.finishDictation()
        }
    }

    /// Finish the live stream if we have one; otherwise (or if it failed) fall
    /// back to transcribing the recorded clip from scratch. The fallback is a
    /// genuine failure path — routine appearances in the log mean the streaming
    /// path is broken, not that this is normal.
    private func transcribe(_ live: LiveDictation?, wavURL: URL) async throws -> String {
        if let live {
            // True once real time has gone into the streaming path — waiting for it
            // to open, or committing to it. Either way, routing the fallback back
            // through the normal transcriber would open a *second* stream and could
            // burn its whole hang guard before conceding.
            var streamWasTried = false
            if live.session == nil {
                streamWasTried = !(await awaitStreamOpen(live))
            }
            if live.session != nil, !live.broken {
                streamWasTried = true
                do { return try await commit(live) }
                catch {
                    let reason = TranscriberError.userMessage(for: error)
                    Log.log("dictation: live stream failed after commit (\(reason)) — re-transcribing the recorded clip")
                    live.trace.note("live failed: \(reason)")
                }
            }
            // Whatever went wrong, this stream is done: release it rather than
            // leaving the RPC and its response-consumer task alive.
            cancelStream(live)
            if streamWasTried, let liveTranscriber {
                // Streaming is unwell right now: skip straight to raw /llm/asr.
                live.trace.note("fell back to raw /llm/asr")
                return try await liveTranscriber.transcribeWithoutStreaming(wavURL: wavURL, language: "en")
            }
            live.trace.note("fell back to whole-clip transcription")
        }
        return try await transcriber.transcribe(wavURL: wavURL, language: "en")
    }

    /// Wait for a stream that was still opening at key-up — but not forever. The
    /// open does a token fetch, which on a captive-portal network can sit on
    /// URLSession's default timeout while the user stares at "transcribing".
    ///
    /// - Returns: whether the stream opened inside the grace period.
    @discardableResult
    private func awaitStreamOpen(_ live: LiveDictation) async -> Bool {
        guard let opening = live.opening else { return true }
        let grace = Self.streamOpenGrace
        let raced = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                // The cancellation handler is what makes the race actually bound
                // the wait: `await someTask.value` does not carry the awaiting
                // task's cancellation into `opening`, and the group drains its
                // children before returning, so without this the "grace period"
                // would wait for the open no matter how long it took.
                await withTaskCancellationHandler {
                    await opening.value
                } onCancel: {
                    opening.cancel()
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(for: grace)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !raced {
            Log.log("dictation: stream still opening \(grace) after key-up — using the recorded clip")
            live.trace.note("stream open timed out")
            live.broken = true
        }
        return raced
    }

    private func commit(_ live: LiveDictation) async throws -> String {
        guard let session = live.session else { throw TranscriberError.streamEnded }

        // Everything still unsent: packets buffered while the stream opened, plus
        // the tail the pump had not reached (snapshotted at key-up). The tail is
        // the only place a partial frame gets padded, which is correct — the
        // recording really has ended there.
        var tail = live.pending
        live.pending = []
        if let encoder = live.encoder, !live.tailPCM.isEmpty {
            do {
                tail += try encoder.encode(pcm: live.tailPCM).packets
                live.offset += live.tailPCM.count
                live.tailPCM = Data()
            } catch {
                Log.log("dictation: final opus encode failed: \(error)")
            }
        }
        _ = await live.sendChain?.value   // preserve ordering ahead of the commit
        return try await session.commit(packets: tail, timeout: FlowSession.defaultCommitTimeout)
    }

    /// Release a dictation's stream. Idempotent, and safe to call whether or not
    /// the stream ever opened — `abandoned` also stops a late-arriving open from
    /// installing a session nobody will use.
    private func cancelStream(_ live: LiveDictation) {
        live.abandoned = true
        live.sendChain?.cancel()
        if let session = live.session {
            live.session = nil
            Task { await session.cancel() }
        }
    }

    /// Record how loud the opening half-second was, in 50 ms bins.
    ///
    /// Expect the first two bins to hold the start cue. What matters is what
    /// follows: if those bins are near zero and speech only appears several bins
    /// in, the user was talking before capture caught up — the empirical answer
    /// to "why did it miss my first words".
    private func noteLeadingLevels(_ live: LiveDictation, pcm: Data) {
        let profile = AudioRecorder.leadingLevelProfile(pcm16: pcm)
        guard !profile.isEmpty else { return }
        live.trace.note("lead(50ms bins) " + profile.map { String(format: "%.3f", $0) }.joined(separator: ","))
    }

    // MARK: - Other actions

    func speakClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        SpeechJobManager.shared.enqueueLocal(text: text)
    }

    func summarizeClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        onStatus?(.summarizing)
        Task { [weak self] in
            defer { self?.onStatus?(.idle) }
            guard let summary = await ClaudeSummarizer.summarizeText(text), !summary.isEmpty else {
                SoundEffect.transcriptionFailed.play(); return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(summary, forType: .string)
            SoundEffect.clipFinished.play()
        }
    }

    func repasteLast() { if let lastPastedText { pasteAndRemember(lastPastedText) } }
    func retrySTT(id: UUID) { guard let e = sttHistory.first(where: { $0.id == id }), let url = e.wavURL else { return }; retry(url, id: id, command: false) }
    func retryCommand(id: UUID) { guard let e = commandHistory.first(where: { $0.id == id }), let url = e.wavURL else { return }; retry(url, id: id, command: true) }
    func copySTT(id: UUID) { if let e = sttHistory.first(where: { $0.id == id }) { copy(e.transcript) } }
    func copyCommand(id: UUID) { if let e = commandHistory.first(where: { $0.id == id }) { copy(e.transcript) } }

    private func retry(_ url: URL, id: UUID, command: Bool) {
        onStatus?(.transcribing)
        startTranscriptionProgressCue()
        Task { [weak self] in
            guard let self else { return }
            defer { self.onStatus?(.idle) }
            do {
                let text = try await self.transcriber.transcribe(wavURL: url, language: "en")
                self.stopTranscriptionProgressCue()
                if command {
                    if let i = self.commandHistory.firstIndex(where: { $0.id == id }) { self.commandHistory[i].transcript = text; self.commandHistory[i].error = nil }
                } else {
                    if let i = self.sttHistory.firstIndex(where: { $0.id == id }) { self.sttHistory[i].transcript = text; self.sttHistory[i].error = nil }
                    self.pasteAndRemember(text)
                }
                self.save()
            } catch {
                self.stopTranscriptionProgressCue()
                SoundEffect.transcriptionFailed.play()
            }
        }
    }

    private func finishDictation() {
        stopTranscriptionProgressCue()
        onStatus?(.idle)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.isDictating = false
            self.onDictationEnded?()
        }
    }

    /// Starts after a short grace period so quick transcriptions stay quiet,
    /// then repeats once the previous cue has fully played plus its pause.
    private func startTranscriptionProgressCue() {
        stopTranscriptionProgressCue()
        transcriptionProgressTask = Task {
            do {
                try await Task.sleep(for: TranscriptionProgressCue.initialDelay)
                while !Task.isCancelled {
                    SoundEffect.transcriptionPending.play()
                    try await Task.sleep(for: TranscriptionProgressCue.cueDuration)
                    try await Task.sleep(for: TranscriptionProgressCue.repeatGap)
                }
            } catch is CancellationError {
                // Transcription completed or failed while the task was asleep.
            } catch {
                Log.log("transcription progress cue failed: \(error)")
            }
        }
    }

    private func stopTranscriptionProgressCue() {
        transcriptionProgressTask?.cancel()
        transcriptionProgressTask = nil
        SoundEffect.transcriptionPending.stop()
    }

    private func pasteAndRemember(_ text: String) { lastPastedText = text; TextInserter.paste(text); SoundEffect.pasted.play() }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    private func persist(_ wav: URL) -> URL? {
        let dst = sttDir.appendingPathComponent("\(UUID().uuidString).wav")
        try? FileManager.default.copyItem(at: wav, to: dst); try? FileManager.default.removeItem(at: wav)
        return FileManager.default.fileExists(atPath: dst.path) ? dst : nil
    }
    private func record(wav: URL, duration: TimeInterval, transcript: String, command: Bool, error: String?) {
        if command { commandHistory.insert(CommandHistoryEntry(date: Date(), duration: duration, transcript: transcript, recognized: false, error: error, wavURL: persist(wav)), at: 0) }
        else { sttHistory.insert(STTHistoryEntry(date: Date(), duration: duration, transcript: transcript, error: error, wavURL: persist(wav)), at: 0) }
        save()
    }
    private func save() { historyStore.save(.init(stt: sttHistory, commands: commandHistory)); onHistoryChanged?() }

    func playSentence(text: String, voiceID: String,
                      onStart: @escaping @Sendable () -> Void = {}) async -> Bool {
        onStatus?(.requestingTTS)
        let result = await tts.play(Utterance(text: text, voiceID: voiceID), onStart: { [weak self] in
            self?.onStatus?(.speaking)
            onStart()
        })
        if !isDictating { onStatus?(.idle) }
        return result
    }
    func haltSpeech() { tts.stop() }
    func prefetchSentence(text: String, voiceID: String) { tts.prefetch(text: text, voiceID: voiceID) }
}

struct DictationContext: Sendable {
    let bundleIdentifier: String?
}
