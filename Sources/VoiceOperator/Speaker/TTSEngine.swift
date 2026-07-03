import Foundation

/// Turns an `Utterance` into audio: cache hit → play instantly; miss →
/// synthesize (Cartesia), cache the WAV, then play. Playback is haltable for
/// dictation barge-in. Reaps stale cache entries on init.
@MainActor
final class TTSEngine {
    private let synth: SpeechSynthesizer
    private let cache: AudioCache
    private let player = SpeechPlayer()

    /// Synthesis tasks currently in flight, keyed by cache key. Coalesces
    /// concurrent requests for the same text+voice (e.g. a replay clicked while
    /// the original is still synthesizing, or two sessions producing identical
    /// audio) into a single provider call whose result everyone reuses.
    private var inFlight: [String: Task<URL, Error>] = [:]

    init(synth: SpeechSynthesizer = CartesiaSynthesizer(), cache: AudioCache = AudioCache()) {
        self.synth = synth
        self.cache = cache
        let reaped = cache.reap()
        if reaped > 0 { NSLog("audio cache: reaped \(reaped) stale entr\(reaped == 1 ? "y" : "ies")") }
    }

    /// Play an utterance. Returns true if it finished, false if halted or failed.
    func play(_ u: Utterance) async -> Bool {
        let url: URL
        do { url = try await audioURL(for: u) }
        catch { NSLog("tts synth failed: \(error)"); return false }
        return await player.play(url: url)
    }

    /// Resolve the WAV for an utterance: cache hit → reuse; in-flight synthesis →
    /// await it; otherwise start one and register it so concurrent callers share.
    private func audioURL(for u: Utterance) async throws -> URL {
        if let hit = cache.cached(text: u.spokenText, voiceID: u.voiceID) { return hit }
        let key = cache.key(text: u.spokenText, voiceID: u.voiceID)
        if let existing = inFlight[key] { return try await existing.value }

        let task = Task { [synth, cache] in
            let data = try await synth.synthesizeWAV(text: u.spokenText, voiceID: u.voiceID)
            return try cache.store(data, text: u.spokenText, voiceID: u.voiceID)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    func halt() { player.halt() }

    /// Playback-readiness of an utterance's audio, for the menu's replay list.
    enum AudioState { case ready, synthesizing, needsSynthesis }
    func audioState(for u: Utterance) -> AudioState {
        let key = cache.key(text: u.spokenText, voiceID: u.voiceID)
        if inFlight[key] != nil { return .synthesizing }
        return cache.contains(text: u.spokenText, voiceID: u.voiceID) ? .ready : .needsSynthesis
    }
}
