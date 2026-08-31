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

    /// Word timings by cache key, so a replay or a cache-hit clip doesn't
    /// re-synthesize them. Session-scoped; timings are deterministic per clip.
    private var timingsCache: [String: [WordTiming]] = [:]

    /// Bumped by `halt()`. A stream that was still synthesizing when halted has no
    /// live playback left to stop once it resolves, so playback paths re-check this
    /// counter and skip if a halt happened meanwhile. Synthesis itself always runs
    /// to completion so the clip lands in cache (barge-in re-cues from cache).
    private var haltCount = 0

    /// How often a clip that has neither started nor finished says where it is.
    private static let stallReportSeconds = 20
    /// Backstop for a clip that never resolves at all.
    ///
    /// Deliberately longer than the synthesizer's own cap, so an upstream stall
    /// is reported and cancelled by the layer that can name the cause before this
    /// blunter one fires. This catches what that cannot: audio that arrived and
    /// was scheduled, but whose `AVAudioPlayerNode` completion callbacks stopped
    /// coming, which leaves `awaitCompletion()` parked forever.
    private static let stallHardCapSeconds = 150

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
    ///
    /// `onSynthesized` fires when this clip's audio is fully in hand and it has
    /// stopped competing for the synthesizer — which is a different moment from
    /// both `onStart` (audio began, more is still being generated) and the
    /// return (audio finished playing, long after). The speech queue schedules
    /// its lookahead on it: while the sentence being played is still
    /// synthesizing, it is the only clip anyone is waiting on, and nothing
    /// speculative should be competing with it. It fires on failure too, so a
    /// clip that dies cannot pin the queue's window shut.
    func play(_ u: Utterance,
              onStart: @escaping @Sendable @MainActor () -> Void = {},
              onSynthesized: @escaping @Sendable @MainActor () -> Void = {}) async -> Bool {
        let mark = haltCount
        let key = cache.key(text: u.spokenText, voiceID: u.voiceID)
        // Which of the three routes a clip took is the first thing worth knowing
        // about a clip that never made a sound, because they fail differently.
        let label = Log.clip(u.spokenText)

        // A. Cache hit — play the stored WAV directly.
        if let hit = cache.cached(text: u.spokenText, voiceID: u.voiceID) {
            guard haltCount == mark else { return false }
            Log.log("tts play: \(label) cache hit")
            onSynthesized()
            onStart()
            return await filePlayer.play(url: hit)
        }
        // B. A stream for this exact clip is already running — await its cached
        //    URL and play the file rather than opening a second provider call.
        if let existing = inFlight[key] {
            Log.log("tts play: \(label) waiting on an in-flight synthesis of the same clip")
            guard let url = try? await existing.value else {
                Log.log("tts play: \(label) the in-flight synthesis it waited on failed — no audio")
                onSynthesized()
                return false
            }
            onSynthesized()
            guard haltCount == mark else { return false }
            onStart()
            return await filePlayer.play(url: url)
        }
        // C. Originator — stream and play live.
        Log.log("tts play: \(label) synthesizing")
        return await streamAndPlay(u, key: key, mark: mark, onStart: onStart, onSynthesized: onSynthesized)
    }

    /// Stream the utterance, teeing each chunk to the live player and to an
    /// accumulator that becomes the cached WAV. The synthesis producer runs to
    /// completion (and caches) even across a halt, so a barged-in clip re-cues
    /// from cache instantly.
    private func streamAndPlay(_ u: Utterance, key: String, mark: Int,
                               onStart: @escaping @Sendable @MainActor () -> Void,
                               onSynthesized: @escaping @Sendable @MainActor () -> Void) async -> Bool {
        let player = StreamingSpeechPlayer()
        player.onFirstBuffer = onStart
        do { try player.start(format: streamFormat) }
        catch {
            Log.log("tts stream: engine start failed (\(error)); falling back to WAV")
            return await playViaWAV(u, key: key, mark: mark, onStart: onStart, onSynthesized: onSynthesized)
        }
        activeStream = player

        // Inherits the main actor (created in a @MainActor method), so the consume
        // loop, scheduling, and cache write are all serialized on the main actor.
        let producer = Task<URL, Error> {
            // Every exit path clears the slot, rather than each one remembering
            // to. A slot left behind is not a leak of memory but of behaviour:
            // `play` coalesces onto whatever it finds in `inFlight`, so a stale
            // entry makes that exact sentence fail instantly and forever after.
            defer { self.inFlight[key] = nil }
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
                throw error
            }
            player.endOfStream()
            guard !acc.isEmpty else {     // empty transcript: nothing to cache
                Log.log("tts stream: \(Log.clip(u.spokenText)) produced no audio")
                throw SpeakerError.synthesis("no audio")
            }
            let wav = PCMAudio.wav(fromFloat32: acc, sampleRate: self.synth.sampleRate)
            return try self.cache.store(wav, text: u.spokenText, voiceID: u.voiceID)
        }
        inFlight[key] = producer
        // Synthesis settling and playback finishing are hours apart on a long
        // clip, and the queue needs the earlier one. `try?` because a clip that
        // failed or was cancelled has stopped competing for the synthesizer
        // just as surely as one that succeeded.
        Task { _ = try? await producer.value; onSynthesized() }

        // Nothing between here and `awaitCompletion` returning is otherwise
        // observable, and that is exactly the stretch a wedged clip dies in: the
        // menu bar sits on cyan, the queue will not advance past `current`, and
        // no layer above has a timeout. Report it while it is still happening,
        // then fail the clip rather than parking on it forever.
        let startedAt = Date()
        let label = Log.clip(u.spokenText)
        let watchdog = Task { [weak player] in
            var waited = 0
            while true {
                try? await Task.sleep(for: .seconds(Self.stallReportSeconds))
                if Task.isCancelled { return }
                guard let player else { return }
                waited += Self.stallReportSeconds
                Log.log("tts stall: \(label) unfinished after \(waited)s — \(player.progress)")
                guard waited >= Self.stallHardCapSeconds else { continue }
                Log.log("tts stall: \(label) giving up after \(waited)s; failing the clip so the queue can advance")
                producer.cancel()
                self.inFlight[key] = nil
                player.fail()
                return
            }
        }

        let finished = await player.awaitCompletion()
        watchdog.cancel()
        Log.log("tts play: \(label) \(finished ? "finished" : "stopped") after \(Log.elapsed(since: startedAt))")
        if activeStream === player { activeStream = nil }
        return finished && haltCount == mark
    }

    /// One-shot fallback (used when the streaming audio engine can't start):
    /// synthesize the whole WAV, cache it, then play the file.
    private func playViaWAV(_ u: Utterance, key: String, mark: Int,
                            onStart: @escaping @Sendable @MainActor () -> Void,
                            onSynthesized: @escaping @Sendable @MainActor () -> Void) async -> Bool {
        let url: URL
        do {
            let task = Task<URL, Error> {
                let data = try await self.synth.synthesizeWAV(text: u.spokenText, voiceID: u.voiceID)
                return try self.cache.store(data, text: u.spokenText, voiceID: u.voiceID)
            }
            inFlight[key] = task
            defer { inFlight[key] = nil }
            url = try await task.value
        } catch {
            Log.log("tts fallback synth failed: \(error)")
            onSynthesized()
            return false
        }
        onSynthesized()
        guard haltCount == mark else { return false }
        onStart()
        return await filePlayer.play(url: url)
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
