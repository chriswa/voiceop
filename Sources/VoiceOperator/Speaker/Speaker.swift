import Foundation

/// One thing to say. `name` is the call-sign and `body` the summary; the text
/// actually sent to TTS is "⟨name⟩ here. ⟨body⟩". `voiceID` is the TTS provider's
/// voice id; `sessionKey` identifies the originating Claude surface for spaceterm
/// speaking events. Keeping name/body separate lets the history show them nicely.
///
/// A `verbatim` utterance (⌘⌃S speak-the-clipboard) is spoken exactly as its
/// `body` — no call-sign prefix — since it's the user's own text, not an agent
/// update.
struct Utterance: Sendable, Equatable {
    let name: String
    let body: String
    let voiceID: String
    let sessionKey: String?
    var verbatim: Bool = false

    var spokenText: String { verbatim ? body : "\(name) here. \(body)" }
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
