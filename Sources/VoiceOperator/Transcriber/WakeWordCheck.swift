import AVFoundation
import Foundation
import Speech

/// Does this short clip start with the wake word — or is it the word alone?
///
/// Spaceterm's hands-free mode listens on whichever device is always-listening
/// (the phone today) for speech that begins after a quiet spell. That device
/// cuts out its first second or so and asks here, through spaceterm, whether
/// it starts with "Control" — and only then opens a Wispr dictation, fed from
/// the start of what was said.
///
/// Apple's on-device `SpeechTranscriber` (macOS 26), never Wispr: the clips are
/// whatever was said in the room, and nothing of that may leave the Mac. The
/// clip is held in memory for the length of the call and dropped; neither it
/// nor what it said is logged unless it matched.
enum WakeWordCheck {
    /// `start`: the clip's first word is the wake word ("Control, what's…").
    /// `only`: the wake word and nothing else ("Control.").
    /// `speech`: any words at all — Spaceterm's conversation window, where
    /// anything said is for Control and the question is only whether it was
    /// words or a cough. Its words come back for the caller to weigh (filler
    /// like "hmm" is its call); this side neither keeps nor logs them.
    enum Match: String, Sendable {
        case start, only, speech
    }

    struct Result: Sendable {
        /// What the transcriber heard, for a clip that matched — empty otherwise; always, for `speech`.
        let heard: String
        let match: Bool
        let elapsedMs: Int
    }

    enum Failure: Error {
        /// This macOS has no `SpeechTranscriber`.
        case unavailable
        case audio(String)
    }

    /// Lowercased words, punctuation dropped: what matching compares.
    static func words(_ text: String) -> [String] {
        text.lowercased().unicodeScalars
            .map { CharacterSet.letters.contains($0) || $0 == "'" ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").map(String.init)
    }

    /// Whether `heard` is `word` alone: case and punctuation ignored, nothing
    /// else said. "Control?" counts; "under control" does not.
    static func isOnly(_ word: String, in heard: String) -> Bool {
        let target = words(word)
        return !target.isEmpty && words(heard) == target
    }

    /// Whether `heard` begins with `word`, punctuation ignored. "Control, what's
    /// Kevin doing" and "Control the lights" count; "under control" and
    /// "controller" do not.
    static func startsWith(_ word: String, in heard: String) -> Bool {
        let target = words(word)
        return !target.isEmpty && words(heard).starts(with: target)
    }

    /// Check 16-bit little-endian mono PCM at `sampleRate`.
    static func check(pcm: Data, sampleRate: Int, word: String, match mode: Match = .only) async throws -> Result {
        guard #available(macOS 26.0, *) else { throw Failure.unavailable }
        let started = Date()
        let heard = try await transcribe(pcm: pcm, sampleRate: sampleRate)
        let elapsed = { Int(Date().timeIntervalSince(started) * 1000) }
        if mode == .speech {
            let count = words(heard).count
            Log.log("speech check: \(count) words in \(elapsed()) ms (\(pcm.count / 2) samples)")
            return Result(heard: heard, match: count > 0, elapsedMs: elapsed())
        }
        let match = mode == .start ? startsWith(word, in: heard) : isOnly(word, in: heard)
        // Only a match is worth a log line with words in it.
        Log.log(match
            ? "wake word: \"\(heard)\" matched \"\(word)\" in \(elapsed()) ms (\(pcm.count / 2) samples)"
            : "wake word: no match in \(elapsed()) ms (\(pcm.count / 2) samples)")
        return Result(heard: match ? heard : "", match: match, elapsedMs: elapsed())
    }

    @available(macOS 26.0, *)
    private static func transcribe(pcm: Data, sampleRate: Int) async throws -> String {
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .transcription)
        try await ensureAssets(for: transcriber)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Failure.audio("no audio format for the transcriber")
        }
        let input = try buffer(pcm: pcm, sampleRate: sampleRate, format: format)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let collect = Task { () -> String in
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }
        try await analyzer.start(inputSequence: stream)
        continuation.yield(AnalyzerInput(buffer: input))
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collect.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The model is downloaded once, by the system; after that this is a no-op.
    @available(macOS 26.0, *)
    private static func ensureAssets(for transcriber: SpeechTranscriber) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Log.log("wake word: installing the on-device speech model")
            try await request.downloadAndInstall()
        }
    }

    /// s16le mono PCM as a buffer in `format`, converted if it needs to be.
    static func buffer(pcm: Data, sampleRate: Int, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let frames = pcm.count / 2
        guard frames > 0, sampleRate > 0,
              let source = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.int16ChannelData?[0] else { throw Failure.audio("empty or unreadable clip") }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            for i in 0..<frames { samples[i] = raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self) }
        }
        if source == format { return buffer }
        guard let converter = AVAudioConverter(from: source, to: format),
              let out = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(Double(frames) * format.sampleRate / Double(sampleRate)) + 64)
        else { throw Failure.audio("cannot convert \(sampleRate) Hz for the transcriber") }
        nonisolated(unsafe) let input = buffer
        nonisolated(unsafe) var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw Failure.audio("conversion failed: \(error.localizedDescription)") }
        return out
    }
}
