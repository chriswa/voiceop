import AVFoundation
import XCTest
@testable import VoiceOperator

final class PlaybackTimelineTests: XCTestCase {
    func testSourcePositionFreezesAcrossNetworkGaps() {
        var timeline = PlaybackTimeline()
        timeline.schedule(sourceStart: 0, count: 100, nodeStart: 0)
        timeline.schedule(sourceStart: 100, count: 100, nodeStart: 300)
        XCTAssertEqual(timeline.position(nodeFrame: 90), 90)
        XCTAssertEqual(timeline.position(nodeFrame: 200), 100)
        XCTAssertEqual(timeline.position(nodeFrame: 310), 110)
        XCTAssertEqual(timeline.position(nodeFrame: 500), 200)
    }

    func testSeekRejectsOldCompletionsAndStartsAtTheRequestedSourceFrame() {
        var timeline = PlaybackTimeline()
        timeline.schedule(sourceStart: 0, count: 240_000, nodeStart: 0)
        let old = timeline.generation
        timeline.reset(at: 48_000)
        timeline.schedule(sourceStart: 48_000, count: 192_000, nodeStart: 0)
        XCTAssertFalse(timeline.acknowledge(end: 240_000, generation: old))
        XCTAssertEqual(timeline.acknowledged, 48_000)
        XCTAssertEqual(timeline.position(nodeFrame: 24_000), 72_000)
        XCTAssertTrue(timeline.acknowledge(end: 240_000, generation: timeline.generation))
    }

    func testRateStepsLimitsAndNewSessionReset() {
        var controls = PlaybackControls()
        controls.adjust(by: 0.2)
        XCTAssertEqual(controls.rate, 1.2)
        controls.adjust(by: -0.2)
        XCTAssertEqual(controls.rate, 1)
        for _ in 0..<30 { controls.adjust(by: 0.2) }
        XCTAssertEqual(controls.rate, 5)
        for _ in 0..<30 { controls.adjust(by: -0.2) }
        XCTAssertEqual(controls.rate, 0.5)
        XCTAssertEqual(PlaybackControls().rate, 1)
    }

    func testCompletionGraceAndRepeatedReplayKeepTheSameSpeed() {
        var controls = PlaybackControls()
        controls.adjust(by: 0.2)
        controls.finish(now: 100)
        XCTAssertTrue(controls.canRewind(now: 101.99))
        XCTAssertFalse(controls.canRewind(now: 102))
        XCTAssertTrue(controls.rewind(now: 101))
        XCTAssertTrue(controls.replaying)
        XCTAssertTrue(controls.canRewind(now: 200))
        XCTAssertEqual(controls.rate, 1.2)
        controls.finish(now: 201)
        XCTAssertTrue(controls.rewind(now: 202))
        controls.finish(now: 205)
        XCTAssertFalse(controls.rewind(now: 207))
    }

