import AVFoundation
import Foundation

/// Synthesis/cache owner. One seekable player spans every sentence of a job;
/// producer lifetimes remain independent so interruption still fills the cache.
@MainActor
final class TTSEngine {
    private let synth: SpeechSynthesizer
    private let cache: AudioCache
    private let streamFormat: AVAudioFormat
    private var player: StreamingSpeechPlayer?
    private var inFlight: [String: Task<URL, Error>] = [:]
    private var timingsCache: [String: [WordTiming]] = [:]
    private var haltCount = 0
    private(set) var playbackRate: Float = 1
    var onDrain: (() -> Void)?
    var position: Double { player?.position ?? 0 }
    var duration: Double { player?.duration ?? 0 }
    var atEnd: Bool { player?.atEnd ?? true }

    init(synth: SpeechSynthesizer = KokoroSynthesizer(), cache: AudioCache = AudioCache()) {
        self.synth = synth
        self.cache = cache
        self.streamFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: Double(synth.sampleRate), channels: 1, interleaved: false)!
        let reaped = cache.reap()
        if reaped > 0 { Log.log("audio cache: reaped \(reaped) stale entries") }
    }

    func beginSession(rate: Float = 1) {
        halt()
        playbackRate = PlaybackPreferences.validRate(rate)
    }

    @discardableResult
    func rewind(seconds: Double) -> Bool {
        player?.seek(to: max(0, position - seconds)) ?? false
    }

    @discardableResult
    func skipAhead(seconds: Double) -> Bool {
        player?.skipAhead(seconds: seconds) ?? false
    }

    func play(_ u: Utterance,
              onStart: @escaping @Sendable @MainActor () -> Void = {},
              onSynthesized: @escaping @Sendable @MainActor () -> Void = {}) async -> Bool {
        let mark = haltCount
        let key = cache.key(text: u.spokenText, voiceID: u.voiceID)
        let player: StreamingSpeechPlayer
        if let existing = self.player {
            player = existing
        } else {
            player = StreamingSpeechPlayer()
            do { try player.start(format: streamFormat) }
            catch {
                Log.log("tts playback engine failed to start: \(error)")
                onSynthesized()
                return false
            }
            player.setRate(playbackRate)
            player.onDrain = { [weak self] in self?.onDrain?() }
            self.player = player
        }
        player.beginSentence(onStart: onStart)

        // Both fully-cached and just-completed lookahead WAVs decode into the
        // same retained source timeline used by live chunks.
        if let hit = cache.cached(text: u.spokenText, voiceID: u.voiceID) {
            onSynthesized()
            do { try appendFile(hit, to: player) }
            catch { Log.log("tts cached audio failed: \(error)"); player.fail() }
            player.endOfStream()
            return await waitForPlayback(player, mark: mark)
        }
        if let existing = inFlight[key] {
            let url = try? await existing.value
            onSynthesized()
            guard haltCount == mark, let url else { return false }
            do { try appendFile(url, to: player) }
            catch { Log.log("tts prefetched audio failed: \(error)"); player.fail() }
            player.endOfStream()
            return await waitForPlayback(player, mark: mark)
        }

        Log.log("tts play: \(Log.clip(u.spokenText)) streaming")
        let producer = Task<URL, Error> {
            defer { self.inFlight[key] = nil }
            var acc = Data()
            var reframer = PCMReframer()
            do {
                for try await pcm in self.synth.synthesizeStream(text: u.spokenText, voiceID: u.voiceID) {
                    acc.append(pcm)
                    if self.haltCount == mark,
                       let buffer = reframer.buffer(from: pcm, format: self.streamFormat) {
                        player.schedule(buffer)
                    }
                }
                guard !acc.isEmpty else { throw SpeakerError.synthesis("no audio") }
                // Cache before finishing the stream so the queue can always
                // replay a completed sentence without a second provider call.
                let wav = PCMAudio.wav(fromFloat32: acc, sampleRate: self.synth.sampleRate)
                let url = try self.cache.store(wav, text: u.spokenText, voiceID: u.voiceID)
                if self.haltCount == mark { player.endOfStream() }
                return url
            } catch {
                Log.log("tts synthesis failed: \(error)")
                player.fail()
                throw error
            }
        }
        inFlight[key] = producer
        Task { _ = try? await producer.value; onSynthesized() }
        return await waitForPlayback(player, mark: mark)
    }

    private func appendFile(_ url: URL, to player: StreamingSpeechPlayer) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == streamFormat.sampleRate,
              file.processingFormat.channelCount == 1 else {
            throw SpeakerError.synthesis("cached audio format does not match the speech timeline")
        }
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: streamFormat, frameCapacity: 24_000) else {
                throw SpeakerError.synthesis("audio buffer allocation failed")
            }
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            player.schedule(buffer)
        }
    }

    private func waitForPlayback(_ player: StreamingSpeechPlayer, mark: Int) async -> Bool {
        // A long slow/replayed sentence is healthy as long as its playhead or
        // received PCM moves. A fixed 150-second total timeout would incorrectly
        // kill perfectly valid playback after slowing down or rewinding.
        let watchdog = Task {
            var previous = player.progress
            var previousPosition = player.position
            var stalled = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                let progress = player.progress
                let position = player.position
                if progress != previous || position != previousPosition { stalled = 0 }
                else { stalled += 5 }
                previous = progress
                previousPosition = position
                if stalled >= 150 {
                    Log.log("tts playback stalled for 150s: \(progress)")
                    player.fail()
                    return
                }
            }
        }
        defer { watchdog.cancel() }
        let result = await player.awaitCompletion()
        return result && haltCount == mark
    }

    /// Word timings for an utterance, for the highlight overlay. Memoized per
    /// clip; returns `[]` on any failure (the overlay just shows nothing).
    func wordTimings(for u: Utterance) async -> [WordTiming] {
        let key = cache.key(text: u.spokenText, voiceID: u.voiceID)
        if let hit = timingsCache[key] { return hit }
        do {
            let timings = try await synth.wordTimings(text: u.spokenText, voiceID: u.voiceID)
            timingsCache[key] = timings
            return timings
        } catch {
            Log.log("tts timings: \(Log.clip(u.spokenText)) failed: \(error)")
            return []
        }
    }

    func halt() {
        haltCount += 1
        player?.halt()
        player = nil
    }

    func setPlaybackRate(_ value: Float) {
        playbackRate = min(5, max(0.5, value))
        player?.setRate(playbackRate)
        Log.log(String(format: "tts playback rate: %.1fx", playbackRate))
    }

    /// Playback-readiness of an utterance's audio, for the menu's replay list.
    enum AudioState { case ready, synthesizing, needsSynthesis }
    func audioState(for u: Utterance) -> AudioState {
        let key = cache.key(text: u.spokenText, voiceID: u.voiceID)
        if inFlight[key] != nil { return .synthesizing }
        return cache.contains(text: u.spokenText, voiceID: u.voiceID) ? .ready : .needsSynthesis
    }

    /// Stop whatever is currently audible. The speech-service coordinator uses
    /// this for a user barge-in and for explicit cancellation.
    func stop() { halt() }

    /// Fill the audio cache without making sound, for sentence lookahead.
    ///
    /// Returns when this clip's synthesis has settled — completed, failed, or
    /// turned out to be unnecessary because the audio was already cached. The
    /// speech queue counts what is in flight from that, so returning early
    /// would let it open a third request while two were still running.
    func prefetch(text: String, voiceID: String) async {
        guard cache.cached(text: text, voiceID: voiceID) == nil else { return }
        let key = cache.key(text: text, voiceID: voiceID)
        // Someone is already synthesizing this exact clip — the originating
        // `play`, or a lookahead that has not been overtaken yet. Wait on it
        // rather than opening a second call for the same audio.
        if let existing = inFlight[key] { _ = try? await existing.value; return }
        let task = Task<URL, Error> {
            do {
                var acc = Data()
                for try await pcm in self.synth.synthesizeStream(text: text, voiceID: voiceID) { acc.append(pcm) }
                guard !acc.isEmpty else { throw SpeakerError.synthesis("no audio") }
                let wav = PCMAudio.wav(fromFloat32: acc, sampleRate: self.synth.sampleRate)
                let url = try self.cache.store(wav, text: text, voiceID: voiceID)
                self.inFlight[key] = nil
                return url
            } catch {
                // Clearing the slot is the point, not the log line. A prefetch
                // that threw used to leave its dead task in `inFlight` forever,
                // and `play` coalesces onto whatever it finds there — so every
                // later attempt at this exact sentence awaited a task that could
                // only fail, and the sentence became permanently unspeakable for
                // the life of the process. Prefetch is best-effort; a failure
                // here must cost nothing more than a re-synthesis.
                Log.log("tts prefetch: \(Log.clip(text)) failed, clearing its slot: \(error)")
                self.inFlight[key] = nil
                throw error
            }
        }
        inFlight[key] = task
        _ = try? await task.value
    }
}
