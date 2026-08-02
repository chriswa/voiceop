import XCTest
@testable import VoiceOperator

final class ConfigTests: XCTestCase {
    override func tearDown() {
        Config.override = nil
        Config.resetCache()
        super.tearDown()
    }

    func testTTSBaseURLFallsBackToLocalhost() {
        Config.override = Config.File()
        Config.resetCache()
        // Env may be set in the developer shell — only assert the config-file
        // branch when the env var is absent.
        if ProcessInfo.processInfo.environment["VOICEOP_KOKORO_URL"] == nil {
            XCTAssertEqual(Config.ttsBaseURL, Config.defaultTTSBaseURL)
        }
        XCTAssertEqual(Config.ttsHeaders, [:])
    }

    func testTTSBaseURLAndHeadersFromConfigFile() {
        // Skip when the env var would win precedence — we can't unset process
        // env from here without affecting other tests.
        guard ProcessInfo.processInfo.environment["VOICEOP_KOKORO_URL"] == nil else { return }
        Config.override = Config.File(tts: .init(
            url: "https://tts.example.com",
            headers: [
                "CF-Access-Client-Id": "id",
                "CF-Access-Client-Secret": "secret",
            ]))
        Config.resetCache()
        XCTAssertEqual(Config.ttsBaseURL, "https://tts.example.com")
        XCTAssertEqual(Config.ttsHeaders["CF-Access-Client-Id"], "id")
        XCTAssertEqual(Config.ttsHeaders["CF-Access-Client-Secret"], "secret")
    }

    func testEndpointJoinsPathWithoutDoubleSlash() {
        Config.override = Config.File(tts: .init(url: "https://tts.example.com/", headers: nil))
        Config.resetCache()
        guard ProcessInfo.processInfo.environment["VOICEOP_KOKORO_URL"] == nil else { return }
        XCTAssertEqual(KokoroSynthesizer.endpoint("synthesize").absoluteString,
                       "https://tts.example.com/synthesize")
        XCTAssertEqual(KokoroSynthesizer.endpoint("voices").absoluteString,
                       "https://tts.example.com/voices")
    }
}

final class KokoroSynthesizerContentTypeTests: XCTestCase {
    func testRequireAudioAcceptsAudioWAV() throws {
        let http = HTTPURLResponse(
            url: URL(string: "https://tts.example.com/synthesize")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "audio/wav"])!
        try KokoroSynthesizer.requireAudioContentType(http)
    }

    func testRequireAudioRejectsHTML() {
        let http = HTTPURLResponse(
            url: URL(string: "https://tts.example.com/synthesize")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        XCTAssertThrowsError(try KokoroSynthesizer.requireAudioContentType(http)) { err in
            guard case SpeakerError.synthesis(let msg) = err else {
                return XCTFail("expected SpeakerError.synthesis, got \(err)")
            }
            XCTAssertTrue(msg.contains("text/html"), msg)
        }
    }

    func testRequireAudioRejectsMissingContentType() {
        let http = HTTPURLResponse(
            url: URL(string: "https://tts.example.com/synthesize")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil)!
        XCTAssertThrowsError(try KokoroSynthesizer.requireAudioContentType(http))
    }
}
