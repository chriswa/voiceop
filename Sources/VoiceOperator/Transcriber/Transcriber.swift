import Foundation

/// A speech-to-text provider. The whole point of this protocol is that Wispr is
/// swappable: a future on-device engine (Whisper/Parakeet) implements the same
/// contract and drops in with no change to the arbiter or UI.
protocol Transcriber: Sendable {
    /// Transcribe a complete 16 kHz mono PCM WAV file to text.
    /// - Returns: the recognized text (already punctuated for Wispr), possibly empty.
    func transcribe(wavURL: URL, language: String) async throws -> String
}

enum TranscriberError: Error {
    case notSignedIn
    case http(status: Int, body: String)
    case badResponse
}
