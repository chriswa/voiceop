import XCTest
@testable import VoiceOperator

/// turn-1-mini on the real graph, when the app has fetched it (it is not in
/// the repository). Never touches the network.
final class TurnOneMiniTests: XCTestCase {
    private func model() throws -> TurnOneMini.Model {
        let file = HistoryStore.supportDir.appendingPathComponent("models").appendingPathComponent(TurnOneMini.file)
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("turn-1-mini not fetched yet") }
        return try TurnOneMini.Model(file: file)
    }

    private func speechThenSilence() throws -> [Int16] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/control-16k-s16le.pcm")
        let speech = HandsFreeService.samples(try Data(contentsOf: url))
        return [Int16](repeating: 0, count: 8000) + speech + [Int16](repeating: 0, count: 24_000)
    }

    func testAnswersEvery20msAndRisesOnceTheSpeechEnds() throws {
        let audio = try speechThenSilence()
        let probs = try model().stream().push(audio)
        XCTAssertEqual(probs.count, audio.count / TurnOneMini.step * 8)
        XCTAssertTrue(probs.allSatisfy { $0 >= 0 && $0 <= 1 })
        let speechEnd = (8000 + 19_682 / 2) / 320
        let during = probs[(speechEnd - 20)..<speechEnd].max() ?? 1
        let after = probs[(speechEnd + 25)...].max() ?? 0
        XCTAssertGreaterThan(after, during, "more sure of the end in the silence after the word than during it")
    }

    func testChunkingDoesNotChangeTheAnswers() throws {
        let audio = try speechThenSilence()
        let m = try model()
        let whole = try m.stream().push(audio)
        let stream = m.stream()
        var pieces: [Float] = []
        var i = 0
        while i < audio.count {
            pieces += try stream.push(Array(audio[i..<min(i + 1000, audio.count)]))
            i += 1000
        }
        XCTAssertEqual(pieces.count, whole.count)
        XCTAssertEqual(zip(pieces, whole).map { abs($0 - $1) }.max() ?? 0, 0, accuracy: 1e-5)
    }
}
