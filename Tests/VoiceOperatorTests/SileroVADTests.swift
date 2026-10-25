import XCTest
@testable import VoiceOperator

/// The real model, through the same streaming wrapper the listener uses.
/// "Control." is `say -v Samantha` at 16 kHz (Fixtures/); the noise is seeded.
/// Ported from Spaceterm's `speech-detector.test.ts`, same signals and bounds.
final class SileroVADTests: XCTestCase {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let modelURL = repo.appendingPathComponent("Resources/models/silero_vad_16k_op15.onnx")
    private static let word: [Int16] = {
        let url = repo.appendingPathComponent("Tests/VoiceOperatorTests/Fixtures/control-16k-s16le.pcm")
        let data = try! Data(contentsOf: url)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }()

    private var vad: SileroVAD!
    private var seed: Int64 = 11

    override func setUpWithError() throws {
        vad = try SileroVAD(modelURL: Self.modelURL)
        seed = 11
    }

    /// The Lehmer generator the TypeScript used, so the noise is the same noise.
    private func random() -> Double {
        seed = (seed * 16807) % 2147483647
        return Double(seed) / 2147483647 * 2 - 1
    }

    private func signal(_ seconds: Int, _ f: (Int) -> Double) -> [Int16] {
        // Math.round: halves go up.
        (0..<(seconds * 16_000)).map { Int16((f($0) + 0.5).rounded(.down)) }
    }

    private func whiteNoise(_ amplitude: Double) -> [Int16] { signal(3) { _ in random() * amplitude } }

    /// Three notes of a chord, swelling twice a second: music to a voice detector.
    private func music() -> [Int16] {
        signal(3) { i in
            let i = Double(i)
            return 4800 * (sin(2 * .pi * 261.6 * i / 16_000) + sin(2 * .pi * 329.6 * i / 16_000) + sin(2 * .pi * 392 * i / 16_000))
                * (0.6 + 0.4 * sin(2 * .pi * 2 * i / 16_000))
        }
    }

    /// The word a second into `background`.
    private func over(_ background: [Int16]) -> [Int16] {
        var out = background
        for (i, s) in Self.word.enumerated() {
            out[16_000 + i] = Int16(max(-32768, min(32767, Int(out[16_000 + i]) + Int(s))))
        }
        return out
    }

    /// How many 32 ms frames it hears as speech.
    private func speechFrames(_ audio: [Int16]) throws -> Int {
        vad.reset()
        var count = 0
        var i = 0
        while i + 512 <= audio.count {
            if try vad.score(Array(audio[i..<(i + 512)])) >= 0.5 { count += 1 }
            i += 512
        }
        return count
    }

    func testHearsNoSpeechInLoudNoiseOrMusicHoweverLoud() throws {
        XCTAssertEqual(try speechFrames(whiteNoise(200)), 0)
        XCTAssertEqual(try speechFrames(whiteNoise(6000)), 0)
        XCTAssertEqual(try speechFrames(music()), 0)
    }

    func testHearsTheWordAboutItsLengthOverNoiseAndMusic() throws {
        let wordFrames = (Double(Self.word.count) / 512).rounded()
        for audio in [over(whiteNoise(200)), over(whiteNoise(3000)), over(music())] {
            let frames = Double(try speechFrames(audio))
            XCTAssertGreaterThan(frames, wordFrames * 0.5)
            XCTAssertLessThan(frames, wordFrames * 1.5)
        }
    }

    func testRefusesAFrameOfTheWrongLength() {
        XCTAssertThrowsError(try vad.score([Int16](repeating: 0, count: 480)))
    }
}
