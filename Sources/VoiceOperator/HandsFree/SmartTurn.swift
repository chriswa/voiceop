import Accelerate
import CryptoKit
import Foundation
import OnnxRuntimeBindings

/// Whisper's log-mel spectrogram, as Smart Turn was trained on it: 25 ms frames
/// every 10 ms, 80 mel bands to 8 kHz, over an eight-second window.
enum WhisperFeatures {
    static let sampleRate = 16_000
    /// The model hears the last eight seconds; shorter turns are padded at the front.
    static let windowSeconds = 8
    static let window = windowSeconds * sampleRate
    static let nFFT = 400
    static let hop = 160
    static let nMels = 80
    static let nFreqs = nFFT / 2 + 1
    /// 800: the STFT's 801st frame is dropped, as Whisper drops it.
    static let frames = window / hop

    /// The last eight seconds of `audio`, zero-padded at the front — as Smart Turn's reference does.
    static func lastWindow(_ audio: [Float]) -> [Float] {
        if audio.count >= window { return Array(audio.suffix(window)) }
        return [Float](repeating: 0, count: window - audio.count) + audio
    }

    /// Whisper's input features for an eight-second window, as transformers'
    /// `WhisperFeatureExtractor(chunk_length=8)` computes them with
    /// `do_normalize=True`: the waveform scaled to zero mean and unit variance,
    /// a centred STFT with reflect padding, the power spectrum through the mel
    /// filters, log10, the last frame dropped, floored at 8 below the peak, and
    /// mapped by (x + 4) / 4. Returns `[mel][frame]`, 80 × 800, row-major.
    ///
    /// The DFT is the plain one — 400 points has no factorisation vDSP's FFTs
    /// take — but done as matrix products (frames × cos/sin tables, then power ×
    /// mel filters) through Accelerate, in double precision as the reference
    /// is. Same arithmetic as Spaceterm's loop, a fraction of the time.
    static func features(_ window8s: [Float]) -> [Float] {
        precondition(window8s.count == window, "expected \(window) samples, got \(window8s.count)")
        let t = Tables.shared

        // Zero mean, unit variance, over the whole window, padding included.
        var mean = 0.0
        for x in window8s { mean += Double(x) }
        mean /= Double(window)
        var variance = 0.0
        for x in window8s { let d = Double(x) - mean; variance += d * d }
        variance /= Double(window)
        let scale = 1 / (variance + 1e-7).squareRoot()

        // Reflect-padded by half a frame either side, so frame t is centred on sample t × hop.
        let pad = nFFT / 2
        var padded = [Double](repeating: 0, count: window + 2 * pad)
        for i in padded.indices {
            var j = i - pad
            if j < 0 { j = -j } else if j >= window { j = 2 * (window - 1) - j }
            padded[i] = (Double(window8s[j]) - mean) * scale
        }

        // Every frame, windowed: [frame][n].
        var framed = [Double](repeating: 0, count: frames * nFFT)
        padded.withUnsafeBufferPointer { src in
            t.window.withUnsafeBufferPointer { w in
                framed.withUnsafeMutableBufferPointer { dst in
                    for f in 0..<frames {
                        vDSP_vmulD(src.baseAddress! + f * hop, 1, w.baseAddress!, 1,
                                   dst.baseAddress! + f * nFFT, 1, vDSP_Length(nFFT))
                    }
                }
            }
        }

        // Real and imaginary parts, [frame][k]; the sign of the imaginary part
        // does not survive squaring, so sin is used as is.
        var re = [Double](repeating: 0, count: frames * nFreqs)
        var im = [Double](repeating: 0, count: frames * nFreqs)
        vDSP_mmulD(framed, 1, t.cos, 1, &re, 1, vDSP_Length(frames), vDSP_Length(nFreqs), vDSP_Length(nFFT))
        vDSP_mmulD(framed, 1, t.sin, 1, &im, 1, vDSP_Length(frames), vDSP_Length(nFreqs), vDSP_Length(nFFT))
        var power = [Double](repeating: 0, count: frames * nFreqs)
        vDSP_vmmaD(re, 1, re, 1, im, 1, im, 1, &power, 1, vDSP_Length(power.count))

        // Through the mel filters: [frame][mel].
        var mel = [Double](repeating: 0, count: frames * nMels)
        vDSP_mmulD(power, 1, t.filtersT, 1, &mel, 1, vDSP_Length(frames), vDSP_Length(nMels), vDSP_Length(nFreqs))

        var peak = -Double.infinity
        for i in mel.indices {
            let v = log10(max(1e-10, mel[i]))
            mel[i] = v
            if v > peak { peak = v }
        }

        let floor = peak - 8
        var out = [Float](repeating: 0, count: nMels * frames)
        for f in 0..<frames {
            for m in 0..<nMels {
                out[m * frames + f] = Float((max(mel[f * nMels + m], floor) + 4) / 4)
            }
        }
        return out
    }