    /// Runs the actual Apple time-pitch graph in offline mode. No audio device
    /// opens, no sound plays, and no user's dictation/listening is interrupted.
    @MainActor
    func testOfflineGraphRewindsAcrossSentencesAndChangesRateLive() async throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                   channels: 1, interleaved: false)!
        let player = StreamingSpeechPlayer()
        try player.start(format: format, manualRendering: true)
        defer { player.halt() }
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        func sentence() -> AVAudioPCMBuffer {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
            buffer.frameLength = 48_000
            for i in 0..<48_000 { buffer.floatChannelData![0][i] = 0.1 * sin(Float(i) * 0.1) }
            return buffer
        }
        player.beginSentence(onStart: {})
        player.schedule(sentence())
        player.endOfStream()
        try await render(player, into: output, count: 110)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(player.atEnd, "first sentence must drain in offline rendering")
        XCTAssertEqual(player.position, 2, accuracy: 0.01)
        player.beginSentence(onStart: {})
        player.schedule(sentence())
        player.endOfStream()
        try await render(player, into: output, count: 50)
        let beforeSeek = player.position
        XCTAssertGreaterThan(beforeSeek, 2.5)
        XCTAssertTrue(player.seek(to: max(0, beforeSeek - 3)))
        XCTAssertLessThan(player.position, 1, "rewind must reach the first sentence")
        try await render(player, into: output, count: 10)
        let atNormalRate = player.position
        player.setRate(5)
        try await render(player, into: output, count: 10)
        XCTAssertGreaterThan(player.position - atNormalRate, 0.5,
                             "the source clock must accelerate with the live time-pitch rate")
        player.setRate(0.5)
        let atSlowStart = player.position
        try await render(player, into: output, count: 10)
        XCTAssertLessThan(player.position - atSlowStart, 0.4)
        player.setRate(5)
        try await render(player, into: output, count: 100)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(player.atEnd)
        XCTAssertEqual(player.duration, 4, accuracy: 0.01)
        XCTAssertTrue(player.seek(to: 1), "completed audio remains seekable during session retention")
        XCTAssertLessThan(player.position, 1.1)
        try await render(player, into: output, count: 100)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(player.atEnd)
    }

    /// Speech is lifted by `makeupGainDB`, and a sentence that already peaks
    /// near full scale is held under it rather than clipped.
    @MainActor
    func testOfflineGraphAddsMakeupGainWithoutClipping() async throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                   channels: 1, interleaved: false)!
        func peak(amplitude: Float) async throws -> Float {
            let player = StreamingSpeechPlayer()
            try player.start(format: format, manualRendering: true)
            defer { player.halt() }
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000)!
            buffer.frameLength = 24_000
            for i in 0..<24_000 { buffer.floatChannelData![0][i] = amplitude * sin(Float(i) * 0.1) }
            player.beginSentence(onStart: {})
            player.schedule(buffer)
            player.endOfStream()
            let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
            var loudest: Float = 0
            for _ in 0..<40 {
                try await render(player, into: output, count: 1)
                for i in 0..<Int(output.frameLength) { loudest = max(loudest, abs(output.floatChannelData![0][i])) }
            }
            return loudest
        }
        let quiet = try await peak(amplitude: 0.03)
        XCTAssertEqual(20 * log10(quiet / 0.03), SpeechLoudness.makeupGainDB, accuracy: 0.5)
        let hot = try await peak(amplitude: 0.98)
        XCTAssertLessThan(hot, 1.0)
    }

    @MainActor
    func testRewindWhileProducerIsOpenPreservesCompletionAndAcceptsMoreAudio() async throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                   channels: 1, interleaved: false)!
        let player = StreamingSpeechPlayer()
        try player.start(format: format, manualRendering: true)
        defer { player.halt() }
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000)!
        chunk.frameLength = 24_000
        chunk.floatChannelData![0].initialize(repeating: 0, count: 24_000)
        player.beginSentence(onStart: {})
        player.schedule(chunk)
        let completion = Task { await player.awaitCompletion() }
        try await render(player, into: output, count: 30)
        XCTAssertTrue(player.seek(to: 0.1))
        XCTAssertTrue(player.seek(to: 0)) // repeated seeks invalidate every old callback
        try await render(player, into: output, count: 80)
        XCTAssertFalse(player.atEnd, "draining buffered audio is not EOF while synthesis is open")
        XCTAssertEqual(player.position, 1, accuracy: 0.01)
        player.schedule(chunk) // a delayed next packet, with an intervening underrun
        player.endOfStream()
        try await render(player, into: output, count: 100)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(player.atEnd)
        if !player.atEnd { player.halt() } // fail cleanly instead of parking the test
        let finished = await completion.value
        XCTAssertTrue(finished, "rewind must neither cancel nor lose the original sentence waiter")
        XCTAssertEqual(player.position, 2, accuracy: 0.01)
    }

    /// A held player queues audio silently; release plays all of it from the top.
    @MainActor
    func testHeldPlayerStaysSilentUntilReleasedThenPlaysFromTheStart() async throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                   channels: 1, interleaved: false)!
        let player = StreamingSpeechPlayer()
        try player.start(format: format, manualRendering: true)
        defer { player.halt() }
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000)!
        chunk.frameLength = 24_000
        for i in 0..<24_000 { chunk.floatChannelData![0][i] = 0.1 * sin(Float(i) * 0.1) }
        var started = false
        player.hold()
        player.beginSentence(onStart: { started = true })
        player.schedule(chunk)
        player.endOfStream()
        XCTAssertTrue(started, "the sentence is ready even while its audio is held")
        try await render(player, into: output, count: 20)
        let peak = (0..<Int(output.frameLength)).map { abs(output.floatChannelData![0][$0]) }.max() ?? 0
        XCTAssertEqual(peak, 0, "held audio must not reach the output")
        XCTAssertEqual(player.position, 0, accuracy: 0.001)
        XCTAssertFalse(player.atEnd)
        player.release()
        try await render(player, into: output, count: 60)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(player.atEnd, "released audio plays through in full")
        XCTAssertEqual(player.position, 1, accuracy: 0.01)
    }

    @MainActor
    private func render(_ player: StreamingSpeechPlayer, into output: AVAudioPCMBuffer, count: Int) async throws {
        var rendered = 0
        for _ in 0..<(count * 10) {
            let status = try player.renderOffline(frames: 512, into: output)
            if status == .success { rendered += 1 }
            if rendered == count { return }
            await Task.yield()
        }
        XCTFail("offline renderer did not produce the requested number of buffers")
    }

    @MainActor
    func testForwardSeekCarriesAcrossUnreceivedSentencesAndRetainsSkippedAudio() async throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                   channels: 1, interleaved: false)!
        let player = StreamingSpeechPlayer()
        try player.start(format: format, manualRendering: true)
        defer { player.halt() }
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000)!
        chunk.frameLength = 24_000
        chunk.floatChannelData![0].initialize(repeating: 0, count: 24_000)
        player.beginSentence(onStart: {})
        player.schedule(chunk)
        XCTAssertTrue(player.seek(to: 1.5))
        XCTAssertTrue(player.skipAhead(seconds: 2), "another skip must extend the pending target")
        player.endOfStream()
        XCTAssertTrue(player.atEnd)
        // Two entire future sentences are skipped, then half of the fourth.
        for _ in 0..<2 {
            player.beginSentence(onStart: {})
            player.schedule(chunk)
            player.endOfStream()
            XCTAssertTrue(player.atEnd)
        }
        player.beginSentence(onStart: {})
        player.schedule(chunk)
        player.endOfStream()
        XCTAssertFalse(player.atEnd)
        XCTAssertEqual(player.position, 3.5, accuracy: 0.01)
        try await render(player, into: output, count: 40)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(player.atEnd)
        XCTAssertEqual(player.position, 4, accuracy: 0.01)
        XCTAssertTrue(player.seek(to: 0.5), "skipped audio must remain rewindable")
        XCTAssertEqual(player.position, 0.5, accuracy: 0.01)
    }
}
