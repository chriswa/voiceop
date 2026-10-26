import CryptoKit
import Foundation
import OnnxRuntimeBindings

/// Has the speaker finished their turn? turn-1-mini (p99lab, Apache-2.0 —
/// "turn-1-mini by p99lab", https://huggingface.co/p99lab/turn-1-mini). A
/// 5.3M-parameter streaming model: fed every 160 ms of audio, it answers with
/// the probability that the turn has ended for each 20 ms in it, carrying its
/// own state (1.2 s of attention) from step to step. It answers all the time,
/// which is what its gauge on the hands-free button shows — the latest answer,
/// and the highest since the pause began.
///
/// It ends hands-free dictations (`HandsFreeEngine.checkMiniEnding`); every
/// pause's line in the decision record says what it made of it.
///
/// The graph (`turn-1-mini.step.int8.onnx`, 6 MB: the benchmarked 8-bit
/// weights, float arithmetic) carries the 4 kHz low-pass and the log-mel it
/// needs inside it, so it takes raw 16 kHz audio. Fetched once at a pinned
/// revision, checked by hash, kept in Application Support's `models`.
enum TurnOneMini {
    static let file = "turn-1-mini.step.int8.onnx"
    static let url = URL(string: "https://huggingface.co/p99lab/turn-1-mini/resolve/076c86d1744a231d3a4cce31f3bbbd1211b4c281/onnx/turn-1-mini.step.int8.onnx")!
    static let sha256 = "aab623c3df7a494710a9bf650df29b292b76ee2fe0e85b616a57c871d0b993b4"
    /// 160 ms of 16 kHz audio: one step.
    static let step = 2560
    /// The answer that ends a dictation (after `HandsFreeEngine.miniHoldMs`), and
    /// the line on the gauge. Its scores are not calibrated: the model card's
    /// operating points are 0.06 (300 ms), 0.16 (600 ms) and 0.17 (5% false
    /// cut-offs). 0.5 for now, a trial at the user's asking (October 25), to see
    /// how it does; 0.17 was the model card's choice.
    static let threshold = 0.5

    /// The state the graph carries from step to step, and its fixed shapes.
    static let states: [(name: String, shape: [Int])] = [
        ("audio", [1, 304]), ("conv1", [1, 80, 2]), ("conv2", [1, 256, 2]),
        ("k", [6, 4, 60, 64]), ("v", [6, 4, 60, 64]), ("k_valid", [60]), ("h6", [60, 256]),
    ]

    enum Failure: Error, CustomStringConvertible {
        case http(Int), hash(String), noOutput(String)
        var description: String {
            switch self {
            case .http(let status): return "fetching turn-1-mini failed: HTTP \(status)"
            case .hash(let hash): return "turn-1-mini's hash is \(hash), not the pinned one"
            case .noOutput(let name): return "turn-1-mini returned no \(name)"
            }
        }
    }

    /// Fetch the graph into `directory` once; afterwards, just its path.
    static func ensure(in directory: URL, log: @Sendable (String) -> Void) async throws -> URL {
        let target = directory.appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        log("fetching \(file) (6 MB) from Hugging Face")
        let (bytes, response) = try await URLSession(configuration: .ephemeral).data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.http(status) }
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard hash == sha256 else { throw Failure.hash(hash) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent(file + ".partial")
        try bytes.write(to: partial)
        try FileManager.default.moveItem(at: partial, to: target)
        return target
    }

    /// The graph, loaded: one session, shared by every stream.
    final class Model: @unchecked Sendable {
        private let env: ORTEnv
        fileprivate let session: ORTSession
        fileprivate let lock = NSLock()

        init(file: URL) throws {
            env = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(1)
            try options.setGraphOptimizationLevel(.all)
            session = try ORTSession(env: env, modelPath: file.path, sessionOptions: options)
        }

        /// A new stream: state at zero, as at the start of a turn.
        func stream() -> Stream { Stream(model: self) }
    }

    /// One turn's stream: feed it audio in order, any length; it answers for
    /// each finished 20 ms frame. Used from one queue at a time.
    final class Stream {
        private let model: Model
        private var state: [String: Data]
        private var pending: [Float] = []

        fileprivate init(model: Model) {
            self.model = model
            state = Dictionary(uniqueKeysWithValues: TurnOneMini.states.map {
                ("state_\($0.name)", Data(count: $0.shape.reduce(1, *) * MemoryLayout<Float>.size))
            })
        }

        /// 16 kHz s16le samples → P(end of turn) per finished 20 ms frame, oldest first.
        func push(_ pcm: [Int16]) throws -> [Float] {
            pending.append(contentsOf: pcm.map { Float($0) / 32768 })
            var probs: [Float] = []
            while pending.count >= TurnOneMini.step {
                probs += try run(Array(pending.prefix(TurnOneMini.step)))
                pending.removeFirst(TurnOneMini.step)
            }
            return probs
        }

        private func run(_ audio: [Float]) throws -> [Float] {
            var inputs: [String: ORTValue] = [:]
            inputs["audio"] = try Self.tensor(audio.withUnsafeBufferPointer { Data(buffer: $0) }, [1, TurnOneMini.step])
            for (name, shape) in TurnOneMini.states {
                inputs["state_\(name)"] = try Self.tensor(state["state_\(name)"]!, shape)
            }
            let outputNames = Set(["probs"] + TurnOneMini.states.map { "new_state_\($0.name)" })
            let outputs = try model.lock.withLock {
                try model.session.run(withInputs: inputs, outputNames: outputNames, runOptions: nil)
            }
            for (name, _) in TurnOneMini.states {
                guard let value = outputs["new_state_\(name)"] else { throw Failure.noOutput("new_state_\(name)") }
                state["state_\(name)"] = try value.tensorData() as Data
            }
            guard let probs = outputs["probs"] else { throw Failure.noOutput("probs") }
            let bytes = try probs.tensorData() as Data
            return bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }

        private static func tensor(_ data: Data, _ shape: [Int]) throws -> ORTValue {
            try ORTValue(tensorData: NSMutableData(data: data), elementType: .float, shape: shape.map { NSNumber(value: $0) })
        }
    }

    /// The graph, fetched and loaded on first use and kept; nil once it has failed (logged once).
    actor Loader {
        private let directory: URL
        private let log: @Sendable (String) -> Void
        private var loading: Task<Model?, Never>?

        init(directory: URL = HistoryStore.supportDir.appendingPathComponent("models", isDirectory: true),
             log: @escaping @Sendable (String) -> Void = { Log.log($0) }) {
            self.directory = directory
            self.log = log
        }

        func model() async -> Model? {
            if let loading { return await loading.value }
            let (directory, log) = (self.directory, self.log)
            let task = Task<Model?, Never> {
                do {
                    let model = try Model(file: try await TurnOneMini.ensure(in: directory, log: log))
                    log("turn-1-mini loaded")
                    return model
                } catch {
                    log("turn-1-mini unavailable: \(error)")
                    return nil
                }
            }
            loading = task
            return await task.value
        }
    }
}

extension TurnOneMini.Stream: HandsFreeEngine.ContinuousTurn {}
