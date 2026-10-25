import Foundation
import OnnxRuntimeBindings

/// Is someone talking in this frame? The probability, per 32 ms frame, that
/// hands-free mode's listener works from (`Listener`).
///
/// Silero VAD (snakers4/silero-vad, MIT; `Resources/models/silero_vad_16k_op15.onnx`,
/// 1.3 MB) is a small voice-activity model trained to tell speech from
/// everything else — so loud white noise and music score as not-speech, and a
/// word said over them scores as speech (checked: `SileroVADTests`). It runs
/// on ONNX Runtime on the CPU, well under a millisecond a frame; nothing it
/// hears leaves this Mac. Ported from Spaceterm's `speech-detector.ts`, where it
/// ran on the phone.
///
/// The streaming wrapper is Silero's own `OnnxWrapper`'s: each frame goes in
/// behind the last 64 samples of the one before, with the recurrent state the
/// model handed back. That carried state is why frames must arrive in order,
/// and why a new stream after a gap calls `reset()`.
final class SileroVAD: FrameScorer {
    let name = "silero"

    static let frameLength = 512
    private static let contextLength = 64
    /// `[2, 1, 128]`: the model's LSTM state, in and out.
    private static let stateLength = 2 * 1 * 128

    private let env: ORTEnv
    private let session: ORTSession
    /// The sample rate is an input of the graph; it never changes, so it is built once.
    private let sampleRate: ORTValue
    private var state = [Float](repeating: 0, count: SileroVAD.stateLength)
    private var context = [Float](repeating: 0, count: SileroVAD.contextLength)

    enum SileroError: Error, CustomStringConvertible {
        case wrongFrameLength(Int)
        case missingOutput(String)
        var description: String {
            switch self {
            case .wrongFrameLength(let n): return "Silero takes \(SileroVAD.frameLength) samples, got \(n)"
            case .missingOutput(let name): return "Silero returned no \(name)"
            }
        }
    }

    init(modelURL: URL) throws {
        env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        // One thread: one frame is tiny, and the work is a steady trickle every
        // 32 ms that should not wake a pool of threads to do it.
        try options.setIntraOpNumThreads(1)
        session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
        var rate: Int64 = 16_000
        sampleRate = try ORTValue(tensorData: NSMutableData(bytes: &rate, length: MemoryLayout<Int64>.size),
                                  elementType: .int64, shape: [])
    }

    /// The model as `make-app.sh` bundles it, in the app's Contents/Resources.
    static func bundledModelURL() -> URL? {
        Bundle.main.url(forResource: "silero_vad_16k_op15", withExtension: "onnx")
    }

    /// Probability, 0..1, that this 512-sample 16 kHz frame is speech.
    func score(_ frame: [Int16]) throws -> Float {
        guard frame.count == Self.frameLength else { throw SileroError.wrongFrameLength(frame.count) }
        var input = context
        input.reserveCapacity(Self.contextLength + Self.frameLength)
        for sample in frame { input.append(Float(sample) / 32768) }

        let inputValue = try Self.tensor(input, shape: [1, NSNumber(value: input.count)])
        let stateValue = try Self.tensor(state, shape: [2, 1, 128])
        let outputs = try session.run(withInputs: ["input": inputValue, "state": stateValue, "sr": sampleRate],
                                      outputNames: ["output", "stateN"], runOptions: nil)
        guard let output = outputs["output"] else { throw SileroError.missingOutput("output") }
        guard let stateN = outputs["stateN"] else { throw SileroError.missingOutput("stateN") }
        state = try Self.floats(stateN)
        context = Array(input.suffix(Self.contextLength))
        guard let p = try Self.floats(output).first else { throw SileroError.missingOutput("output") }
        return p
    }

    /// Forget the audio so far: a new stream, after a gap.
    func reset() {
        state = [Float](repeating: 0, count: Self.stateLength)
        context = [Float](repeating: 0, count: Self.contextLength)
    }

    private static func tensor(_ values: [Float], shape: [NSNumber]) throws -> ORTValue {
        let data = values.withUnsafeBufferPointer { NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<Float>.size) }
        return try ORTValue(tensorData: data, elementType: .float, shape: shape)
    }

    private static func floats(_ value: ORTValue) throws -> [Float] {
        let data = try value.tensorData() as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
