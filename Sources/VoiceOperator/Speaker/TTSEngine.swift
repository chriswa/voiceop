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
    private var inFlight: [String: Task<Clip, Error>] = [:]
    /// Incognito mode's stand-in for the disk cache: lookahead clips waiting
    /// for playback, each dropped the moment it is played, and all of them on
    /// `stop()`. `ephemeralGeneration` stops a synthesis that outlives a stop
    /// from putting its clip back.
    private var ephemeral: [String: Data] = [:]
    private var ephemeralGeneration = 0
    private var timingsCache: [String: [WordTiming]] = [:]
    private var haltCount = 0
    private(set) var playbackRate: Float = 1
    var onDrain: (() -> Void)?
    var position: Double { player?.position ?? 0 }
    /// `position` as it read at `uptime`, earlier than now: see `StreamingSpeechPlayer.position(at:)`.
    func position(at uptime: TimeInterval) -> Double { player?.position(at: uptime) ?? 0 }
    /// How far the output is behind the player, as `position` allows for it.
    var outputLatency: Double { player?.outputLatency ?? 0 }
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

    /// `startGate`, when given, holds the first audio of a new session's player
    /// until it returns; synthesis carries on meanwhile. Sentences that join a
    /// running player are not held.
    func play(_ u: Utterance,
              startGate: (@MainActor () async -> Void)? = nil,
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
            if let startGate {
                player.hold()
                Task { @MainActor in await startGate(); player.release() }
            }
        }
        player.beginSentence(onStart: onStart)

        // Both fully-cached and just-completed lookahead WAVs decode into the
        // same retained source timeline used by live chunks.
        if let hit = takeCached(key: key, text: u.spokenText, voiceID: u.voiceID) {
            onSynthesized()
            do { try append(hit, to: player) }
            catch { Log.log("tts cached audio failed: \(error)"); player.fail() }
            player.endOfStream()
            return await waitForPlayback(player, mark: mark)
        }
        if let existing = inFlight[key] {
            let clip = try? await existing.value
            ephemeral[key] = nil   // a lookahead's incognito copy: this play is it
            onSynthesized()
            guard haltCount == mark, let clip else { return false }
            do { try append(clip, to: player) }
            catch { Log.log("tts prefetched audio failed: \(error)"); player.fail() }
            player.endOfStream()
            return await waitForPlayback(player, mark: mark)
        }

        Log.log("tts play: \(Log.clip(u.spokenText)) streaming")
        let producer = Task<Clip, Error> {
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
                let clip = try self.keep(wav, text: u.spokenText, voiceID: u.voiceID)
                if self.haltCount == mark { player.endOfStream() }
                return clip
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

    /// A synthesized clip: a file in the audio cache, or in incognito mode,
    /// where nothing is written, the WAV bytes themselves.
    private enum Clip { case file(URL), memory(Data) }

    /// Keep a finished clip so the queue can replay it without another call to
    /// the synthesizer: in the disk cache, or only in memory in incognito mode.
    private func keep(_ wav: Data, text: String, voiceID: String) throws -> Clip {
        guard Incognito.allows(AudioCache.incognitoActivity) else { return .memory(wav) }
        return .file(try cache.store(wav, text: text, voiceID: voiceID))
    }

    /// A clip already synthesized for this text+voice. An incognito clip is
    /// handed over once and forgotten.
    private func takeCached(key: String, text: String, voiceID: String) -> Clip? {
        if let wav = ephemeral.removeValue(forKey: key) { return .memory(wav) }
        return cache.cached(text: text, voiceID: voiceID).map(Clip.file)
    }

    private func append(_ clip: Clip, to player: StreamingSpeechPlayer) throws {
        switch clip {
        case .file(let url): try appendFile(url, to: player)
        case .memory(let wav): try appendWAV(wav, to: player)
        }
    }

    /// The in-memory twin of `appendFile`, for the s16le WAVs `PCMAudio.wav` makes.
    private func appendWAV(_ data: Data, to player: StreamingSpeechPlayer) throws {
        let wav = try WAVFile.parse(data)
        guard Double(wav.sampleRate) == streamFormat.sampleRate else {
            throw SpeakerError.synthesis("cached audio format does not match the speech timeline")
        }
        let frames = wav.samples.count / 2
        var start = 0
        while start < frames {
            let count = min(24_000, frames - start)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: streamFormat, frameCapacity: AVAudioFrameCount(count)),
                  let dst = buffer.floatChannelData?[0] else {
                throw SpeakerError.synthesis("audio buffer allocation failed")
            }
            wav.samples.withUnsafeBytes { raw in
                let s16 = raw.bindMemory(to: Int16.self)
                for i in 0..<count { dst[i] = Float(Int16(littleEndian: s16[start + i])) / 32767 }
            }
            buffer.frameLength = AVAudioFrameCount(count)
            player.schedule(buffer)
            start += count
        }
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
        return ephemeral[key] != nil || cache.contains(text: u.spokenText, voiceID: u.voiceID) ? .ready : .needsSynthesis
    }

    /// Stop whatever is currently audible. The speech-service coordinator uses
    /// this for a user barge-in and for explicit cancellation. Also the end of
    /// an incognito job's life: its lookahead audio goes with it.
    func stop() {
        halt()
        ephemeral.removeAll()
        ephemeralGeneration += 1
        // The timings carry the words; outside incognito they are worth keeping.
        if Incognito.isOn { timingsCache.removeAll() }
    }

    /// Fill the audio cache without making sound, for sentence lookahead.
    ///
    /// Returns when this clip's synthesis has settled — completed, failed, or
    /// turned out to be unnecessary because the audio was already cached. The
    /// speech queue counts what is in flight from that, so returning early
    /// would let it open a third request while two were still running.
    func prefetch(text: String, voiceID: String) async {
        let key = cache.key(text: text, voiceID: voiceID)
        guard ephemeral[key] == nil, cache.cached(text: text, voiceID: voiceID) == nil else { return }
        let generation = ephemeralGeneration
        // Someone is already synthesizing this exact clip — the originating
        // `play`, or a lookahead that has not been overtaken yet. Wait on it
        // rather than opening a second call for the same audio.
        if let existing = inFlight[key] { _ = try? await existing.value; return }
        let task = Task<Clip, Error> {
            do {
                var acc = Data()
                for try await pcm in self.synth.synthesizeStream(text: text, voiceID: voiceID) { acc.append(pcm) }
                guard !acc.isEmpty else { throw SpeakerError.synthesis("no audio") }
                let wav = PCMAudio.wav(fromFloat32: acc, sampleRate: self.synth.sampleRate)
                let clip = try self.keep(wav, text: text, voiceID: voiceID)
                if case .memory(let wav) = clip, generation == self.ephemeralGeneration { self.ephemeral[key] = wav }
                self.inFlight[key] = nil
                return clip
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
