import Foundation

/// A speech-to-text provider. The whole point of this protocol is that Wispr is
/// swappable: a future on-device engine (Whisper/Parakeet) implements the same
/// contract and drops in with no change to the arbiter or UI.
protocol Transcriber: Sendable {
    /// Transcribe a complete 16 kHz mono PCM WAV blob to text.
    /// - Returns: the recognized text (already punctuated for Wispr), possibly empty.
    func transcribe(wavData: Data, language: String) async throws -> String

    /// Chunk duration for live dictation: the arbiter sends audio in pieces of
    /// this length while the user is still talking (Wispr Flow's model), so
    /// only a short tail remains to transcribe when recording stops.
    var liveChunkSeconds: Double { get }
}

extension Transcriber {
    /// Transcribe a 16 kHz mono PCM WAV file to text.
    func transcribe(wavURL: URL, language: String) async throws -> String {
        try await transcribe(wavData: Data(contentsOf: wavURL), language: language)
    }
}

enum TranscriberError: Error {
    case notSignedIn
    case http(status: Int, body: String)
    case badResponse
}

extension TranscriberError {
    /// Short human-readable reason, shown in the history menu after a failure.
    var userMessage: String {
        switch self {
        case .notSignedIn:
            return "not signed in to Wispr Flow"
        case .http(let status, let body):
            // The API's error bodies look like {"detail": "Request timed out"}.
            if let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
               let detail = obj["detail"] as? String, !detail.isEmpty {
                return "HTTP \(status) — \(detail)"
            }
            return "HTTP \(status)"
        case .badResponse:
            return "bad server response"
        }
    }

    /// A short display message for any error a transcription attempt can throw
    /// (TranscriberError, URLError, WAV parse failures, …).
    static func userMessage(for error: Error) -> String {
        switch error {
        case let e as TranscriberError: return e.userMessage
        case let e as URLError where e.code == .timedOut: return "network timeout"
        case let e as URLError where e.code == .notConnectedToInternet: return "no internet connection"
        case is WAVFile.WAVError: return "unreadable audio file"
        default: return error.localizedDescription
        }
    }
}
