import Foundation

/// One thing to say. Voice Operator deliberately knows no agent/session identity:
/// callers supply ordinary text plus a provider voice id.
struct Utterance: Sendable, Equatable {
    let text: String
    let voiceID: String

    var spokenText: String { text }
}

/// Text→audio provider, swappable like `Transcriber`. Streams raw PCM as it's
/// synthesized (so playback can start on the first chunk) while `synthesizeWAV`
/// remains available as a one-shot fallback. Both let the result be cached and
/// replayed for free.
protocol SpeechSynthesizer: Sendable {
    /// Native sample rate of the raw PCM this synthesizer yields (mono). Drives
    /// the live-playback `AVAudioFormat` and the cached WAV's header rate.
    var sampleRate: Int { get }

    /// Stream raw `pcm_f32le` audio (mono, at `sampleRate`) as it is synthesized.
    /// The stream finishes normally when the provider is done and throws
    /// `SpeakerError` (e.g. `.synthesis`) on an error.
    func synthesizeStream(text: String, voiceID: String) -> AsyncThrowingStream<Data, Error>

    /// One-shot WAV. Fallback path (e.g. when live audio playback can't start).
    func synthesizeWAV(text: String, voiceID: String) async throws -> Data
}

enum SpeakerError: Error {
    case http(status: Int, body: String)
    /// The provider reported a synthesis error mid-stream (SSE error frame).
    case synthesis(String)
}
