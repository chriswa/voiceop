import AppKit

/// The coordination brain (DESIGN.md). Owns the invariant that dictation and
/// TTS never collide:
///   dictation-start → mute output + halt current TTS + block the TTS queue;
///   dictation-end   → unmute, transcribe + paste, then (after a delay) drain queue.
///
/// The system-output mute is scoped to the *listening* window (started just after
/// the start chirp, restored on release) so our own dictation chirps stay
/// audible. Barge-in: an utterance interrupted by dictation is re-cued from the
/// start (cheap, since its audio is cached).
@MainActor
final class AudioArbiter {
    private let recorder = AudioRecorder()
    private let muter = OutputMuter()
    private let transcriber: Transcriber
    private let tts = TTSEngine()

    var onStatus: ((OperatorStatus) -> Void)?
    /// Fired around TTS playback so a listener can forward speaking events to
    /// spaceterm (start: the utterance; stop: nil).
    var onSpeaking: ((Utterance?) -> Void)?
    /// Given a finished transcript, decide if it's a directed reply (the user
    /// said only a call-sign). Returns true if handled (raised a surface), in
    /// which case we skip pasting. Runs before paste.
    var directedReplyHandler: ((String) async -> Bool)?
    /// Fired when either history list changes, so the menu can refresh.
    var onHistoryChanged: (() -> Void)?
    /// Fired with the unread-update count (for the menu-bar badge).
    var onUnreadChanged: ((Int) -> Void)?
    /// Fired when mute state changes (for the icon's prohibition overlay).
    var onMutedChanged: ((Bool) -> Void)?

    private(set) var narrationMuted = false
    private var isDictating = false
    /// The most recently pasted text, for the ⌘⌃V re-paste shortcut.
    private var lastPastedText: String?

    /// Voice-energy thresholds below which a clip is treated as "said nothing"
    /// (both must be under to skip). Tunable; logged on every dictation. Nudged
    /// down slightly from 0.03/0.006 after a quiet-but-real dictation (peak
    /// 0.0275) was falsely skipped.
    private static let silencePeak: Float = 0.025
    private static let silenceRMS: Float = 0.005

    // Narration updates not fully heard yet (oldest→newest) — the "unread" list
    // and badge source. Muting halts and leaves them here; unmuting replays oldest
    // first. `oneOff` is explicit playback (replay / more-details / escape) that
    // bypasses mute and isn't counted as unread.
    private var unread: [Utterance] = []
    private var oneOff: [Utterance] = []
    private var current: Utterance?
    private var currentIsNarration = false
    private var pumping = false
    private var halted = false      // set when we deliberately stop playback

    /// How many summarizations (narration + on-demand clipboard) are awaiting
    /// Claude/Haiku right now. Ref-counted so overlapping ones share the single
    /// blue "summarizing" state; the entry cue plays only on the first.
    private var summarizingCount = 0
    /// The most recent clipboard summarize input→output, so re-invoking on
    /// unchanged text (or on our own last output) never re-summarizes. In-memory
    /// only — resets on restart, which is enough to stop repeat re-summarization.
    private var lastSummaryInput: String?
    private var lastSummaryOutput: String?
    private var summarizingClipboard = false   // guard against double-trigger
    /// Voice for ⌘⌃S verbatim clipboard speech (session-less, so not registry-assigned).
    private let clipboardVoiceID = NameVoiceTable.defaultVoice.voiceID

    var unreadCount: Int { unread.count }
    /// Whether a clip is being fetched or played right now — the "Skip" action is
    /// only meaningful while this is true.
    var isPlaying: Bool { pumping }
    private func notifyUnread() { onUnreadChanged?(unread.count) }
    private func haltPlayback() { halted = true; tts.halt() }

    /// Skip the clip playing now, treating it as fully heard: stop the current
    /// audio and let `pump()` advance to the next queued clip. Unlike mute /
    /// barge-in (`haltPlayback`), the skipped narration leaves the unread queue
    /// rather than staying to replay in full — it's already recorded in Recent
    /// Updates. No-op when nothing is playing.
    func skipCurrent() {
        guard pumping, current != nil else { return }
        tts.skip()
    }

