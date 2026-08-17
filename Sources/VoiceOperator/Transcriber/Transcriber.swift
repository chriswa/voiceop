import Foundation

/// A speech-to-text provider. The whole point of this protocol is that Wispr is
/// swappable: a future on-device engine (Whisper/Parakeet) implements the same
/// contract and drops in with no change to the arbiter or UI.
protocol Transcriber: Sendable {
    /// Transcribe a complete 16 kHz mono PCM WAV blob to text.
    /// - Returns: the recognized text (already punctuated for Wispr), possibly empty.
    ///
    /// This is the *stored clip* path — history retries and the debug CLI. Live
    /// dictation does not go through it: it streams audio while the user talks
    /// via `LiveTranscriber`, so that nothing but the tail is left to do when the
    /// key comes up.
    func transcribe(wavData: Data, language: String) async throws -> String
}

/// A transcriber that can upload audio *during* the recording rather than after
/// it, which is the entire reason dictation feels instant in Wispr Flow.
///
/// The arbiter opens a session when the trigger key goes down, feeds it opus
/// packets as they are encoded, and commits when the key comes up.
protocol LiveTranscriber: Transcriber {
    /// Open a streaming session. Called concurrently with microphone start-up, so
    /// it must not depend on any audio existing yet.
    func openLiveSession(app: FlowAppTarget, trace: DictationTrace?) async throws -> FlowSession

    /// Transcribe a stored clip *without* attempting the streaming path.
    ///
    /// Used when a live stream has just failed: `transcribe(wavData:)` would open
    /// another stream and could spend its whole hang guard again before giving up,
    /// so one bad network moment would cost the user two timeouts back to back.
    func transcribeWithoutStreaming(wavData: Data, language: String) async throws -> String
}

extension LiveTranscriber {
    func transcribeWithoutStreaming(wavURL: URL, language: String) async throws -> String {
        try await transcribeWithoutStreaming(wavData: Data(contentsOf: wavURL), language: language)
    }
}

/// The app a dictation is destined for, passed to the server as tone context.
struct FlowAppTarget: Sendable {
    var bundleIdentifier: String?
    var name: String?
}

extension Transcriber {
    /// Transcribe a 16 kHz mono PCM WAV file to text.
    func transcribe(wavURL: URL, language: String) async throws -> String {
        try await transcribe(wavData: Data(contentsOf: wavURL), language: language)
    }
}

enum TranscriberError: Error {
    case notSignedIn
    /// Every refresh token we hold has been spent or revoked, so only a fresh
    /// sign-in in the Wispr Flow app can restore the chain.
    case signInExpired
    case http(status: Int, body: String)
    case badResponse
    /// No Baseten key, so the streaming path is unavailable.
    case noBasetenKey
    /// The server closed the stream without ever sending a result.
    case streamEnded
    /// Committed, but no result came back inside the hang guard.
    case streamTimeout
    /// The server answered with RESULT_STATUS_ERROR.
    case serverError(String)
}

extension TranscriberError {
    /// Short human-readable reason, shown in the history menu after a failure.
    var userMessage: String {
        switch self {
        case .notSignedIn:
            return "not signed in to Wispr Flow"
        case .signInExpired:
            return "Wispr sign-in expired — open Wispr Flow and sign in"
        case .http(let status, let body):
            // The API's error bodies look like {"detail": "Request timed out"}.
            if let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
               let detail = obj["detail"] as? String, !detail.isEmpty {
                return "HTTP \(status) — \(detail)"
            }
            return "HTTP \(status)"
        case .badResponse:
            return "bad server response"
        case .noBasetenKey:
            return "no Baseten key"
        case .streamEnded:
            return "stream closed with no result"
        case .streamTimeout:
            return "no result after commit"
        case .serverError(let detail):
            return detail
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
