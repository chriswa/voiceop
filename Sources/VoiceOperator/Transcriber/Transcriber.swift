import Foundation

/// Which transcription provider, filed with what it recognizes.
enum TranscriptionProviderID: String, CaseIterable, Codable, Sendable {
    case parakeet = "parakeet"

    var displayName: String {
        switch self {
        case .parakeet: return "Parakeet (on this Mac)"
        }
    }
}

/// Dictation preferences, persisted in `UserDefaults` alongside the others.
enum TranscriptionPreferences {
    private static let cleanupKey = "vo.dictationCleanup"

    /// Whether the primary's transcripts go through the on-device clean-up pass
    /// (`CleanedUpProvider`) before they are pasted. Off until chosen.
    static var cleanup: Bool {
        get { !ServiceMode.isService && UserDefaults.standard.bool(forKey: cleanupKey) }
        set { UserDefaults.standard.set(newValue, forKey: cleanupKey) }
    }
}

/// A word of a transcript and when it was said: in milliseconds from the first
/// sample of the audio that was transcribed.
struct TranscribedWord: Sendable, Equatable {
    var word: String
    var startMs: Int
    var endMs: Int
}

/// What a provider made of one dictation.
struct Transcript: Sendable, Equatable {
    /// What gets pasted.
    var text: String
    /// What recognition produced before a clean-up pass rewrote it into `text`;
    /// nil when no clean-up ran (or it failed, and `text` is the raw text).
    var raw: String? = nil
    /// `text` word by word, punctuation attached as it is there, timed against
    /// the dictation's whole audio (every sample the session or the clip was
    /// given, trimmed of nothing). Nil when the model gives no timings, and after
    /// a clean-up pass, whose text they would not describe.
    var words: [TranscribedWord]? = nil
}

/// Everything from the user's audio to the text that gets pasted — recognition
/// and any clean-up pass behind it are one provider, not two stages the arbiter
/// stitches together. `AudioArbiter` and `RemoteTranscriptionManager` only ever
/// talk to this.
protocol TranscriptionProvider: Sendable {
    var id: TranscriptionProviderID { get }

    /// The model behind this provider, filed with what it recognizes so a corpus
    /// can tell one model's output from another's.
    var modelName: String { get }

    /// Open a live session. Called the instant the trigger key goes down,
    /// concurrently with microphone start-up, so it must not need any audio yet.
    func openSession(target: DictationTarget, trace: DictationTrace?) async throws -> any TranscriptionSession

    /// Transcribe a complete stored clip (16 kHz mono PCM WAV): history retries,
    /// the debug CLI, and dictations whose live session never opened.
    func transcribe(wavData: Data) async throws -> Transcript

    /// Load models so the first dictation is as quick as the tenth. Returns why
    /// the provider cannot work at all, when that is known before anyone
    /// dictates, else nil.
    func prewarm() async -> String?
}

extension TranscriptionProvider {
    var modelName: String { id.rawValue }

    func transcribe(wavURL: URL) async throws -> Transcript {
        try await transcribe(wavData: Data(contentsOf: wavURL))
    }
}

/// The providers themselves, one instance each for the life of the process.
enum TranscriptionProviders {
    static let parakeet = ParakeetProvider()

    /// The provider whose transcript gets pasted, with the clean-up pass behind
    /// it when that is on.
    static var primary: any TranscriptionProvider {
        TranscriptionPreferences.cleanup ? CleanedUpProvider(base: parakeet) : parakeet
    }
}

/// One live dictation inside a provider. Fed audio while the user is still
/// speaking, so only the tail is left to do when the key comes up.
protocol TranscriptionSession: Sendable {
    /// Newly captured 16 kHz mono PCM16, any length. Callers send in capture
    /// order and never concurrently (`TranscriptionLeg` chains them).
    func send(pcm: Data) async
    /// The last of the audio, then the final text.
    func commit(pcm: Data) async throws -> Transcript
    /// Abandon the session. Safe to call more than once.
    func cancel() async
}

/// The app a dictation is destined for; a provider may use it for tone.
struct DictationTarget: Sendable {
    var bundleIdentifier: String?
    var name: String?
}

/// Short human-readable reasons for transcription failures.
enum TranscriptionFailure {
    /// A short display message for any error a transcription attempt can throw
    /// (model load failures, WAV parse failures, …), shown in the history menu.
    static func message(for error: Error) -> String {
        switch error {
        case is WAVFile.WAVError: return "unreadable audio file"
        default: return error.localizedDescription
        }
    }
}