    /// The window, the DFT's cos/sin tables (`[n][k]`, so a frame row times them
    /// is its spectrum) and the mel filters transposed (`[k][mel]`). Built once.
    private struct Tables: Sendable {
        static let shared = Tables()

        let window: [Double]
        let cos: [Double]
        let sin: [Double]
        let filtersT: [Double]

        private init() {
            // A periodic Hann window, as `window_function(400, "hann")`.
            window = (0..<nFFT).map { 0.5 - 0.5 * Foundation.cos(2 * Double.pi * Double($0) / Double(nFFT)) }
            var cos = [Double](repeating: 0, count: nFFT * nFreqs)
            var sin = [Double](repeating: 0, count: nFFT * nFreqs)
            for n in 0..<nFFT {
                for k in 0..<nFreqs {
                    let angle = 2 * Double.pi * Double((k * n) % nFFT) / Double(nFFT)
                    cos[n * nFreqs + k] = Foundation.cos(angle)
                    sin[n * nFreqs + k] = Foundation.sin(angle)
                }
            }
            self.cos = cos
            self.sin = sin
            let filters = WhisperFeatures.melFilters()
            var filtersT = [Double](repeating: 0, count: nFreqs * nMels)
            for m in 0..<nMels { for k in 0..<nFreqs { filtersT[k * nMels + m] = filters[m][k] } }
            self.filtersT = filtersT
        }
    }

    /// Slaney's mel scale, as librosa and transformers' `mel_filter_bank` use it.
    private static func hertzToMel(_ hz: Double) -> Double {
        let minLogHertz = 1000.0, minLogMel = 15.0, logstep = 27 / log(6.4)
        return hz < minLogHertz ? 3 * hz / 200 : minLogMel + log(hz / minLogHertz) * logstep
    }

    private static func melToHertz(_ mel: Double) -> Double {
        let minLogHertz = 1000.0, minLogMel = 15.0, logstep = log(6.4) / 27
        return mel < minLogMel ? 200 * mel / 3 : minLogHertz * exp(logstep * (mel - minLogMel))
    }

    /// Triangular filters, Slaney-normalised: `[mel][frequency bin]`.
    private static func melFilters() -> [[Double]] {
        let nyquist = Double(sampleRate / 2)
        let fftFreqs = (0..<nFreqs).map { Double($0) * nyquist / Double(nFreqs - 1) }
        let minMel = hertzToMel(0), maxMel = hertzToMel(nyquist)
        let filterFreqs = (0..<(nMels + 2)).map { melToHertz(minMel + (maxMel - minMel) * Double($0) / Double(nMels + 1)) }
        return (0..<nMels).map { m in
            let lower = filterFreqs[m], centre = filterFreqs[m + 1], upper = filterFreqs[m + 2]
            let enorm = 2 / (upper - lower)
            return fftFreqs.map { f in
                let down = (f - lower) / (centre - lower)
                let up = (upper - f) / (upper - centre)
                return max(0, min(down, up)) * enorm
            }
        }
    }
}

/// The model, loaded: features in, probability the turn is complete out.
protocol TurnModel: Sendable {
    func run(_ features: [Float]) throws -> Float
}

/// Where the model comes from: Hugging Face, at a pinned revision, checked by hash.
enum SmartTurnModel {
    static let file = "smart-turn-v3.2-cpu.onnx"
    static let url = URL(string: "https://huggingface.co/pipecat-ai/smart-turn-v3/resolve/f766f81d3cfdf7737ac64aad813d91bbfd56bf93/smart-turn-v3.2-cpu.onnx")!
    static let sha256 = "2bb026316b14a660486a75b1733cd3fbab8c2fd0314dc9af7be49f8cca967e4f"

    enum Failure: Error, CustomStringConvertible {
        case http(Int)
        case hash(String)
        case noOutput
        var description: String {
            switch self {
            case .http(let status): return "fetching the turn model failed: HTTP \(status)"
            case .hash(let hash): return "the turn model's hash is \(hash), not the pinned one"
            case .noOutput: return "the turn model returned nothing"
            }
        }
    }

    /// Fetch the model into `directory` once; afterwards, just its path. Written
    /// beside itself and renamed into place, so a fetch cut short is never
    /// mistaken for the model. No incognito gate: it carries nothing of the
    /// user's, like Parakeet's weights.
    static func ensure(in directory: URL, log: @Sendable (String) -> Void) async throws -> URL {
        let file = directory.appendingPathComponent(Self.file)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        log("fetching \(Self.file) (8 MB) from Hugging Face")
        let (bytes, response) = try await URLSession(configuration: .ephemeral).data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.http(status) }
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard hash == sha256 else { throw Failure.hash(hash) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent(Self.file + ".partial")
        try bytes.write(to: partial)
        try FileManager.default.moveItem(at: partial, to: file)
        return file
    }

