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

    private(set) var dictationPaused = false
    private(set) var narrationMuted = false
    private var isDictating = false
    /// The most recently pasted text, for the ⌘⌃V re-paste shortcut.
    private var lastPastedText: String?

    /// Voice-energy thresholds below which a clip is treated as "said nothing"
    /// (both must be under to skip). Tunable; logged on every dictation.
    private static let silencePeak: Float = 0.03
    private static let silenceRMS: Float = 0.006

    // `bypassMute`: play even when narration is muted (explicit user actions —
    // replay, more-details). Recording history is the enqueuer's job, not pump's.
    private struct QueuedUtterance { let utterance: Utterance; let bypassMute: Bool }
    private var queue: [QueuedUtterance] = []
    private var pumping = false
    private var current: QueuedUtterance?

    /// The session most recently *referenced* — by narration OR by any tool
    /// (repeat / more-details / surface, with or without a name). A name-less
    /// voice tool targets this session, so referencing one agent then issuing a
    /// bare tool follows that agent.
    private(set) var lastReferencedSessionKey: String?

    /// Note a session as referenced (for tools that don't play audio, e.g. surface).
    func referenceSession(_ key: String?) { if let key { lastReferencedSessionKey = key } }

    private(set) var ttsHistory: [TTSHistoryEntry] = []
    private(set) var sttHistory: [STTHistoryEntry] = []
    private(set) var commandHistory: [CommandHistoryEntry] = []
    private let historyLimit = 10
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

    init(transcriber: Transcriber = WisprTranscriber()) {
        self.transcriber = transcriber
        let loaded = historyStore.load()
        ttsHistory = loaded.tts
        sttHistory = loaded.stt
        commandHistory = loaded.commands
    }

    /// Persist + notify whenever any history list changes.
    private func historyChanged() {
        historyStore.save(.init(tts: ttsHistory, stt: sttHistory, commands: commandHistory))
        onHistoryChanged?()
    }

    // MARK: - Toggles

    func setDictationPaused(_ paused: Bool) {
        dictationPaused = paused
        onStatus?(paused ? .paused : .idle)
    }

    /// Mute/unmute Claude narration. Muting halts current speech and drops queued
    /// updates; new turns while muted are skipped (the watcher still advances, so
    /// unmuting doesn't replay a backlog). Explicit replays still play.
    func setNarrationMuted(_ muted: Bool) {
        narrationMuted = muted
        if muted {
            queue.removeAll()
            current = nil
            tts.halt()
        } else {
            pump()
        }
    }

    // MARK: - Dictation

    func beginDictation(mode: DictationMode) {
        guard !dictationPaused, !recorder.isRecording else { return }
        dictationMode = mode
        isDictating = true
        if let interrupted = current {           // barge-in: re-cue from the start
            queue.insert(interrupted, at: 0)
            current = nil
        }
        tts.halt()
        (mode == .command ? SoundEffect.commandListeningStarted : .listeningStarted).play()
        do {
            try recorder.start()
            onStatus?(mode == .command ? .commandListening : .listening)
            // Mute background media just after the start chirp, so the chirp
            // itself isn't swallowed by the system-output mute.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.recorder.isRecording else { return }
                self.muter.mute()
            }
        } catch {
            NSLog("recorder start failed: \(error)")
            isDictating = false
            onStatus?(.idle)
        }
    }

    func endDictation() {
        guard recorder.isRecording else { return }
        let wav: URL
        do {
            wav = try recorder.stop()
        } catch {
            NSLog("recorder stop failed: \(error)")
            muter.restore()
            finishDictation()
            return
        }
        let duration = recorder.lastDurationSeconds
        let peak = recorder.lastPeak
        let rms = recorder.lastRMS
        muter.restore()                    // listening done → unmute immediately
        (dictationMode == .command ? SoundEffect.commandListeningFinished : .listeningFinished).play()

        // Silence gate: if the mic never crossed a voice-energy threshold, the
        // user said nothing — skip transcription entirely rather than let Whisper
        // hallucinate "you" (this is the volume check Wispr does). Thresholds are
        // conservative; measured peak/rms are logged so they can be tuned.
        if peak < Self.silencePeak && rms < Self.silenceRMS {
            Log.log(String(format: "dictation: silent input (peak %.4f, rms %.4f) — skipping transcription", peak, rms))
            try? FileManager.default.removeItem(at: wav)
            finishDictation()
            return
        }

        onStatus?(.transcribing)
        Task { await self.finish(wav: wav, duration: duration, mode: dictationMode) }
    }

    private func finish(wav: URL, duration: TimeInterval, mode: DictationMode) async {
        var transcript = ""
        do { transcript = try await transcriber.transcribe(wavURL: wav, language: "en") }
        catch { NSLog("transcribe failed: \(error)") }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        switch mode {
        case .paste:
            if !trimmed.isEmpty {
                onStatus?(.pasting)
                pasteAndRemember(transcript)
            }
            recordSTT(wav: wav, duration: duration, transcript: transcript)   // Recent Dictations

        case .command:
            // Run the transcript through the voice-tool router only — never paste.
            var recognized = false
            if !trimmed.isEmpty, let handler = directedReplyHandler {
                recognized = await handler(transcript)
            }
            recordCommand(wav: wav, duration: duration, transcript: transcript, recognized: recognized)
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

    /// New narration from the watcher: create a depth-able history entry (keeping
    /// the original context for "More details"), then play it.
    func narrate(_ utterance: Utterance, context: [Turn]) {
        guard !narrationMuted else { return }
        let entry = TTSHistoryEntry(name: utterance.name, body: utterance.body,
                                    voiceID: utterance.voiceID, sessionKey: utterance.sessionKey,
                                    date: Date(), context: context, priorSummaries: [utterance.body])
        insertTTS(entry)
        referenceSession(utterance.sessionKey)   // the agent that just spoke
        enqueue(utterance, bypassMute: false)
    }

    /// Low-level enqueue. History recording is the caller's responsibility (so
    /// replays and barge-in re-cues don't duplicate entries).
    private func enqueue(_ utterance: Utterance, bypassMute: Bool) {
        guard bypassMute || !narrationMuted else { return }
        queue.append(QueuedUtterance(utterance: utterance, bypassMute: bypassMute))
        pump()
    }

    private func pump() {
        guard !pumping, !isDictating, !queue.isEmpty else { return }
        pumping = true
        let item = queue.removeFirst()
        current = item
        Task {
            onSpeaking?(item.utterance)
            onStatus?(.speaking)
            let finished = await tts.play(item.utterance)
            onSpeaking?(nil)
            if finished, current?.utterance == item.utterance { current = nil }
            pumping = false
            if !isDictating && !queue.isEmpty {
                pump()
            } else if current == nil {
                onStatus?(.idle)
            }
        }
    }

    // MARK: - History

    private func insertTTS(_ entry: TTSHistoryEntry) {
        ttsHistory.insert(entry, at: 0)
        if ttsHistory.count > historyLimit { ttsHistory.removeLast(ttsHistory.count - historyLimit) }
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

    private func recordSTT(wav: URL, duration: TimeInterval, transcript: String) {
        let entry = STTHistoryEntry(date: Date(), duration: duration, transcript: transcript,
                                    wavURL: persistClip(wav))
        sttHistory.insert(entry, at: 0)
        if sttHistory.count > historyLimit {
            for evicted in sttHistory[historyLimit...] {
                if let u = evicted.wavURL { try? FileManager.default.removeItem(at: u) }
            }
            sttHistory.removeLast(sttHistory.count - historyLimit)
        }
        historyChanged()
    }

    private func recordCommand(wav: URL, duration: TimeInterval, transcript: String, recognized: Bool) {
        let entry = CommandHistoryEntry(date: Date(), duration: duration, transcript: transcript,
                                        recognized: recognized, wavURL: persistClip(wav))
        commandHistory.insert(entry, at: 0)
        if commandHistory.count > historyLimit {
            for evicted in commandHistory[historyLimit...] {
                if let u = evicted.wavURL { try? FileManager.default.removeItem(at: u) }
            }
            commandHistory.removeLast(commandHistory.count - historyLimit)
        }
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
        enqueue(entry.utterance, bypassMute: true)
    }

    /// Ask for more depth on an update. With an explicit id, targets that entry;
    /// with nil, the latest update of the last-referenced session. Re-runs the
    /// summarizer on the original context + everything already spoken; adds a new
    /// depth-able entry, or speaks the escape-hatch when exhausted.
    func moreDetails(id: UUID?) {
        let target: TTSHistoryEntry? = id.flatMap { tid in ttsHistory.first { $0.id == tid } }
            ?? lastReferencedSessionKey.flatMap { lastTTSEntry(forSessionKey: $0) }
        guard let entry = target else { Log.log("more-details: no target entry"); return }
        referenceSession(entry.sessionKey)
        Task {
            let detail = await ClaudeSummarizer.elaborate(context: entry.context,
                                                          alreadySpoken: entry.priorSummaries)
            if ClaudeSummarizer.isNoMoreInfo(detail) {
                Log.log("more-details: chain exhausted for \(entry.name)")
                // Speak the escape-hatch once; don't create a depth-able entry.
                enqueue(Utterance(name: entry.name, body: detail, voiceID: entry.voiceID,
                                  sessionKey: entry.sessionKey), bypassMute: true)
                return
            }
            let next = TTSHistoryEntry(name: entry.name, body: detail, voiceID: entry.voiceID,
                                       sessionKey: entry.sessionKey, date: Date(),
                                       context: entry.context, priorSummaries: entry.priorSummaries + [detail])
            insertTTS(next)
            enqueue(next.utterance, bypassMute: true)
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
                    historyChanged()
                }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pasteAndRemember(text)
                }
            } catch { NSLog("retry transcribe failed: \(error)") }
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
                    historyChanged()
                }
                (recognized ? SoundEffect.surfaceRaised : SoundEffect.unrecognized).play()
            } catch { NSLog("retry command failed: \(error)") }
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
}
