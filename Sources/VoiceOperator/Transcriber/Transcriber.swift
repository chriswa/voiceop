import Foundation

/// Which transcription provider. A hard-coded list: adding one is a code change,
/// and the menu offers exactly these.
enum TranscriptionProviderID: String, CaseIterable, Codable, Sendable {
    case wisprFlow = "wispr-flow"
    case parakeet = "parakeet"

    var displayName: String {
        switch self {
        case .wisprFlow: return "Wispr Flow"
        case .parakeet: return "Parakeet (on this Mac)"
        }
    }
}

/// Which provider pastes, and which (if any) shadows it. Persisted in
/// `UserDefaults` alongside the other preferences, so the choice survives
/// relaunches.
enum TranscriptionPreferences {
    private static let primaryKey = "vo.transcriptionProvider"
    private static let shadowKey = "vo.shadowTranscriptionProvider"

    /// What dictation uses until the menu says otherwise: always Parakeet, even
    /// on a Mac signed in to Wispr Flow. Wispr is only ever a deliberate choice.
    static let defaultPrimary = TranscriptionProviderID.parakeet

    /// The provider whose transcript is pasted.
    static var primary: TranscriptionProviderID {
        get { UserDefaults.standard.string(forKey: primaryKey).flatMap(TranscriptionProviderID.init) ?? defaultPrimary }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: primaryKey) }
    }

    /// Whether a provider can be chosen at all on this Mac: Wispr Flow needs a
    /// Wispr sign-in to borrow; Parakeet needs nothing.
    static func isAvailable(_ id: TranscriptionProviderID) -> Bool {
        switch id {
        case .wisprFlow: return WisprToken.hasSession
        case .parakeet: return true
        }
    }

    /// A second provider fed the same audio, whose transcript is only kept for
    /// comparison. Never the primary: choosing the shadow as primary clears it.
    static var shadow: TranscriptionProviderID? {
        get {
            let id = UserDefaults.standard.string(forKey: shadowKey).flatMap(TranscriptionProviderID.init)
            return id == primary ? nil : id
        }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: shadowKey) }
    }
}

/// Everything from the user's audio to the text that gets pasted — recognition
/// and any clean-up pass behind it are one provider, not two stages the arbiter
/// stitches together. `AudioArbiter` and `RemoteTranscriptionManager` only ever
/// talk to this; each provider owns its own encoding, credentials and fallback.
protocol TranscriptionProvider: Sendable {
    var id: TranscriptionProviderID { get }

    /// Open a live session. Called the instant the trigger key goes down,
    /// concurrently with microphone start-up, so it must not need any audio yet.
    func openSession(target: DictationTarget, trace: DictationTrace?) async throws -> any TranscriptionSession

    /// Transcribe a complete stored clip (16 kHz mono PCM WAV): history retries,
    /// the debug CLI, and dictations whose live session never opened.
    func transcribe(wavData: Data) async throws -> String

    /// Transcribe a clip whose live session has just failed, *without* opening
    /// another one: a fresh session would spend its whole hang guard again, so one
    /// bad network moment would cost two timeouts back to back.
    func transcribeAfterLiveFailure(wavData: Data) async throws -> String

    /// What `transcribeAfterLiveFailure` is called in traces ("raw /llm/asr").
    var fallbackLabel: String { get }

    /// Whether a failed live session is worth retrying on the recorded clip at
    /// all. False for a provider whose live session *is* its only path, where a
    /// retry would just fail the same way after the same wait.
    var retriesAfterLiveFailure: Bool { get }

    /// Warm connections, credentials and models so the first dictation is as
    /// quick as the tenth. Returns why the provider cannot work at all, when that
    /// is known before anyone dictates (no key, no model), else nil.
    func prewarm() async -> String?
}

extension TranscriptionProvider {
    var retriesAfterLiveFailure: Bool { true }

    func transcribe(wavURL: URL) async throws -> String {
        try await transcribe(wavData: Data(contentsOf: wavURL))
    }
}

/// The providers themselves, one instance each for the life of the process.
enum TranscriptionProviders {
    static let wisprFlow = WisprFlowProvider()
    static let parakeet = ParakeetProvider()

    static func provider(_ id: TranscriptionProviderID) -> any TranscriptionProvider {
        switch id {
        case .wisprFlow: return wisprFlow
        case .parakeet: return parakeet
        }
    }

    /// The provider whose transcript gets pasted.
    static var primary: any TranscriptionProvider { provider(TranscriptionPreferences.primary) }

    /// The provider shadowing it, if one is chosen.
    static var shadow: (any TranscriptionProvider)? { TranscriptionPreferences.shadow.map(provider) }
}

/// One live dictation inside a provider. Fed audio while the user is still
/// speaking, so only the tail is left to do when the key comes up.
protocol TranscriptionSession: Sendable {
    /// Newly captured 16 kHz mono PCM16, any length. Callers send in capture
    /// order and never concurrently (`TranscriptionLeg` chains them).
    func send(pcm: Data) async
    /// The last of the audio, then the final text. Bounded by the provider's own
    /// hang guard, after which it throws.
    func commit(pcm: Data) async throws -> String
    /// Abandon the session. Safe to call more than once.
    func cancel() async
}

/// The app a dictation is destined for; a provider may use it for tone.
struct DictationTarget: Sendable {
    var bundleIdentifier: String?
    var name: String?
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
        case let e as Incognito.Blocked: return e.description
        case let e as URLError where e.code == .timedOut: return "network timeout"
        case let e as URLError where e.code == .notConnectedToInternet: return "no internet connection"
        case is WAVFile.WAVError: return "unreadable audio file"
        default: return error.localizedDescription
        }
    }
}