    /// The real thing: ONNX Runtime on the CPU, one thread, as the reference runs it.
    ///
    /// Spaceterm also set sequential execution with one inter-op thread, and
    /// turned off the CPU memory arena and memory patterns (about 13 MB of the
    /// ~130 MB the runtime costs). Sequential is ORT's default, which makes the
    /// inter-op count moot; the arena and pattern switches are not exposed by
    /// the Objective-C bindings, so they stay at their defaults here.
    static func load(from file: URL) throws -> any TurnModel {
        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        try options.setGraphOptimizationLevel(.all)
        let session = try ORTSession(env: env, modelPath: file.path, sessionOptions: options)
        let input = try session.inputNames()[0]
        let output = try session.outputNames()[0]
        return OnnxTurnModel(env: env, session: session, input: input, output: output)
    }
}

/// ORT sessions may be run from any thread; `TurnDetector` runs this one from
/// its own actor, one call at a time.
private final class OnnxTurnModel: TurnModel, @unchecked Sendable {
    private let env: ORTEnv
    private let session: ORTSession
    private let input: String
    private let output: String

    init(env: ORTEnv, session: ORTSession, input: String, output: String) {
        self.env = env
        self.session = session
        self.input = input
        self.output = output
    }

    func run(_ features: [Float]) throws -> Float {
        let data = features.withUnsafeBufferPointer {
            NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<Float>.size)
        }
        let shape: [NSNumber] = [1, NSNumber(value: WhisperFeatures.nMels), NSNumber(value: WhisperFeatures.frames)]
        let value = try ORTValue(tensorData: data, elementType: .float, shape: shape)
        let outputs = try session.run(withInputs: [input: value], outputNames: [output], runOptions: nil)
        guard let result = outputs[output] else { throw SmartTurnModel.Failure.noOutput }
        let bytes = try result.tensorData() as Data
        guard let p = bytes.withUnsafeBytes({ $0.bindMemory(to: Float.self).first }) else {
            throw SmartTurnModel.Failure.noOutput
        }
        return p
    }
}

/// Has the speaker finished their turn? Smart Turn v3.2 (pipecat-ai/smart-turn,
/// BSD-2): an 8 MB int8 model — Whisper Tiny's encoder and a linear classifier —
/// that listens to the last eight seconds of a turn and judges, from grammar,
/// intonation and pace together, whether it sounds finished. "Tell Kevin to run
/// the tests and" is not; "Tell Kevin to run the tests." is.
///
/// Hands-free mode asks at each pause in a dictation, so a finished thought ends
/// it quickly and a thinking pause does not.
///
/// Ported from Spaceterm's `turn-detector.ts`. Whisper's feature extraction is
/// ported below and checked number for number against the Python reference
/// (`SmartTurnTests`). The model is fetched once from Hugging Face, at a pinned
/// revision, checked by hash, and kept in Application Support's `models`; it is
/// loaded when the first hands-free dictation starts and stays loaded.
///
/// The model is loaded on first use and kept. A model that will not load says
/// so once in the log and answers nothing afterwards, so hands-free mode falls
/// back on silence alone.
actor TurnDetector {
    private let load: @Sendable () async throws -> any TurnModel
    private let log: @Sendable (String) -> Void
    private var loading: Task<(any TurnModel)?, Never>?

    init(modelDirectory: URL = HistoryStore.supportDir.appendingPathComponent("models", isDirectory: true),
         log: @escaping @Sendable (String) -> Void = { Log.log($0) }) {
        self.init(load: {
            try SmartTurnModel.load(from: try await SmartTurnModel.ensure(in: modelDirectory, log: log))
        }, log: log)
    }

    /// `load` is the test seam: the default fetches and loads the real model.
    init(load: @escaping @Sendable () async throws -> any TurnModel, log: @escaping @Sendable (String) -> Void) {
        self.load = load
        self.log = log
    }

    /// Load the model now, ahead of the first question — a dictation that will ask has begun.
    func warm() {
        _ = model()
    }

    /// Probability, 0..1, that 16 kHz `audio` — the turn so far, ending now — is
    /// finished. Nil without a model, or if the model fails on this audio.
    func probability(_ audio: [Float]) async -> Double? {
        guard let model = await model().value else { return nil }
        do {
            return Double(try model.run(WhisperFeatures.features(WhisperFeatures.lastWindow(audio))))
        } catch {
            log("turn model failed: \(error)")
            return nil
        }
    }

    private func model() -> Task<(any TurnModel)?, Never> {
        if let loading { return loading }
        let (load, log) = (self.load, self.log)
        let task = Task<(any TurnModel)?, Never> {
            do {
                let model = try await load()
                log("turn model loaded")
                return model
            } catch {
                log("turn model unavailable: \(error)")
                return nil
            }
        }
        loading = task
        return task
    }
}
