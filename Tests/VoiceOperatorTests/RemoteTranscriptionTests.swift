import Foundation
import XCTest
@testable import VoiceOperator

final class RemoteTranscriptionTests: XCTestCase {
    // MARK: - Routing

    func testRoutes() {
        XCTAssertEqual(TranscriptionRoute(method: "POST", path: "/v1/transcriptions"), .create)
        XCTAssertEqual(TranscriptionRoute(method: "POST", path: "/v1/transcriptions/abc/audio"), .audio("abc"))
        XCTAssertEqual(TranscriptionRoute(method: "POST", path: "/v1/transcriptions/abc/finish"), .finish("abc"))
        XCTAssertEqual(TranscriptionRoute(method: "DELETE", path: "/v1/transcriptions/abc"), .cancel("abc"))
        XCTAssertEqual(TranscriptionRoute(method: "GET", path: "/v1/transcriptions"), .methodNotAllowed)
        XCTAssertEqual(TranscriptionRoute(method: "GET", path: "/v1/transcriptions/abc/finish"), .methodNotAllowed)
        XCTAssertEqual(TranscriptionRoute(method: "POST", path: "/v1/transcriptions/abc"), .methodNotAllowed)
        XCTAssertNil(TranscriptionRoute(method: "POST", path: "/v1/speech"))
        XCTAssertNil(TranscriptionRoute(method: "POST", path: "/v1/transcriptions/abc/other"))
        XCTAssertNil(TranscriptionRoute(method: "POST", path: "/v1/transcriptions//audio"))
    }

