import AVFoundation
import Foundation

/// Turns an `Utterance` into audio. Cache hit → play the stored WAV instantly.
/// Miss → stream from the provider (Kokoro), playing chunks as they arrive
/// while accumulating the full clip; on completion the assembled WAV is cached so
/// future plays are free. Playback is haltable for dictation barge-in. Reaps stale
/// cache entries on init.
@MainActor
final class TTSEngine {
    private let synth: SpeechSynthesizer
    private let cache: AudioCache
    /// Plays complete cached WAVs (cache hits and shared duplicates).
    private let filePlayer = SpeechPlayer()
    /// The live streaming player for the utterance currently being synthesized,
    /// so `halt()` can stop it. Nil when nothing is streaming.
    private var activeStream: StreamingSpeechPlayer?

    /// Live-playback PCM format: `pcm_f32le`, mono, at the synthesizer's native
    /// sample rate (the format its `synthesizeStream` chunks decode to).
    private let streamFormat: AVAudioFormat

    /// Synthesis tasks currently in flight, keyed by cache key, each resolving to
    /// the cached WAV's URL. Coalesces concurrent requests for the same text+voice
    /// (e.g. a replay clicked while the original is still streaming) so only one
    /// provider call runs; duplicates await this task and play the cached file.
    private var inFlight: [String: Task<URL, Error>] = [:]

    /// Bumped by `halt()`. A stream that was still synthesizing when halted has no
    /// live playback left to stop once it resolves, so playback paths re-check this
    /// counter and skip if a halt happened meanwhile. Synthesis itself always runs
    /// to completion so the clip lands in cache (barge-in re-cues from cache).
    private var haltCount = 0

    init(synth: SpeechSynthesizer = KokoroSynthesizer(), cache: AudioCache = AudioCache()) {
        self.synth = synth
        self.cache = cache
        self.streamFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(synth.sampleRate),
            channels: 1, interleaved: false)!
        let reaped = cache.reap()
        if reaped > 0 { Log.log("audio cache: reaped \(reaped) stale entr\(reaped == 1 ? "y" : "ies")") }
    }

    /// Play an utterance. `onStart` fires when playback actually begins — on the
    /// first audible chunk when streaming, or just before playback for a cache hit.
    /// Returns true if it finished, false if halted (even mid-synthesis, before
    /// playback began) or failed.
    func play(_ u: Utterance, onStart: @escaping @Sendable @MainActor () -> Void = {}) async -> Bool {
        let mark = haltCount
        let key = cache.key(text: u.spokenText, voiceID: u.voiceID)

        // A. Cache hit — play the stored WAV directly.
        if let hit = cache.cached(text: u.spokenText, voiceID: u.voiceID) {
            guard haltCount == mark else { return false }
            onStart()
            return await filePlayer.play(url: hit)
        }
        // B. A stream for this exact clip is already running — await its cached
        //    URL and play the file rather than opening a second provider call.
        if let existing = inFlight[key] {
            guard let url = try? await existing.value else { return false }
            guard haltCount == mark else { return false }
            onStart()
            return await filePlayer.play(url: url)
        }
        // C. Originator — stream and play live.
        return await streamAndPlay(u, key: key, mark: mark, onStart: onStart)
    }

    /// Stream the utterance, teeing each chunk to the live player and to an
    /// accumulator that becomes the cached WAV. The synthesis producer runs to
    /// completion (and caches) even across a halt, so a barged-in clip re-cues
    /// from cache instantly.
    private func streamAndPlay(_ u: Utterance, key: String, mark: Int,
                               onStart: @escaping @Sendable @MainActor () -> Void) async -> Bool {
        let player = StreamingSpeechPlayer()
        player.onFirstBuffer = onStart
        do { try player.start(format: streamFormat) }
        catch {
            Log.log("tts stream: engine start failed (\(error)); falling back to WAV")
            return await playViaWAV(u, key: key, mark: mark, onStart: onStart)
        }
        activeStream = player

        // Inherits the main actor (created in a @MainActor method), so the consume
        // loop, scheduling, and cache write are all serialized on the main actor.
        let producer = Task<URL, Error> {
            var acc = Data()
            var reframer = PCMReframer()
            do {
                for try await pcm in self.synth.synthesizeStream(text: u.spokenText, voiceID: u.voiceID) {
                    acc.append(pcm)   // full bytes always accumulate for the cache
                    // Feed live playback only while this play is un-halted.
                    if self.haltCount == mark,
                       let buf = reframer.buffer(from: pcm, format: self.streamFormat) {
                        player.schedule(buf)
                    }
                }
            } catch {
                Log.log("tts stream: synthesis failed: \(error)")
                player.fail()             // resolve awaitCompletion(false); do NOT cache
                self.inFlight[key] = nil
                throw error
            }
            player.endOfStream()
            guard !acc.isEmpty else {     // empty transcript: nothing to cache
                self.inFlight[key] = nil
                throw SpeakerError.synthesis("no audio")
            }
            let wav = PCMAudio.wav(fromFloat32: acc, sampleRate: self.synth.sampleRate)
            let url = try self.cache.store(wav, text: u.spokenText, voiceID: u.voiceID)
            self.inFlight[key] = nil
            return url
        }
        inFlight[key] = producer

        let finished = await player.awaitCompletion()
        if activeStream === player { activeStream = nil }
        return finished && haltCount == mark
    }

    /// One-shot fallback (used when the streaming audio engine can't start):
    /// synthesize the whole WAV, cache it, then play the file.
    private func playViaWAV(_ u: Utterance, key: String, mark: Int,
                            onStart: @escaping @Sendable @MainActor () -> Void) async -> Bool {
        let url: URL
        do {
            let task = Task<URL, Error> {
                let data = try await self.synth.synthesizeWAV(text: u.spokenText, voiceID: u.voiceID)
                return try self.cache.store(data, text: u.spokenText, voiceID: u.voiceID)
            }
            inFlight[key] = task
            defer { inFlight[key] = nil }
            url = try await task.value
        } catch { Log.log("tts fallback synth failed: \(error)"); return false }
        guard haltCount == mark else { return false }
        onStart()
        return await filePlayer.play(url: url)
    }

    func halt() {
        haltCount += 1
        filePlayer.halt()
        // Stop live playback now; the synthesis producer is intentionally left
        // running so the clip still lands in cache for an instant re-cue.
        activeStream?.halt()
        activeStream = nil
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

    /// Fill the audio cache without making sound for sentence prefetch.
    func prefetch(text: String, voiceID: String) {
        guard cache.cached(text: text, voiceID: voiceID) == nil else { return }
        let key = cache.key(text: text, voiceID: voiceID)
        guard inFlight[key] == nil else { return }
        let task = Task<URL, Error> {
            var acc = Data()
            for try await pcm in self.synth.synthesizeStream(text: text, voiceID: voiceID) { acc.append(pcm) }
            guard !acc.isEmpty else { throw SpeakerError.synthesis("no audio") }
            let wav = PCMAudio.wav(fromFloat32: acc, sampleRate: self.synth.sampleRate)
            let url = try self.cache.store(wav, text: text, voiceID: voiceID)
            self.inFlight[key] = nil
            return url
        }
        inFlight[key] = task
    }
}
