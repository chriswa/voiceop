import AppKit

/// Coordinates microphone dictation with the shared speech queue. Dictation has
/// priority: starting it immediately stops the audible sentence and prevents a
/// subsequent sentence from starting until transcription has finished.
@MainActor
final class AudioArbiter {
    private let recorder = AudioRecorder()
    private let muter = OutputMuter()
    private let transcriber: Transcriber
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
    private var commandContext: DictationContext?
    private var transcriptionProgressTask: Task<Void, Never>?

    /// Tunable timing for the audible indication that transcription is ongoing.
    /// The cue itself is synthesized to last `cueDuration` (see SoundEffects).
    private enum TranscriptionProgressCue {
        static let initialDelay: Duration = .milliseconds(1_500)
        static let cueDuration: Duration = .milliseconds(1_500)
        static let repeatGap: Duration = .seconds(1)
    }

    init(transcriber: Transcriber = WisprFlowTranscriber()) {
        self.transcriber = transcriber
        let loaded = historyStore.load()
        sttHistory = loaded.stt
        commandHistory = loaded.commands
        sttDir = HistoryStore.supportDir.appendingPathComponent("stt-history", isDirectory: true)
        try? FileManager.default.createDirectory(at: sttDir, withIntermediateDirectories: true)
    }

    func beginDictation(mode: DictationMode) {
        guard !recorder.isRecording else { return }
        self.mode = mode
        isDictating = true
        onDictationBegan?()
        (mode == .command ? SoundEffect.commandListeningStarted : .listeningStarted).play()
        do {
            try recorder.start()
            onStatus?(mode == .command ? .commandListening : .listening)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.recorder.isRecording else { return }
                self.muter.mute()
            }
        } catch {
            Log.log("recorder start failed: \(error)")
            isDictating = false
            onDictationEnded?()
            onStatus?(.idle)
        }
    }

    /// Capture command routing context at stop, not at key-down: this is the app
    /// the user intentionally had selected when they finished speaking.
    func endDictation(context: DictationContext? = nil) {
        guard recorder.isRecording else { return }
        commandContext = context
        let wav: URL
        do { wav = try recorder.stop() }
        catch {
            Log.log("recorder stop failed: \(error)")
            muter.restore(); finishDictation(); return
        }
        let duration = recorder.lastDurationSeconds
        let peak = recorder.lastPeak
        let rms = recorder.lastRMS
        muter.restore()
        let silent = peak < 0.025 && rms < 0.005
        if silent {
            SoundEffect.silenceSkipped.play()
            record(wav: wav, duration: duration, transcript: "", command: mode == .command,
                   error: "no speech detected")
            finishDictation()
            return
        }
        (mode == .command ? SoundEffect.commandListeningFinished : .listeningFinished).play()
        onStatus?(.transcribing)
        startTranscriptionProgressCue()
        Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await self.transcriber.transcribe(wavURL: wav, language: "en")
                self.stopTranscriptionProgressCue()
                let command = self.mode == .command
                self.record(wav: wav, duration: duration, transcript: text, command: command, error: nil)
                if command {
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let context = self.commandContext { self.onCommand?(text, context) }
                } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.pasteAndRemember(text)
                }
            } catch {
                self.stopTranscriptionProgressCue()
                Log.log("transcribe failed: \(error)")
                SoundEffect.transcriptionFailed.play()
                self.record(wav: wav, duration: duration, transcript: "", command: self.mode == .command,
                            error: TranscriberError.userMessage(for: error))
            }
            self.finishDictation()
        }
    }

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
