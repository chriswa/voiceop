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

    /// Synthesize `text` with `say` and transcribe it through the gRPC flow path
    /// (`WisprFlowTranscriber`) — the formatted Wispr-parity path, streamed over
    /// `TranscribeStream` exactly as live dictation is. Requires
    /// `VOICEOP_BASETEN_KEY`; otherwise it exercises the `/llm/asr` fallback.
    /// One stream (endpoint etiquette). The `trace …` line it logs shows the
    /// phase-by-phase timing.
    static func runFlowGRPCTest(text: String) async {
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
            let haveKey = WisprBasetenKey.value != nil
            FileHandle.standardError.write(Data("flow-grpc-test: said \(text.count) chars; baseten key \(haveKey ? "present" : "ABSENT → /llm fallback")\n".utf8))
            let transcript = try await WisprFlowTranscriber().transcribe(wavURL: wav, language: "en")
            print("transcript: \(transcript)")
        } catch {
            FileHandle.standardError.write(Data("flow-grpc-test failed: \(error)\n".utf8))
            exit(1)
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

    /// Fetch the user's live Wispr dictionary and print the words that would ride
    /// along as `dictionary_context`. Bypasses the cache (fresh fetch each run).
    static func runDictTest() async {
        do {
            let token = try await WisprToken.shared.accessToken()
            async let personal = fetchDictJSON(path: "/api/v1/dictionary/personal", token: token)
            async let team = fetchDictJSON(path: "/api/v1/dictionary/team", token: token)
            let words = WisprDictionary.contextWords(personal: try await personal,
                                                     team: (try? await team) ?? [])
            print("dictionary_context (\(words.count) words):")
            for w in words { print("  • \(w)") }
        } catch {
            FileHandle.standardError.write(Data("dict-test failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func fetchDictJSON(path: String, token: String) async throws -> [WisprDictionary.Entry] {
        var req = URLRequest(url: URL(string: "https://api.wisprflow.ai" + path)!)
        req.setValue(token, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw TranscriberError.http(status: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                                        body: String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode([WisprDictionary.Entry].self, from: data)
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
        let summary = await ClaudeSummarizer.summarizeText("I added exponential backoff with three retries to the uploader and a unit test covering the failure path. All tests pass.")
        print("summary: \(summary ?? "(failed)")")
    }

    /// Synthesize one utterance via the TTS engine and play it, streaming as it arrives.
    /// Logs time-to-first-audio vs. total wall time so you can confirm playback
    /// starts long before synthesis finishes. Uses the default voice.
    @MainActor
    static func runTTSTest(text: String) async {
        let utterance = Utterance(text: text, voiceID: "af_heart")
        func note(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
        note("speaking: \(utterance.spokenText)")
        let engine = TTSEngine()
        let t0 = Date()
        let ok = await engine.play(utterance, onStart: {
            let s = String(format: "tts-test: first audio at %.2fs\n", Date().timeIntervalSince(t0))
            FileHandle.standardError.write(Data(s.utf8))
        })
        note(String(format: "tts-test %@ (%.2fs total)",
                    ok ? "finished" : "failed/halted", Date().timeIntervalSince(t0)))
    }
}
