import FluidAudio
import Foundation

/// NVIDIA Parakeet TDT v3, on this Mac (CoreML on the Neural Engine, via
/// FluidAudio). Raw recognition with its own punctuation and casing — no clean-up
/// pass and no custom vocabulary, so names like "kubectl" come out as heard.
///
/// It is fast enough (about 190× real time on an M4 Pro) that streaming would buy
/// nothing: a session just collects the audio while the key is held and
/// transcribes all of it at key-up. Failures are reported as failures — there is
/// deliberately no fallback to another provider, which would hide how Parakeet
/// actually behaves.
struct ParakeetProvider: TranscriptionProvider {
    let id = TranscriptionProviderID.parakeet
    let fallbackLabel = "Parakeet on the recorded clip"
    /// The session only buffers audio; a failed commit is the model failing,
    /// and running it again on the same audio would fail the same way.
    let retriesAfterLiveFailure = false

    func prewarm() async -> String? {
        do {
            _ = try await ParakeetEngine.shared.load()
            return nil
        } catch {
            return TranscriberError.userMessage(for: error)
        }
    }

    func openSession(target: DictationTarget, trace: DictationTrace?) async throws -> any TranscriptionSession {
        // Start (or join) the model load now, so it overlaps the user speaking.
        Task { _ = try? await ParakeetEngine.shared.load() }
        return ParakeetSession(trace: trace)
    }

    func transcribe(wavData: Data) async throws -> String {
        try await ParakeetEngine.shared.transcribe(pcm: WAVFile.parse(wavData).samples)
    }

    func transcribeAfterLiveFailure(wavData: Data) async throws -> String {
        try await transcribe(wavData: wavData)
    }
}

/// A Parakeet dictation: holds the audio until the key comes up.
actor ParakeetSession: TranscriptionSession {
    private var pcm = Data()
    private let trace: DictationTrace?

    init(trace: DictationTrace?) { self.trace = trace }

    func send(pcm: Data) { self.pcm.append(pcm) }

    func commit(pcm: Data) async throws -> String {
        self.pcm.append(pcm)
        trace?.mark("commit")
        let text = try await ParakeetEngine.shared.transcribe(pcm: self.pcm)
        trace?.mark("result")
        trace?.note(String(format: "%.1fs audio on device", Double(self.pcm.count / 2) / 16_000))
        return text
    }

    func cancel() { pcm = Data() }
}

/// The loaded model, shared by every Parakeet session. Loading means a download
/// of about 470 MB from Hugging Face the first time (cached under Application
/// Support/FluidAudio), a CoreML compile of about 30 s the first time each new
/// build loads it, and 0.2 s after that — so it happens once and is kept for the
/// life of the process.
actor ParakeetEngine {
    static let shared = ParakeetEngine()

    static let version = AsrModelVersion.v3

    /// How long a dictation waits for a load that is still under way — the app
    /// was just launched, or Parakeet was just chosen. Sized for the CoreML
    /// compile a freshly built binary pays once (about 30 s measured on this Mac;
    /// later launches of the same build load in 0.2 s). A first download takes far
    /// longer, and the dictation fails rather than hang.
    static let loadWait: Duration = .seconds(45)

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

    /// Transcribe 16 kHz mono PCM16. Waits up to `loadWait` for a load in
    /// progress, then gives up with `stillLoading`.
    func transcribe(pcm: Data) async throws -> String {
        let manager = try await readyManager()
        let samples = Self.floatSamples(pcm)
        guard !samples.isEmpty else { return "" }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
