import AVFoundation
import Foundation
import Speech

/// Listens to a remote dictation's audio, alongside Wispr, for a phrase that
/// ends it — "over and out" in Spaceterm's hands-free mode — wherever in the
/// dictation it is said.
///
/// Apple's on-device `SpeechTranscriber` (macOS 26) with volatile results, so
/// the phrase is caught as it is spoken rather than at the end of a sentence.
/// What it hears is compared and dropped; nothing is kept or logged.
final class PhraseWatcher: @unchecked Sendable {
    /// Set once, from the transcriber's results; read on every append.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() {
            lock.lock()
            let first = !value
            value = true
            lock.unlock()
            if first { Log.log("phrase watch: heard the end phrase") }
        }
    }

    private let flag = Flag()
    private let audio: AsyncStream<Data>.Continuation
    private var task: Task<Void, Never>?

    /// Whether the phrase has been heard yet.
    var heard: Bool { flag.isSet }

    /// nil on a macOS without `SpeechTranscriber`: the dictation then only ends
    /// on silence.
    init?(phrase: String) {
        guard #available(macOS 26.0, *) else { return nil }
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        audio = continuation
        let flag = flag
        task = Task {
            do {
                try await Self.watch(phrase: phrase, audio: stream) { flag.set() }
            } catch {
                Log.log("phrase watch: stopped: \(error)")
            }
        }
    }

    /// 16 kHz signed 16-bit mono, as the remote session has it.
    func feed(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        audio.yield(pcm)
    }

    func stop() {
        audio.finish()
        task?.cancel()
    }

    /// Whether `heard` contains `phrase` as whole words, in order — case,
    /// punctuation and where it falls ignored. "Over and out." and "…, over
    /// and out" count; "moreover and outside" does not.
    static func contains(_ phrase: String, in heard: String) -> Bool {
        let target = WakeWordCheck.words(phrase)
        let words = WakeWordCheck.words(heard)
        guard !target.isEmpty, words.count >= target.count else { return false }
        for start in 0...(words.count - target.count) where Array(words[start..<(start + target.count)]) == target {
            return true
        }
        return false
    }

    @available(macOS 26.0, *)
    private static func watch(phrase: String, audio: AsyncStream<Data>, onHeard: @escaping @Sendable () -> Void) async throws {
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (inputs, feed) = AsyncStream<AnalyzerInput>.makeStream()
        let results = Task {
            // Finished text so far, and the guess at what is being said now.
            var final = ""
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal { final += " " + text }
                if contains(phrase, in: result.isFinal ? final : final + " " + text) {
                    onHeard()
                    return
                }
            }
        }
        try await analyzer.start(inputSequence: inputs)
        for await pcm in audio {
            guard !Task.isCancelled else { break }
            if let buffer = try? WakeWordCheck.buffer(pcm: pcm, sampleRate: PCM16Resampler.outputRate, format: format) {
                feed.yield(AnalyzerInput(buffer: buffer))
            }
        }
        feed.finish()
        await analyzer.cancelAndFinishNow()
        results.cancel()
    }
}