    func testCreateBodySampleRate() {
        XCTAssertEqual(TranscriptionRoute.sampleRate(fromCreateBody: Data()), 16_000)
        XCTAssertEqual(TranscriptionRoute.sampleRate(fromCreateBody: Data("{}".utf8)), 16_000)
        XCTAssertEqual(TranscriptionRoute.sampleRate(fromCreateBody: Data(#"{"sample_rate":48000}"#.utf8)), 48_000)
        XCTAssertNil(TranscriptionRoute.sampleRate(fromCreateBody: Data(#"{"sample_rate":"48000"}"#.utf8)))
        XCTAssertNil(TranscriptionRoute.sampleRate(fromCreateBody: Data(#"{"sample_rate":true}"#.utf8)))
        XCTAssertNil(TranscriptionRoute.sampleRate(fromCreateBody: Data("not json".utf8)))
    }

    // MARK: - Resampler

    func testResamplerPassesThrough16kAndCarriesOddBytes() {
        let resampler = PCM16Resampler(inputRate: 16_000)!
        let pcm = Data((0..<10).map { UInt8($0) })
        var out = resampler.convert(pcm.prefix(3))
        out += resampler.convert(pcm.suffix(7))
        out += resampler.flush()
        XCTAssertEqual(out, pcm)
    }

    func testResamplerConverts48kToAThirdAsManySamples() {
        let resampler = PCM16Resampler(inputRate: 48_000)!
        let input = sine(rate: 48_000, seconds: 1)
        var out = Data()
        // Odd chunk sizes, so samples straddle chunk boundaries.
        var offset = 0
        while offset < input.count {
            let end = min(offset + 4_001, input.count)
            out += resampler.convert(input.subdata(in: offset..<end))
            offset = end
        }
        out += resampler.flush()
        XCTAssertEqual(Double(out.count / 2), 16_000, accuracy: 50)
    }

    func testResamplerRejectsAbsurdRates() {
        XCTAssertNil(PCM16Resampler(inputRate: 0))
        XCTAssertNil(PCM16Resampler(inputRate: 1_000_000))
    }

    // MARK: - Session bookkeeping

    func testStreamsAudioAndReturnsTheCommittedText() async throws {
        let stream = FakeStream(result: .success("hello world"))
        let manager = RemoteTranscriptionManager(backend: .fake(stream: stream))
        let id = try await manager.create(sampleRate: 16_000)
        XCTAssertEqual(manager.activity.active, 1)
        let second = sine(rate: 16_000, seconds: 1)
        try await manager.append(id: id, pcm: second.prefix(4_000))
        try await manager.append(id: id, pcm: second.dropFirst(4_000))
        let text = try await manager.finish(id: id)
        XCTAssertEqual(text, "hello world")
        // One second is 50 whole 20 ms frames, split between sends and the commit.
        let (sent, committed) = await stream.counts
        XCTAssertEqual(sent + committed, 50)
        XCTAssertEqual(manager.activity.active, 0)
    }

    func testFinishedSessionsAnswerConflictAndUnknownIDsNotFound() async throws {
        let manager = RemoteTranscriptionManager(backend: .fake(stream: FakeStream(result: .success("x"))))
        let id = try await manager.create()
        try await manager.append(id: id, pcm: sine(rate: 16_000, seconds: 0.2))
        _ = try await manager.finish(id: id)
        await assertThrows(.alreadyFinished) { try await manager.finish(id: id) }
        await assertThrows(.alreadyFinished) { try await manager.append(id: id, pcm: Data(count: 2)) }
        await assertThrows(.unknownSession) { try await manager.finish(id: "nope") }
        await assertThrows(.unsupportedSampleRate) { _ = try await manager.create(sampleRate: 3) }
    }

    func testNoAudioIsEmptyTextWithoutCommitting() async throws {
        let stream = FakeStream(result: .success("should not be used"))
        let manager = RemoteTranscriptionManager(backend: .fake(stream: stream))
        let id = try await manager.create()
        let text = try await manager.finish(id: id)
        XCTAssertEqual(text, "")
        let cancelled = await stream.cancelled
        XCTAssertTrue(cancelled)
    }

    func testFallsBackToTheClipWhenTheStreamCannotOpen() async throws {
        let clips = ClipLog()
        let backend = RemoteTranscriptionBackend(
            openStream: { _ in throw TranscriberError.noBasetenKey },
            transcribeClip: { wav in await clips.add(wav); return "from fallback" })
        let manager = RemoteTranscriptionManager(backend: backend)
        let id = try await manager.create(sampleRate: 16_000)
        try await manager.append(id: id, pcm: sine(rate: 16_000, seconds: 0.5))
        let text = try await manager.finish(id: id)
        XCTAssertEqual(text, "from fallback")
        let wav = try WAVFile.parse(await clips.first!)
        XCTAssertEqual(wav.sampleRate, 16_000)
        XCTAssertEqual(wav.samples.count, 16_000)
    }

    func testFallsBackWhenTheCommitFails() async throws {
        let backend = RemoteTranscriptionBackend(
            openStream: { _ in FakeStream(result: .failure(TranscriberError.streamTimeout)) },
            transcribeClip: { _ in "rescued" })
        let manager = RemoteTranscriptionManager(backend: backend)
        let id = try await manager.create()
        try await manager.append(id: id, pcm: sine(rate: 16_000, seconds: 0.3))
        let text = try await manager.finish(id: id)
        XCTAssertEqual(text, "rescued")
    }

    func testUpstreamFailureSurfaces() async throws {
        let backend = RemoteTranscriptionBackend(
            openStream: { _ in throw TranscriberError.noBasetenKey },
            transcribeClip: { _ in throw TranscriberError.signInExpired })
        let manager = RemoteTranscriptionManager(backend: backend)
        let id = try await manager.create()
        try await manager.append(id: id, pcm: sine(rate: 16_000, seconds: 0.1))
        do {
            _ = try await manager.finish(id: id)
            XCTFail("expected a failure")
        } catch let RemoteTranscriptionManager.Failure.upstream(_, unavailable) {
            XCTAssertTrue(unavailable)
        }
    }

    func testCancelForgetsTheSessionAndReleasesTheStream() async throws {
        let stream = FakeStream(result: .success("x"))
        let manager = RemoteTranscriptionManager(backend: .fake(stream: stream))
        let id = try await manager.create()
        try await manager.append(id: id, pcm: sine(rate: 16_000, seconds: 0.1))
        try await manager.cancel(id: id)
        XCTAssertEqual(manager.activity.active, 0)
        await assertThrows(.unknownSession) { try await manager.finish(id: id) }
    }

    func testReaperDropsIdleSessionsAndSignalsIdle() async throws {
        let manager = RemoteTranscriptionManager(backend: .fake(stream: FakeStream(result: .success("x"))))
        let idled = expectation(description: "idle")
        manager.activity.onIdle = { idled.fulfill() }
        let start = Date()
        let stale = try await manager.create(now: start)
        let fresh = try await manager.create(now: start.addingTimeInterval(100))
        await manager.reap(now: start.addingTimeInterval(RemoteTranscriptionManager.idleLimit + 1))
        XCTAssertEqual(manager.activity.active, 1)
        await assertThrows(.unknownSession) { try await manager.append(id: stale, pcm: Data(count: 2)) }
        try await manager.cancel(id: fresh)
        await fulfillment(of: [idled], timeout: 1)
    }

    // MARK: - Helpers

    private func sine(rate: Int, seconds: Double) -> Data {
        var data = Data()
        for i in 0 ..< Int(Double(rate) * seconds) {
            let value = Int16(10_000 * sin(2 * Double.pi * 440 * Double(i) / Double(rate)))
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func assertThrows(_ expected: RemoteTranscriptionManager.Failure,
                              file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let failure as RemoteTranscriptionManager.Failure {
            XCTAssertEqual(failure, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}

private actor FakeStream: TranscriptionStream {
    private let result: Result<String, Error>
    private var sent = 0
    private var committed = 0
    private(set) var cancelled = false

    init(result: Result<String, Error>) { self.result = result }

    var counts: (Int, Int) { (sent, committed) }

    func send(packets: [Data]) { sent += packets.count }
    func commit(packets: [Data], timeout: Duration) throws -> String {
        committed = packets.count
        return try result.get()
    }
    func cancel() { cancelled = true }
}

private actor ClipLog {
    private var clips: [Data] = []
    func add(_ clip: Data) { clips.append(clip) }
    var first: Data? { clips.first }
}

private extension RemoteTranscriptionBackend {
    static func fake(stream: FakeStream) -> RemoteTranscriptionBackend {
        RemoteTranscriptionBackend(openStream: { _ in stream }, transcribeClip: { _ in "fallback" })
    }
}
