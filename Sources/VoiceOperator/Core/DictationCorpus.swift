import Foundation

/// Every recognition this Mac has run, with the audio it ran on, kept so the
/// clips can be scored and used to train a model on this user's voice.
///
/// `dictation-corpus/entries.jsonl` in Application Support holds one JSON object
/// per line and only ever grows. `AudioArbiter` points each line at the clip it
/// already keeps in `stt-history/`; phone and hands-free dictation have no
/// history entry, so their clips are kept in `dictation-corpus/clips/`.
///
/// History can't serve for this: it holds what was pasted, after shaping and
/// clean-up, a retry overwrites it, and it has no phone or hands-free dictation.
///
/// Incognito mode writes none of it.
final class DictationCorpus: @unchecked Sendable {
    static let shared: DictationCorpus = {
        // Under `swift test`, keep fake dictations out of the user's real corpus.
        if NSClassFromString("XCTestCase") != nil {
            return DictationCorpus(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("VoiceOperator-tests-corpus-\(UUID().uuidString)"))
        }
        return DictationCorpus(directory: HistoryStore.supportDir.appendingPathComponent("dictation-corpus"))
    }()
    static let incognitoActivity = Incognito.Activity.persist("dictation corpus")

    enum Source: String, Codable, Sendable {
        case dictation, command, retry, phone
        case handsFree = "hands-free"
    }

    /// What one recognition produced.
    struct Recognition: Codable, Equatable, Sendable {
        let source: Source
        /// A `TranscriptionProviderID` raw value.
        let provider: String
        /// `TranscriptionProvider.modelName`.
        let model: String
        /// Whether the provider's fallback path produced this, not its live one.
        let fellBack: Bool
        /// What recognition produced, before clean-up and shaping.
        let recognized: String
        /// What the clean-up pass made of `recognized`; nil when none ran.
        let cleaned: String?
        let seconds: TimeInterval
        /// The input device's name; nil when the audio came from elsewhere.
        let mic: String?
        /// The user chose to discard this dictation rather than paste it.
        let discarded: Bool
        /// The history entry whose clip a retry ran on.
        let retryOf: UUID?

        init(source: Source, provider: any TranscriptionProvider, transcript: Transcript, fellBack: Bool,
             seconds: TimeInterval, mic: String?, discarded: Bool = false, retryOf: UUID? = nil) {
            self.source = source
            self.provider = provider.id.rawValue
            model = provider.modelName
            self.fellBack = fellBack
            recognized = transcript.raw ?? transcript.text
            cleaned = transcript.raw == nil ? nil : transcript.text
            self.seconds = seconds
            self.mic = mic
            self.discarded = discarded
            self.retryOf = retryOf
        }

        init(source: Source, outcome: TranscriptionLeg.Outcome, seconds: TimeInterval, mic: String?,
             discarded: Bool = false) {
            self.init(source: source, provider: outcome.provider, transcript: outcome.transcript,
                      fellBack: outcome.liveFailure != nil, seconds: seconds, mic: mic, discarded: discarded)
        }
    }

    /// One line of `entries.jsonl`.
    struct Entry: Codable, Equatable, Sendable {
        let id: UUID
        let date: Date
        let appVersion: String
        /// The path of the clip (16 kHz mono WAV).
        let clip: String
        let recognition: Recognition
    }

    private let directory: URL
    private var clips: URL { directory.appendingPathComponent("clips") }
    private var file: URL { directory.appendingPathComponent("entries.jsonl") }
    private let queue = DispatchQueue(label: "com.voiceop.dictation-corpus")

    init(directory: URL) { self.directory = directory }

    /// File a recognition whose clip is already on disk.
    func record(_ recognition: Recognition, clipAt url: URL, id: UUID = UUID(), now: Date = Date()) {
        guard shouldKeep(recognition) else { return }
        queue.async { [self] in append(id: id, date: now, clip: url, recognition) }
    }

    /// File a recognition and keep its clip (a WAV), which nothing else keeps.
    func record(_ recognition: Recognition, keeping wav: Data, id: UUID = UUID(), now: Date = Date()) {
        guard shouldKeep(recognition) else { return }
        queue.async { [self] in
            let url = clips.appendingPathComponent("\(id.uuidString).wav")
            do {
                try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
                try wav.write(to: url)
            } catch {
                Log.log("corpus: could not keep a clip: \(error)")
                return
            }
            append(id: id, date: now, clip: url, recognition)
        }
    }

    /// Everything filed so far.
    func entries() -> [Entry] {
        queue.sync {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return text.split(separator: "\n").compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
        }
    }

    private func shouldKeep(_ recognition: Recognition) -> Bool {
        Incognito.refusal(Self.incognitoActivity) == nil
            && !recognition.recognized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// **queue only.**
    private func append(id: UUID, date: Date, clip: URL, _ recognition: Recognition) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let entry = Entry(id: id, date: date, appVersion: BuildInfo.version, clip: clip.path, recognition: recognition)
        do {
            var line = try encoder.encode(entry)
            line.append(0x0A)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: file)
            }
        } catch {
            Log.log("corpus: could not write an entry: \(error)")
        }
    }
}
