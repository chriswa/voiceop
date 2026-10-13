import AppKit
import Foundation
import AVFoundation

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

            let transcript = try await WisprTranscriber().transcribe(wavData: Data(contentsOf: wav), language: "en")
            print("transcript: \(transcript)")
        } catch {
            FileHandle.standardError.write(Data("asr-test failed: \(error)\n".utf8))
        }
    }

    /// Synthesize `text` with `say` and transcribe it through the gRPC flow path
    /// (`WisprFlowProvider`) — the formatted Wispr-parity path, streamed over
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
            let transcript = try await WisprFlowProvider().transcribe(wavURL: wav)
            print("transcript: \(transcript)")
        } catch {
            FileHandle.standardError.write(Data("flow-grpc-test failed: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Synthesize `text` with `say` and dictate it through a provider's *live*
    /// path — a `TranscriptionLeg` fed 100 ms slices in real time, then finished,
    /// exactly as a held key does. The `trace …` line shows the timing.
    static func runProviderTest(provider id: TranscriptionProviderID, text: String) async {
        do {
            let tmp = FileManager.default.temporaryDirectory
            let aiff = tmp.appendingPathComponent("vo-say-\(UUID().uuidString).aiff")
            let wavURL = aiff.deletingPathExtension().appendingPathExtension("wav")
            defer { try? FileManager.default.removeItem(at: aiff)
                    try? FileManager.default.removeItem(at: wavURL) }
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-o", aiff.path, text]
            try say.run(); say.waitUntilExit()
            try AudioRecorder.convertToASRWav(from: aiff, to: wavURL)
            let clip = try Data(contentsOf: wavURL)
            let wav = try WAVFile.parse(clip)

            let provider = TranscriptionProviders.provider(id)
            if let problem = await provider.prewarm() {
                FileHandle.standardError.write(Data("provider-test: \(id.rawValue) not ready: \(problem)\n".utf8))
            }
            let trace = DictationTrace("provider-test")
            let leg = TranscriptionLeg(provider: provider, target: DictationTarget(), trace: trace)
            let slice = 3_200   // 100 ms of 16 kHz PCM16
            var offset = 0
            while offset < wav.samples.count {
                let end = min(offset + slice, wav.samples.count)
                leg.append(wav.samples.subdata(in: offset ..< end))
                offset = end
                try await Task.sleep(for: .milliseconds(100))
            }
            trace.mark("key-up")
            let outcome = try await leg.finish(tail: Data(), openGrace: .seconds(2), clip: { clip })
            trace.mark("done")
            trace.flush()
            if let failure = outcome.liveFailure {
                FileHandle.standardError.write(Data("provider-test: live path failed (\(failure)), fell back\n".utf8))
            }
            print("transcript: \(outcome.text)")
        } catch {
            FileHandle.standardError.write(Data("provider-test failed: \(error)\n".utf8))
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
            let transcript = try await WisprTranscriber().transcribe(wavData: Data(contentsOf: url), language: "en")
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

    /// Render the menu-bar icon in every transcript-style combination to a PNG
    /// contact sheet, so the badges can be judged at their real size instead of by
    /// eye through a screenshot. Each row is drawn at 2× (Retina, as the menu bar
    /// draws it) and then magnified with no interpolation, over both a light and a
    /// dark menu-bar background. Writes to the given path (default /tmp).
    @MainActor
    static func runIconPreview(path: String) async {
        let styles: [TranscriptStyle] = [
            .normal,
            TranscriptStyle(lowercaseFirst: true),
            TranscriptStyle(lowercaseFirst: true, trimTrailingPunctuation: true),
            TranscriptStyle(trimTrailingPunctuation: true),
            TranscriptStyle(discard: true),
        ]
        let statuses: [OperatorStatus] = [.listening, .commandListening]
        let scale: CGFloat = 2, zoom: CGFloat = 8, pad: CGFloat = 4
        let cell = MenuBarController.icon(status: .listening, muted: false).size

        let cols = styles.count, rows = statuses.count * 2   // × light/dark
        let cellW = (cell.width + pad * 2) * zoom, cellH = (cell.height + pad * 2) * zoom
        let sheet = NSSize(width: cellW * CGFloat(cols), height: cellH * CGFloat(rows))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(sheet.width.rounded(.up)),
                                         pixelsHigh: Int(sheet.height.rounded(.up)),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .none
        var row = 0
        for status in statuses {
            for dark in [true, false] {
                let bg: NSColor = dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.93, alpha: 1)
                for (col, style) in styles.enumerated() {
                    let frame = NSRect(x: CGFloat(col) * cellW, y: sheet.height - CGFloat(row + 1) * cellH,
                                       width: cellW, height: cellH)
                    bg.setFill(); frame.fill()
                    // Render the icon into its own 2× bitmap first, so the zoom
                    // magnifies real pixels rather than re-rendering vectors.
                    let icon = MenuBarController.icon(status: status, muted: false, style: style)
                    guard let small = NSBitmapImageRep(bitmapDataPlanes: nil,
                                                       pixelsWide: Int(cell.width * scale),
                                                       pixelsHigh: Int(cell.height * scale),
                                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                                       bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                    small.size = cell
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: small)
                    let bounds = NSRect(origin: .zero, size: cell)
                    // A fresh rep's memory is uninitialised — clear it, or the
                    // icon lands on an opaque white block instead of the menu bar.
                    NSGraphicsContext.current?.cgContext.clear(bounds)
                    icon.draw(in: bounds)
                    NSGraphicsContext.restoreGraphicsState()
                    // Wrapped in an NSImage rather than drawn as a bare rep, which
                    // composites with `copy` and would paint the icon's
                    // transparent margin as an opaque block.
                    let magnified = NSImage(size: cell)
                    magnified.addRepresentation(small)
                    magnified.draw(in: frame.insetBy(dx: pad * zoom, dy: pad * zoom))
                }
                row += 1
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            try png.write(to: url)
            print("icon preview → \(url.path)  (rows: listening dark/light, command dark/light; "
                  + "cols: normal, a, a+x, x, trash)")
        } catch {
            FileHandle.standardError.write(Data("icon-preview failed: \(error)\n".utf8))
        }
    }

    /// Summarize a small synthetic turn via Haiku (claude-print-daemon). One request.
    static func runSummarizeTest() async {
        let summary = await ClaudeSummarizer.summarizeText("I added exponential backoff with three retries to the uploader and a unit test covering the failure path. All tests pass.")
        print("summary: \(summary ?? "(failed)")")
    }

    /// Synthesize one utterance via the TTS engine and play it, streaming as it arrives.
    /// Logs time-to-first-audio vs. total wall time so you can confirm playback
    /// starts long before synthesis finishes. Uses the default voice.
    @MainActor
    static func runTTSTest(text: String) async {
        let utterance = Utterance(text: text, voiceID: KokoroSynthesizer.defaultVoiceID)
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

    /// Reproduce (and now verify the fix for) "dictation after barge-in captures
    /// nothing": hold a narration-ducking lease, then release it around the start
    /// of a recording the way interrupting TTS with the trigger key does, and
    /// report whether the microphone ever delivers a buffer.
    ///
    /// `ordered` releases the lease before `AudioRecorder.start()` and waits
    /// `delayMS` first — 0, the default, is back-to-back, which is what
    /// `beginDictation` does; both engines sharing `AudioGraphQueue` is what makes
    /// that ordering hold. `racing` releases it `delayMS` *after* the start
    /// instead, which is the arrangement that killed capture outright.
    ///
    /// Needs the microphone, so it is a manual check rather than a unit test:
    /// `swift run VoiceOperator --duck-race-test ordered|racing[:ms]`.
    @MainActor
    static func runDuckRaceTest(ordered: Bool, delayMS: Int) async {
        @Sendable func note(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { _ in
                note("  ! AVAudioEngineConfigurationChange")
            }
        defer { NotificationCenter.default.removeObserver(observer) }

        let ducker = NarrationDucker()
        ducker.start()
        try? await Task.sleep(for: .milliseconds(1_500))

        let recorder = AudioRecorder()
        let heard = Heard()
        recorder.onFirstAudio = { heard.mark() }
        recorder.onStartFailed = { reason in note("  ! start failed: \(reason)") }

        // delayMS < 0 in ordered mode: never release the lease during the
        // recording at all — the "hold it through the dictation" alternative.
        let held = ordered && delayMS < 0
        if ordered, !held {
            ducker.stop()
            if delayMS > 0 { try? await Task.sleep(for: .milliseconds(delayMS)) }
        }
        let t0 = Date()
        do { try recorder.start() } catch { note("start threw \(error)"); return }
        note("  recorder.start() returned after \(Int(Date().timeIntervalSince(t0) * 1000))ms")
        if !ordered {
            try? await Task.sleep(for: .milliseconds(delayMS))
            ducker.stop()
        }
        try? await Task.sleep(for: .seconds(4))
        let clip = try? recorder.stop()   // PCM16
        ducker.stopSynchronously()
        let first = heard.at.map { "\(Int($0.timeIntervalSince(t0) * 1000))ms" } ?? "NEVER"
        if let pcm = clip {
            let perSecond = stride(from: 0, to: pcm.count, by: AudioRecorder.asrSampleRate * 2).map { off -> String in
                let end = min(off + AudioRecorder.asrSampleRate * 2, pcm.count)
                return String(format: "%.4f", AudioRecorder.levels(pcm16: Data(pcm[off..<end])).peak)
            }
            note("  peak per second: " + perSecond.joined(separator: " "))
        }
        note(String(format: "duck-race %@ delay=%dms: firstAudio=%@ bytes=%d peak=%.4f rms=%.4f",
                    held ? "held" : (ordered ? "ordered" : "racing"), delayMS, first,
                    clip?.count ?? -1, recorder.lastPeak, recorder.lastRMS))

    }

    /// First-audio timestamp, written from the audio thread.
    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var stamp: Date?
        var at: Date? { lock.lock(); defer { lock.unlock() }; return stamp }
        func mark() { lock.lock(); if stamp == nil { stamp = Date() }; lock.unlock() }
    }
}
