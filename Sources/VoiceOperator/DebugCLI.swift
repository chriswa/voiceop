import Foundation

/// Developer self-tests, invoked from `main.swift` via CLI flags. Not part of
/// the shipping menu-bar app.
enum DebugCLI {
    /// Synthesize `text` with `say`, transcode to the ASR WAV format, and run a
    /// single WisprTranscriber call. Prints the transcript. Makes exactly one
    /// network request (endpoint etiquette).
    static func runASRTest(text: String) async {
        do {
            let tmp = FileManager.default.temporaryDirectory
            let aiff = tmp.appendingPathComponent("vo-say-\(UUID().uuidString).aiff")
            let wav = aiff.deletingPathExtension().appendingPathExtension("wav")
            defer { try? FileManager.default.removeItem(at: aiff)
                    try? FileManager.default.removeItem(at: wav) }

            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-o", aiff.path, text]
            try say.run(); say.waitUntilExit()

            try AudioRecorder.convertToASRWav(from: aiff, to: wav)
            let bytes = (try? Data(contentsOf: wav).count) ?? 0
            FileHandle.standardError.write(Data("said \(text.count) chars -> WAV \(bytes) B\n".utf8))

            let transcript = try await WisprTranscriber().transcribe(wavURL: wav, language: "en")
            print("transcript: \(transcript)")
        } catch {
            FileHandle.standardError.write(Data("asr-test failed: \(error)\n".utf8))
        }
    }

    /// Transcribe an existing WAV file through the real chunked transcriber
    /// path (one network request per 28 s chunk). Prints the transcript.
    static func runTranscribeFile(path: String) async {
        do {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let wav = try WAVFile(contentsOf: url)
            FileHandle.standardError.write(Data(String(format: "clip: %.1fs @ %d Hz\n",
                                                       wav.duration, wav.sampleRate).utf8))
            let transcript = try await WisprTranscriber().transcribe(wavURL: url, language: "en")
            print(transcript)
        } catch {
            FileHandle.standardError.write(Data("transcribe-file failed: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Play the three dictation chirps in sequence (no network).
    @MainActor
    static func runChirpTest() async {
        for (label, effect): (String, SoundEffect) in [
            ("listeningStarted", .listeningStarted), ("listeningFinished", .listeningFinished), ("pasted", .pasted),
        ] {
            FileHandle.standardError.write(Data("chirp: \(label)\n".utf8))
            effect.play()
            try? await Task.sleep(for: .milliseconds(600))
        }
    }

    /// Summarize a small synthetic turn via Haiku (Keychain OAuth). One request.
    static func runSummarizeTest() async {
        let context = [
            Turn(role: "user", text: "Can you add retry logic to the uploader?", pos: 0, stopReason: nil),
            Turn(role: "assistant",
                 text: "I added exponential backoff with three retries to the uploader and a unit test covering the failure path. All tests pass.",
                 pos: 1, stopReason: "end_turn"),
        ]
        let summary = await ClaudeSummarizer.summarize(context: context, spoken: [])
        print("summary: \(summary)")
    }

    /// Synthesize one utterance via Cartesia and play it. Makes exactly one TTS
    /// request (cached afterward). Uses the first table voice by default.
    @MainActor
    static func runTTSTest(text: String) async {
        let voice = NameVoiceTable.all[0]
        let utterance = Utterance(name: voice.name, body: text, voiceID: voice.voiceID, sessionKey: nil)
        FileHandle.standardError.write(Data("speaking as \(voice.name): \(utterance.spokenText)\n".utf8))
        let engine = TTSEngine()
        let ok = await engine.play(utterance)
        FileHandle.standardError.write(Data("tts-test \(ok ? "finished" : "failed/halted")\n".utf8))
    }
}
