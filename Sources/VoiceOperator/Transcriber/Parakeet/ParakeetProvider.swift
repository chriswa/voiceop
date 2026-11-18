import FluidAudio
import Foundation

/// NVIDIA Parakeet TDT v2 (English only), on this Mac (CoreML on the Neural Engine, via
/// FluidAudio). Raw recognition with its own punctuation and casing — no clean-up
/// pass and no custom vocabulary, so names like "kubectl" come out as heard.
///
/// It is fast enough (about 190× real time on an M4 Pro) that streaming would buy
/// nothing: a session just collects the audio while the key is held and
/// transcribes all of it at key-up.
struct ParakeetProvider: TranscriptionProvider {
    let id = TranscriptionProviderID.parakeet
    var modelName: String { "parakeet-tdt-0.6b-\(ParakeetEngine.version)" }

    func prewarm() async -> String? {
        do {
            _ = try await ParakeetEngine.shared.load()
            return nil
        } catch {
            return TranscriptionFailure.message(for: error)
        }
    }

    func openSession(target: DictationTarget, trace: DictationTrace?) async throws -> any TranscriptionSession {
        // Start (or join) the model load now, so it overlaps the user speaking.
        Task { _ = try? await ParakeetEngine.shared.load() }
        return ParakeetSession(trace: trace)
    }

    func transcribe(wavData: Data) async throws -> Transcript {
        try await ParakeetEngine.shared.transcribe(pcm: WAVFile.parse(wavData).samples)
    }
}

/// A Parakeet dictation: holds the audio until the key comes up.
actor ParakeetSession: TranscriptionSession {
    private var pcm = Data()
    private let trace: DictationTrace?

    init(trace: DictationTrace?) { self.trace = trace }

    func send(pcm: Data) { self.pcm.append(pcm) }

    func commit(pcm: Data) async throws -> Transcript {
        self.pcm.append(pcm)
        trace?.mark("commit")
        let transcript = try await ParakeetEngine.shared.transcribe(pcm: self.pcm)
        trace?.mark("result")
        trace?.note(String(format: "%.1fs audio on device", Double(self.pcm.count / 2) / 16_000))
        return transcript
    }

    func cancel() { pcm = Data() }
}

/// The loaded model, shared by every Parakeet session. Loading means a download
/// of about 470 MB from Hugging Face the first time (cached under Application
/// Support/FluidAudio) and a CoreML compile of about 30 s, cached per app and
/// macOS build in Caches/<bundle id>/com.apple.e5rt.e5bundlecache — so after a
/// rebuild it still loads in 0.2 s. It is kept for the life of the process.
actor ParakeetEngine {
    static let shared = ParakeetEngine()

    static let version = AsrModelVersion.v2

    /// Every version this app has used. Once `version` loads, the downloads of
    /// the others are deleted, so switching versions doesn't leave ~470 MB
    /// behind on each Mac.
    static let knownVersions: [AsrModelVersion] = [.v2, .v3]

    /// How long a dictation waits for a load that is still under way — the app
    /// was just launched. A normal load takes 0.2 s.
    /// The CoreML compile (about 30 s) happens only when its cache is missing:
    /// the first load after a macOS update or a cleared cache, not after a
    /// rebuild. That and a first download take longer than this, and the
    /// dictation fails rather than hang.
    static let loadWait: Duration = .seconds(15)

    enum EngineError: LocalizedError {
        case stillLoading
        var errorDescription: String? { "the Parakeet model is still loading" }
    }

    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?

    /// Load the model, or join the load already under way. A failed load is
    /// forgotten so the next call tries again.
    func load() async throws -> AsrManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        let task = Task { () throws -> AsrManager in
            let started = ContinuousClock.now
            Log.log("parakeet: loading \(Self.version) (downloads on first use)")
            let models = try await AsrModels.downloadAndLoad(version: Self.version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            Log.log("parakeet: ready in \(started.duration(to: .now).formatted(.units(allowed: [.seconds, .milliseconds])))")
            Self.removeOtherVersions()
            return manager
        }
        loading = task
        do {
            let manager = try await task.value
            self.manager = manager
            loading = nil
            return manager
        } catch {
            loading = nil
            Log.log("parakeet: load failed: \(error.localizedDescription)")
            throw error
        }
    }

    private static func removeOtherVersions() {
        for other in knownVersions where other != version {
            let directory = AsrModels.defaultCacheDirectory(for: other)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            do {
                try FileManager.default.removeItem(at: directory)
                Log.log("parakeet: removed the unused \(other) model at \(directory.path)")
            } catch {
                Log.log("parakeet: couldn't remove the unused \(other) model at \(directory.path): \(error.localizedDescription)")
            }
        }
    }

    /// Transcribe 16 kHz mono PCM16, with each word's time from its first
    /// sample. Waits up to `loadWait` for a load in progress, then gives up with
    /// `stillLoading`.
    func transcribe(pcm: Data) async throws -> Transcript {
        let manager = try await readyManager()
        let samples = Self.floatSamples(pcm)
        guard !samples.isEmpty else { return Transcript(text: "") }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state)
        return Transcript(text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                          words: Self.words(from: result.tokenTimings))
    }

    /// FluidAudio's token timings as words; nil if it gave none. A word's span
    /// leaves out its punctuation tokens (a sentence's full stop is timed in the
    /// silence after it, up to a second past the last syllable).
    static func words(from timings: [TokenTiming]?) -> [TranscribedWord]? {
        let timings = timings ?? []
        let words = buildWordTimings(from: timings)
        guard !words.isEmpty else { return nil }
        let spoken = buildWordTimings(from: timings.filter { $0.token.contains(where: { $0.isLetter || $0.isNumber }) })
        let spans = spoken.count == words.count ? spoken : words
        return zip(words, spans).map { word, span in
            TranscribedWord(word: word.word, startMs: Int((span.startTime * 1000).rounded()),
                            endMs: Int((span.endTime * 1000).rounded()))
        }
    }

    private func readyManager() async throws -> AsrManager {
        if let manager { return manager }
        let load = Task { try await self.load() }
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Result<AsrManager, Error>?, Never>) in
            let once = Once(continuation)
            Task {
                do { once.resume(.success(try await load.value)) }
                catch { once.resume(.failure(error)) }
            }
            Task { try? await Task.sleep(for: Self.loadWait); once.resume(nil) }
        }
        guard let outcome else { throw EngineError.stillLoading }
        return try outcome.get()
    }

    /// Little-endian PCM16 to [-1, 1] floats.
    static func floatSamples(_ pcm: Data) -> [Float] {
        let count = pcm.count / 2
        return pcm.withUnsafeBytes { raw in
            (0 ..< count).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32_768 }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result<AsrManager, Error>?, Never>?
        init(_ continuation: CheckedContinuation<Result<AsrManager, Error>?, Never>) { self.continuation = continuation }
        func resume(_ value: Result<AsrManager, Error>?) {
            lock.withLock { () -> CheckedContinuation<Result<AsrManager, Error>?, Never>? in
                defer { continuation = nil }
                return continuation
            }?.resume(returning: value)
        }
    }
}