    /// Voice "skip". A command dictation barges in on whatever was playing
    /// (`beginDictation` → `haltPlayback`), returning an interrupted narration to
    /// the front of `unread` to resume once dictation ends. By the time the
    /// "skip" transcript is recognized nothing is playing, so we drop that
    /// front-of-queue entry — the clip that was playing — so playback advances to
    /// the next update instead of resuming it. It stays in Recent Updates. Falls
    /// back to a live skip if a clip is somehow still playing.
    func skipQueued() {
        if pumping, current != nil { tts.skip(); return }
        guard !unread.isEmpty else { return }
        unread.removeFirst()
        notifyUnread()
    }

    /// The session most recently *referenced* — by narration OR by any tool
    /// (repeat / more-details / surface, with or without a name). A name-less
    /// voice tool targets this session, so referencing one agent then issuing a
    /// bare tool follows that agent.
    private(set) var lastReferencedSessionKey: String?

    /// Note a session as referenced (for tools that don't play audio, e.g. surface).
    /// Persisted so "Focus last speaker" / ⌘⌃J survive a restart.
    func referenceSession(_ key: String?) {
        guard let key, key != lastReferencedSessionKey else { return }
        lastReferencedSessionKey = key
        saveState()
    }

    private(set) var ttsHistory: [TTSHistoryEntry] = []
    private(set) var sttHistory: [STTHistoryEntry] = []
    private(set) var commandHistory: [CommandHistoryEntry] = []
    /// How many entries the menu shows. The dictation/command stores retain
    /// more than this (see `clipRetention`); TTS history is trimmed to it.
    private let menuHistoryLimit = 10
    /// Dictation/command entries — and their audio — are kept until they are
    /// both beyond the newest `menuHistoryLimit` AND at least this old, so a
    /// clip can always be retried/recovered for a week even after it has
    /// scrolled out of the menu.
    private static let clipRetention: TimeInterval = 7 * 86_400
    private let historyStore = HistoryStore()
    /// Which mode the in-progress dictation is in (set at begin, used at finish).
    private var dictationMode: DictationMode = .paste
    // Dictation clips (STT + command) live in Application Support so "Retry"
    // survives restarts and Cache purges (unlike the regenerable TTS audio cache).
    private let sttDir: URL = {
        let dir = HistoryStore.supportDir.appendingPathComponent("stt-history", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // WisprFlowTranscriber = the formatted Wispr-parity gRPC path, falling back
    // to raw /llm/asr (WisprTranscriber) when the Baseten key is absent or gRPC fails.
    init(transcriber: Transcriber = WisprFlowTranscriber()) {
        self.transcriber = transcriber
        let loaded = historyStore.load()
        ttsHistory = loaded.tts
        sttHistory = loaded.stt
        commandHistory = loaded.commands
        lastReferencedSessionKey = loaded.lastReferencedSessionKey   // restore "Focus last speaker"
        reapExpiredClips()   // clips may have aged past retention while the app was closed
    }

    /// Persist all durable arbiter state — the history lists plus the
    /// last-referenced session (so "Focus last speaker" survives a restart).
    private func saveState() {
        historyStore.save(.init(tts: ttsHistory, stt: sttHistory, commands: commandHistory,
                                lastReferencedSessionKey: lastReferencedSessionKey))
    }

    /// Persist + notify whenever any history list changes.
    private func historyChanged() {
        saveState()
        onHistoryChanged?()
    }

    // MARK: - Toggles

    /// Mute/unmute Claude narration. Muting stops playback immediately; any update
    /// not fully heard stays in the unread list. Unmuting replays the unread
    /// updates oldest→newest. Explicit one-off plays (replay/more-details) ignore
    /// mute.
    func setNarrationMuted(_ muted: Bool) {
        narrationMuted = muted
        onMutedChanged?(muted)
        if muted { haltPlayback() } else { pump() }
    }

    /// The agent currently speaking, or the most-recently referenced — for the
    /// menu's "Focus <name>" shortcut.
    func currentOrLastAgent() -> (name: String, sessionKey: String)? {
        if currentIsNarration, let c = current, let key = c.sessionKey { return (c.name, key) }
        if let key = lastReferencedSessionKey, let e = lastTTSEntry(forSessionKey: key) {
            return (e.name, key)
        }
        return nil
    }

    // MARK: - Dictation

    // Live chunking (Wispr Flow's model): while recording, every full
    // `liveChunkSeconds` of captured audio is transcribed immediately —
    // sequentially, one request in flight — so when the user stops talking only
    // a short tail is left to transcribe, regardless of dictation length.

    /// Per-dictation live-chunking state. A class (not properties on the
    /// arbiter) so an in-flight chunk request and a still-running `finish()`
    /// keep operating on *their* dictation's state even if the user has
    /// already started the next dictation.
    @MainActor
    private final class LiveChunkSession {
        var texts: [String] = []          // per-chunk transcripts, in order
        var offset = 0                    // captured bytes already dispatched
        var task: Task<Void, Never>?      // the one chunk request in flight
        var failure: String?              // first failure; stops further sends
    }
    private var liveSession: LiveChunkSession?
    private var liveChunkTimer: Timer?

    func beginDictation(mode: DictationMode) {
        guard !recorder.isRecording else { return }
        dictationMode = mode
        isDictating = true
        haltPlayback()   // barge-in: a narration update in progress returns to unread
        (mode == .command ? SoundEffect.commandListeningStarted : .listeningStarted).play()
        do {
            try recorder.start()
            startLiveChunking()
            onStatus?(mode == .command ? .commandListening : .listening)
            // Mute background media just after the start chirp, so the chirp
            // itself isn't swallowed by the system-output mute.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.recorder.isRecording else { return }
                self.muter.mute()
            }
        } catch {
            Log.log("recorder start failed: \(error)")
            isDictating = false
            onStatus?(.idle)
        }
    }

    private func startLiveChunking() {
        liveSession = LiveChunkSession()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pumpLiveChunks() }
        }
        // .common so the pump keeps firing while the menu is open (menu
        // tracking parks the run loop outside the default mode).
        RunLoop.main.add(timer, forMode: .common)
        liveChunkTimer = timer
    }

    /// If a full chunk of un-dispatched audio has accumulated and nothing is in
    /// flight, transcribe it. Chains itself on completion so a backlog drains.
    private func pumpLiveChunks() {
        guard recorder.isRecording, let session = liveSession,
              session.task == nil, session.failure == nil else { return }
        let chunkBytes = Int(transcriber.liveChunkSeconds * Double(AudioRecorder.asrSampleRate)) * 2
        guard recorder.capturedByteCount - session.offset >= chunkBytes else { return }
        let slice = recorder.capturedData(offset: session.offset, maxCount: chunkBytes)
        session.offset += slice.count
        let index = session.texts.count + 1

        // No per-chunk silence gate: mirroring Wispr Flow, every chunk of a
        // recording is transcribed. Wispr sends its whole packet buffer and only
        // uses silence for auto-stop / dead-mic watchdogs — never to drop audio.
        // A per-chunk gate here judged each 28 s slice in isolation (RMS averaged
        // over the whole slice), so a soft word or a word split across a chunk
        // boundary fell under the bar and that chunk's speech was lost even though
        // the clip as a whole was clearly voiced. The whole-clip gate in
        // endDictation() is the single silence decision — and since it measures
        // the entire recording, "the clip is silent" already means "every chunk
        // was silent."
        Log.log("dictation: transcribing live chunk \(index) mid-recording")
        session.task = Task { [weak self, transcriber] in
            do {
                let wavData = WAVFile(sampleRate: AudioRecorder.asrSampleRate, samples: slice).data
                let text = try await transcriber.transcribe(wavData: wavData, language: "en")
                session.texts.append(text)
            } catch {
                Log.log("dictation: live chunk \(index) failed: \(error)")
                session.failure = TranscriberError.userMessage(for: error)
            }
            session.task = nil
            self?.pumpLiveChunks()   // a further chunk may already be waiting
        }
    }

    func endDictation() {
        guard recorder.isRecording else { return }
        liveChunkTimer?.invalidate()
        liveChunkTimer = nil
        let session = liveSession
        liveSession = nil
        let wav: URL
        do {
            wav = try recorder.stop()
        } catch {
            Log.log("recorder stop failed: \(error)")
            muter.restore()
            finishDictation()
            return
        }
        let duration = recorder.lastDurationSeconds
        let peak = recorder.lastPeak
        let rms = recorder.lastRMS
        muter.restore()                    // listening done → unmute immediately

        // Silence gate: if the mic never crossed a voice-energy threshold, the
        // user said nothing — skip transcription entirely rather than let Whisper
        // hallucinate "you" (this is the volume check Wispr does). Thresholds are
        // conservative; measured peak/rms are logged so they can be tuned.
        //
        // We still record the clip to history (marked as skipped) rather than
        // deleting it: the audio is the only evidence of a borderline capture, so
        // keeping it lets us investigate false skips and gives the user visible
        // feedback + a Retry, instead of the dictation vanishing without a trace.
        let isSilent = peak < Self.silencePeak && rms < Self.silenceRMS
        // Sad "silence skipped" cue when nothing was captured; otherwise the
        // normal stop-listening confirmation. (Only one, so they don't overlap.)
        if isSilent {
            SoundEffect.silenceSkipped.play()
        } else {
            (dictationMode == .command ? SoundEffect.commandListeningFinished : .listeningFinished).play()
        }

        if isSilent {
            let note = String(format: "no speech detected (peak %.4f, rms %.4f)", peak, rms)
            Log.log("dictation: silent input — skipping transcription, \(note)")
            switch dictationMode {
            case .paste:
                recordSTT(wav: wav, duration: duration, transcript: "", error: note)
            case .command:
                recordCommand(wav: wav, duration: duration, transcript: "", recognized: false, error: note)
            }
            finishDictation()
            return
        }

        onStatus?(.transcribing)
        Task { await self.finish(wav: wav, duration: duration, mode: dictationMode, session: session) }
    }

    private func finish(wav: URL, duration: TimeInterval, mode: DictationMode,
                        session: LiveChunkSession?) async {
        // Wait out any live chunk request still in flight when recording stopped.
        while let task = session?.task { await task.value }

        var transcript = ""
        var failure = session?.failure
        if failure == nil {
            do {
                var texts = session?.texts ?? []
                let tailOffset = session?.offset ?? 0
                // Transcribe the tail: whatever was captured after the last full
                // live chunk. transcribe(wavData:) re-chunks internally if the
                // tail itself is over one chunk long (e.g. chunks backed up).
                let samples = try WAVFile(contentsOf: wav).samples
                if tailOffset < samples.count {
                    let tail = WAVFile(sampleRate: AudioRecorder.asrSampleRate,
                                       samples: samples.subdata(in: tailOffset..<samples.count))
                    texts.append(try await transcriber.transcribe(wavData: tail.data, language: "en"))
                }
                if texts.count > 1 {
                    Log.log("dictation: merged \(texts.count) chunk transcripts")
                }
                transcript = WisprTranscriber.joinChunkTexts(texts)
            } catch {
                failure = TranscriberError.userMessage(for: error)
                Log.log("transcribe failed: \(error)")
            }
        }
        if failure != nil { SoundEffect.transcriptionFailed.play() }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        switch mode {
        case .paste:
            if !trimmed.isEmpty {
                onStatus?(.pasting)
                pasteAndRemember(transcript)
            }
            recordSTT(wav: wav, duration: duration, transcript: transcript, error: failure)   // Recent Dictations

        case .command:
            // Run the transcript through the voice-tool router only — never paste.
            var recognized = false
            if !trimmed.isEmpty, let handler = directedReplyHandler {
                recognized = await handler(transcript)
            }
            recordCommand(wav: wav, duration: duration, transcript: transcript,
                          recognized: recognized, error: failure)
            if !trimmed.isEmpty {
                (recognized ? SoundEffect.surfaceRaised : SoundEffect.unrecognized).play()
            }
        }
        finishDictation()
    }

    /// After a short delay (so a paste-triggered app sound isn't clipped), clear
    /// the dictation flag and resume the TTS queue.
    private func finishDictation() {
        onStatus?(.idle)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.isDictating = false
            self.pump()
        }
    }

    // MARK: - TTS queue

    /// New narration from the watcher: record a history entry (keeping the
    /// original context and the spoken summary so an "aside" can be grounded in
    /// them) and add it to the unread list.
    /// Plays now if unmuted, otherwise becomes backlog.
    func narrate(_ utterance: Utterance, context: [Turn]) {
        let entry = TTSHistoryEntry(name: utterance.name, body: utterance.body,
                                    voiceID: utterance.voiceID, sessionKey: utterance.sessionKey,
                                    date: Date(), context: context, priorSummaries: [utterance.body])
        insertTTS(entry)
        unread.append(utterance)
        notifyUnread()
        pump()
    }

    /// Explicit playback (replay / more-details / escape) — plays even when muted,
    /// not counted as unread.
    private func playOneOff(_ utterance: Utterance) {
        oneOff.append(utterance)
        pump()
    }

    private func pump() {
        guard !pumping, !isDictating else { return }
        let item: Utterance
        let isNarration: Bool
        if !oneOff.isEmpty {
            item = oneOff.removeFirst(); isNarration = false
        } else if !narrationMuted, let next = unread.first {
            item = next; isNarration = true          // peek; removed on natural finish
        } else {
            onStatus?(.idle); return
        }
        pumping = true
        current = item
        currentIsNarration = isNarration
        halted = false
        if isNarration { referenceSession(item.sessionKey) }
        let requesting = tts.audioState(for: item) != .ready   // not cached → will fetch
        Task {
            if requesting {
                onStatus?(.requestingTTS)          // cyan: fetching the clip
                SoundEffect.clipRequested.play()
            }
            onSpeaking?(item)
            let finished = await tts.play(item, onStart: { [weak self] in
                self?.onStatus?(.speaking)          // green: audio is playing
                SoundEffect.clipStarted.play()
            })
            let wasHalted = halted
            onSpeaking?(nil)
            pumping = false
            current = nil
            currentIsNarration = false
            if finished {
                SoundEffect.clipFinished.play()
                if isNarration, unread.first == item { unread.removeFirst(); notifyUnread() }
            } else if isNarration, !wasHalted {
                // Synth failed (not an interruption) → drop so we don't retry-loop.
                if unread.first == item { unread.removeFirst(); notifyUnread() }
            }
            // Interrupted narration (wasHalted) stays at unread front to replay in full.
            if !isDictating { pump() } else { onStatus?(.idle) }
        }
    }

    // MARK: - History

    private func insertTTS(_ entry: TTSHistoryEntry) {
        ttsHistory.insert(entry, at: 0)
        if ttsHistory.count > menuHistoryLimit { ttsHistory.removeLast(ttsHistory.count - menuHistoryLimit) }
        historyChanged()
    }

    /// Move a temp recording into the persistent clip store; returns its URL.
    private func persistClip(_ wav: URL) -> URL? {
        let dst = sttDir.appendingPathComponent("\(UUID().uuidString).wav")
        try? FileManager.default.copyItem(at: wav, to: dst)
        let ok = FileManager.default.fileExists(atPath: dst.path)
        try? FileManager.default.removeItem(at: wav)
        return ok ? dst : nil
    }

    /// Dispose of an evicted history clip. Clips whose transcription failed are
    /// moved to `saved-clips/` instead of deleted — the audio is the only copy
    /// of words the user never got text for, so eviction must not destroy it.
    private func discardEvictedClip(_ url: URL?, transcriptionFailed: Bool) {
        guard let url else { return }
        guard transcriptionFailed else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let dir = HistoryStore.supportDir.appendingPathComponent("saved-clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.moveItem(at: url, to: dst)
        Log.log("history: preserved failed dictation audio at \(dst.path)")
    }

    /// Reap dictation/command entries that are both past the menu window and
    /// older than `clipRetention`, disposing of their audio. Lists are
    /// newest-first, so the oldest entry is always last.
    private func reapExpiredClips() {
        let cutoff = Date().addingTimeInterval(-Self.clipRetention)
        while sttHistory.count > menuHistoryLimit,
              let oldest = sttHistory.last, oldest.date < cutoff {
            discardEvictedClip(oldest.wavURL, transcriptionFailed: oldest.error != nil)
            sttHistory.removeLast()
        }
        while commandHistory.count > menuHistoryLimit,
              let oldest = commandHistory.last, oldest.date < cutoff {
            discardEvictedClip(oldest.wavURL, transcriptionFailed: oldest.error != nil)
            commandHistory.removeLast()
        }
    }

    private func recordSTT(wav: URL, duration: TimeInterval, transcript: String, error: String? = nil) {
        let entry = STTHistoryEntry(date: Date(), duration: duration, transcript: transcript,
                                    error: error, wavURL: persistClip(wav))
        sttHistory.insert(entry, at: 0)
        reapExpiredClips()
        historyChanged()
    }

    private func recordCommand(wav: URL, duration: TimeInterval, transcript: String,
                               recognized: Bool, error: String? = nil) {
        let entry = CommandHistoryEntry(date: Date(), duration: duration, transcript: transcript,
                                        recognized: recognized, error: error, wavURL: persistClip(wav))
        commandHistory.insert(entry, at: 0)
        reapExpiredClips()
        historyChanged()
    }

    /// Playback state of a history entry's audio, for the menu ("synthesizing…"
    /// while its first synthesis is still writing to cache).
    func replayState(forTTS id: UUID) -> TTSEngine.AudioState {
        guard let entry = ttsHistory.first(where: { $0.id == id }) else { return .needsSynthesis }
        return tts.audioState(for: entry.utterance)
    }

    /// Replay a past update (explicit user action → plays even if narration muted).
    func replayTTS(id: UUID) {
        guard let entry = ttsHistory.first(where: { $0.id == id }) else { return }
        referenceSession(entry.sessionKey)
        playOneOff(entry.utterance)
    }

    /// Question the summarizer about an update: answer a spoken "ask" grounded in
    /// the original context + what was said, then append the Q&A and speak the
    /// answer as a new (further-askable) entry. With an explicit id, targets that
    /// entry; with nil, the latest update of the last-referenced session.
    func ask(id: UUID?, message: String) {
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { Log.log("ask: empty message"); return }
        let target: TTSHistoryEntry? = id.flatMap { tid in ttsHistory.first { $0.id == tid } }
            ?? lastReferencedSessionKey.flatMap { lastTTSEntry(forSessionKey: $0) }
        guard let entry = target else { Log.log("ask: no target entry"); return }
        referenceSession(entry.sessionKey)
        Task {
            guard let answer = await ClaudeSummarizer.ask(context: entry.context,
                                                          spoken: entry.priorSummaries,
                                                          dialogue: entry.asks,
                                                          message: msg) else {
                Log.log("ask: no answer for \(entry.name)")
                // Speak a short apology; don't extend the thread with a non-answer.
                playOneOff(Utterance(name: entry.name, body: "Sorry, I couldn't answer that.",
                                     voiceID: entry.voiceID, sessionKey: entry.sessionKey))
                return
            }
            let dialogue = entry.asks + [
                Turn(role: "user", text: msg, pos: 0, stopReason: nil),
                Turn(role: "assistant", text: answer, pos: 0, stopReason: nil),
            ]
            let next = TTSHistoryEntry(name: entry.name, body: answer, voiceID: entry.voiceID,
                                       sessionKey: entry.sessionKey, date: Date(),
                                       context: entry.context, priorSummaries: entry.priorSummaries,
                                       asks: dialogue)
            insertTTS(next)
            playOneOff(next.utterance)
        }
    }

    /// The most recent update for a given session (history is newest-first).
    func lastTTSEntry(forSessionKey key: String) -> TTSHistoryEntry? {
        ttsHistory.first { $0.sessionKey == key }
    }

    /// Re-run transcription on a stored dictation, paste the result, and update
    /// the history entry.
    func retrySTT(id: UUID) {
        guard let entry = sttHistory.first(where: { $0.id == id }), let wav = entry.wavURL else { return }
        Task {
            do {
                let text = try await transcriber.transcribe(wavURL: wav, language: "en")
                if let i = sttHistory.firstIndex(where: { $0.id == id }) {
                    sttHistory[i].transcript = text
                    sttHistory[i].error = nil
                    historyChanged()
                }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pasteAndRemember(text)
                }
            } catch {
                Log.log("retry transcribe failed: \(error)")
                SoundEffect.transcriptionFailed.play()
                if let i = sttHistory.firstIndex(where: { $0.id == id }) {
                    sttHistory[i].error = TranscriberError.userMessage(for: error)
                    historyChanged()
                }
            }
        }
    }

    /// Paste text, remember it for the ⌘⌃V re-paste shortcut, and cue.
    private func pasteAndRemember(_ text: String) {
        lastPastedText = text
        TextInserter.paste(text)
        SoundEffect.pasted.play()
    }

    /// Re-paste the last text we pasted (⌘⌃V) into the frontmost app.
    func repasteLast() {
        guard let text = lastPastedText, !text.isEmpty else {
            Log.log("re-paste: nothing pasted yet"); return
        }
        pasteAndRemember(text)
    }

    /// Copy a past dictation's transcript to the clipboard.
    func copySTT(id: UUID) {
        guard let entry = sttHistory.first(where: { $0.id == id }) else { return }
        copyToClipboard(entry.transcript)
    }

    /// Re-transcribe a stored command clip and re-run it through the voice-tool
    /// router, updating the history entry and cueing the outcome.
    func retryCommand(id: UUID) {
        guard let entry = commandHistory.first(where: { $0.id == id }), let wav = entry.wavURL else { return }
        Task {
            do {
                let text = try await transcriber.transcribe(wavURL: wav, language: "en")
                var recognized = false
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let handler = directedReplyHandler {
                    recognized = await handler(text)
                }
                if let i = commandHistory.firstIndex(where: { $0.id == id }) {
                    commandHistory[i].transcript = text
                    commandHistory[i].recognized = recognized
                    commandHistory[i].error = nil
                    historyChanged()
                }
                (recognized ? SoundEffect.surfaceRaised : SoundEffect.unrecognized).play()
            } catch {
                Log.log("retry command failed: \(error)")
                SoundEffect.transcriptionFailed.play()
                if let i = commandHistory.firstIndex(where: { $0.id == id }) {
                    commandHistory[i].error = TranscriberError.userMessage(for: error)
                    historyChanged()
                }
            }
        }
    }

    /// Copy a past command's transcript to the clipboard.
    func copyCommand(id: UUID) {
        guard let entry = commandHistory.first(where: { $0.id == id }) else { return }
        copyToClipboard(entry.transcript)
    }

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func clipboardText() -> String? {
        let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }

    // MARK: - "Waiting on Claude" state

    /// Enter the blue "waiting on Claude/Haiku" state. Ref-counted so a narration
    /// summary and an on-demand clipboard summary can overlap; the entry cue plays
    /// once, and the icon only turns blue when nothing louder (a live dictation or
    /// TTS playback) already owns it.
    func beginSummarizing() {
        summarizingCount += 1
        guard summarizingCount == 1 else { return }
        SoundEffect.summarizing.play()
        if !pumping, !isDictating { onStatus?(.summarizing) }
    }

    /// Leave the summarizing state. Only restores idle when the last summarization
    /// finishes and nothing else owns the icon — a subsequent `pump()` (narration)
    /// will set its own cyan/green regardless.
    func endSummarizing() {
        if summarizingCount > 0 { summarizingCount -= 1 }
        if summarizingCount == 0, !pumping, !isDictating { onStatus?(.idle) }
    }

    // MARK: - Clipboard actions

    /// ⌘⌃S: speak the current clipboard text verbatim through the TTS engine. This is an
    /// explicit action, so it bypasses narration mute (the one-off path) and drives
    /// the same cyan→green icon states + clip cues as narration.
    ///
    /// Pressing it again *while our own clipboard speech is playing or being
    /// fetched* means "stop": halt it and drop any queued verbatim one-offs. We
    /// gate on `verbatim` (which only clipboard speech carries) so ⌘⌃S never halts
    /// unrelated agent narration — halting that would just make `pump()` replay it
    /// from the front, the opposite of silencing.
    func speakClipboardOrHalt() {
        if pumping, current?.verbatim == true {
            haltPlayback()
            oneOff.removeAll { $0.verbatim }
            return
        }
        guard let text = clipboardText() else {
            Log.log("speak-clipboard: clipboard has no text"); return
        }
        playOneOff(Utterance(name: "", body: text, voiceID: clipboardVoiceID,
                             sessionKey: nil, verbatim: true))
    }

    /// Summarize the clipboard via Haiku and write the result back to the clipboard.
    /// Skips silently when the clipboard already holds our last summary (so it never
    /// re-summarizes its own output over and over), and reuses the cached output
    /// when the input is unchanged rather than calling Haiku again.
    func summarizeClipboard() {
        guard !summarizingClipboard else { return }
        guard let text = clipboardText() else {
            Log.log("summarize-clipboard: clipboard has no text"); return
        }
        if text == lastSummaryOutput {
            Log.log("summarize-clipboard: clipboard already holds the last summary — skipping")
            return
        }
        if text == lastSummaryInput, let cached = lastSummaryOutput {
            Log.log("summarize-clipboard: input unchanged — reusing cached summary")
            copyToClipboard(cached)
            SoundEffect.clipFinished.play()
            return
        }
        summarizingClipboard = true
        beginSummarizing()
        Task {
            defer { summarizingClipboard = false; endSummarizing() }
            guard let summary = await ClaudeSummarizer.summarizeText(text), !summary.isEmpty else {
                Log.log("summarize-clipboard: Haiku returned nothing — clipboard untouched")
                SoundEffect.transcriptionFailed.play()
                return
            }
            lastSummaryInput = text
            lastSummaryOutput = summary
            copyToClipboard(summary)
            SoundEffect.clipFinished.play()
            Log.log("summarize-clipboard: wrote \(summary.count)-char summary to clipboard")
        }
    }
}
