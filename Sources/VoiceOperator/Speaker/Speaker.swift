import Foundation

/// One thing to say. `name` is the call-sign and `body` the summary; the text
/// actually sent to TTS is "⟨name⟩ here. ⟨body⟩". `voiceID` is the Cartesia
/// voice; `sessionKey` identifies the originating Claude surface for spaceterm
/// speaking events. Keeping name/body separate lets the history show them nicely.
struct Utterance: Sendable, Equatable {
    let name: String
    let body: String
    let voiceID: String
    let sessionKey: String?

    var spokenText: String { "\(name) here. \(body)" }
}

/// Text→audio provider, swappable like `Transcriber`. Produces a complete WAV
/// for a given text+voice (so it can be cached and replayed for free).
protocol SpeechSynthesizer: Sendable {
    func synthesizeWAV(text: String, voiceID: String) async throws -> Data
}

enum SpeakerError: Error {
    case noAPIKey
    case http(status: Int, body: String)
}
