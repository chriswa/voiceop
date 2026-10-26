import XCTest
@testable import VoiceOperator

/// Ported from Spaceterm's `turn-detector.test.ts`. No network: the detector's
/// model is faked, and the features are checked against values from Python.
final class SmartTurnTests: XCTestCase {
    /// 2.5 s of a gliding two-tone "voice" under a swelling envelope, at the end
    /// of an eight-second window — the same formula as the Python that produced
    /// the expected values below (transformers 4.57 `WhisperFeatureExtractor`,
    /// `chunk_length=8`, `do_normalize=True`, the Smart Turn reference's settings).
    private func referenceSignal() -> [Float] {
        (0..<40_000).map { i in
            let t = Double(i) / 16_000
            return Float((0.3 * sin(2 * .pi * (180 + 60 * t) * t) + 0.1 * sin(2 * .pi * 1250 * t)) * sin(.pi * t / 2.5))
        }
    }

    /// (mel, frame, value) from the Python reference.
    private let reference: [(Int, Int, Float)] = [
        (0, 0, -0.165529), (40, 0, -0.165529), (0, 560, 0.211664), (5, 600, 1.710078),
        (10, 650, 1.025412), (20, 700, -0.165529), (39, 720, -0.165529), (50, 750, -0.165529),
        (79, 780, -0.165529), (3, 799, -0.165529), (12, 799, 0.910719), (60, 640, -0.165529),
    ]
    private let referenceMean = -0.07196687161922455

    /// vitest's `toBeCloseTo(x, 4)`: within 0.5e-4.
    private let tolerance = 0.5e-4

    func testFeaturesMatchTransformersWhisperFeatureExtractor() {
        let features = WhisperFeatures.features(WhisperFeatures.lastWindow(referenceSignal()))
        XCTAssertEqual(features.count, 80 * WhisperFeatures.frames)
        for (mel, frame, value) in reference {
            XCTAssertEqual(Double(features[mel * WhisperFeatures.frames + frame]), Double(value), accuracy: tolerance,
                           "mel \(mel), frame \(frame)")
        }
        let mean = features.reduce(0.0) { $0 + Double($1) } / Double(features.count)
        XCTAssertEqual(mean, referenceMean, accuracy: tolerance)
    }

    func testLastWindowPadsAShortTurnAtTheFront() {
        let window = WhisperFeatures.lastWindow([1, 2, 3])
        XCTAssertEqual(window.count, 128_000)
        XCTAssertEqual(Array(window.suffix(3)), [1, 2, 3])
        XCTAssertEqual(window[0], 0)
    }

    func testLastWindowKeepsOnlyTheLastEightSecondsOfALongOne() {
        var long = [Float](repeating: 0, count: 200_000)
        long[long.count - 1] = 0.5
        long[0] = 0.25
        let window = WhisperFeatures.lastWindow(long)
        XCTAssertEqual(window.count, 128_000)
        XCTAssertEqual(window.last, 0.5)
        XCTAssertFalse(window.contains(0.25))
    }

    func testLoadsTheModelOnceAndAsksItAboutTheLastEightSeconds() async {
        let loads = Counter(), seen = Recorder<Int>()
        let model = FakeTurnModel(answer: 0.93) { seen.append($0.count) }
        let detector = TurnDetector(load: { loads.increment(); return model }, log: { _ in })
        let first = await detector.probability(referenceSignal())
        let second = await detector.probability([Float](repeating: 0, count: 16_000))
        XCTAssertEqual(first.map(Float.init), 0.93)
        XCTAssertEqual(second.map(Float.init), 0.93)
        XCTAssertEqual(loads.value, 1)
        XCTAssertEqual(seen.values, [80 * WhisperFeatures.frames, 80 * WhisperFeatures.frames])
    }

    func testWithoutAModelAnswersNothingAndSaysWhyOnce() async {
        let logged = Recorder<String>()
        let detector = TurnDetector(load: { throw Offline() }, log: { logged.append($0) })
        let first = await detector.probability([Float](repeating: 0, count: 16_000))
        let second = await detector.probability([Float](repeating: 0, count: 16_000))
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(logged.values, ["turn model unavailable: offline"])
    }

    func testCanBeLoadedAheadOfTheFirstQuestion() async {
        let loads = Counter()
        let detector = TurnDetector(load: { loads.increment(); return FakeTurnModel(answer: 0.1) }, log: { _ in })
        await detector.warm()
        await detector.warm()
        let p = await detector.probability([Float](repeating: 0, count: 16_000))
        XCTAssertEqual(p.map(Float.init), 0.1)
        XCTAssertEqual(loads.value, 1)
    }

    /// Not a check — how long features plus the real model take per call, when
    /// the model is already in `~/Library/Application Support/VoiceOperator/models`.
    /// Skipped otherwise: tests never fetch it.
    func testRealModelTiming() async throws {
        let dir = HistoryStore.supportDir.appendingPathComponent("models", isDirectory: true)
        let file = dir.appendingPathComponent(SmartTurnModel.file)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: file.path), "Smart Turn model not downloaded")
        let detector = TurnDetector(load: { try SmartTurnModel.load(from: file) }, log: { _ in })
        let audio = referenceSignal()
        _ = await detector.probability(audio)
        let started = Date()
        let runs = 10
        for _ in 0..<runs {
            let p = await detector.probability(audio)
            XCTAssertNotNil(p)
        }
        let featuresStarted = Date()
        for _ in 0..<runs { _ = WhisperFeatures.features(WhisperFeatures.lastWindow(audio)) }
        print(String(format: "smart turn: %.1f ms per probability, %.1f ms of it features",
                     featuresStarted.timeIntervalSince(started) * 1000 / Double(runs),
                     Date().timeIntervalSince(featuresStarted) * 1000 / Double(runs)))
    }
}

private struct Offline: Error, CustomStringConvertible {
    var description: String { "offline" }
}

private struct FakeTurnModel: TurnModel {
    let answer: Float
    var onRun: @Sendable ([Float]) -> Void = { _ in }
    func run(_ features: [Float]) throws -> Float { onRun(features); return answer }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.withLock { items.append(item) } }
    var values: [T] { lock.withLock { items } }
}
