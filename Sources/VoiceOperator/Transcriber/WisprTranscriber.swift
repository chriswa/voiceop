import Foundation

/// Wispr Flow speech-to-text over the proven HTTP path (DESIGN.md, Milestone A):
///
///     POST https://api.wisprflow.ai/llm/asr
///     Authorization: <raw access token>        (NOT "Bearer …")
///     Content-Type: application/json
///     { "audio": base64(16 kHz mono WAV), "language": "en", "prompt": "<words>" }
///     -> 200 { "content": "<transcript>", "detected_language": "en" }
///
/// `prompt` carries the user's custom dictionary words (fetched + cached by
/// `WisprDictionary`). Whisper treats it as a spelling/context hint, so proper
/// nouns like "Claude", "kubectl" and "Coda" come back spelled correctly instead
/// of "Klaud"/"Q-Bectel"/"Koda". This is a lighter-weight substitute for Wispr's
/// full context-aware "flow request" (`/llm/asr_audio_chunks` with a real
/// `dictionary_context`), which needs Opus-encoded audio — deferred, see
/// DESIGN.md Milestone C.
///
/// The endpoint enforces a ~20 s server-side processing budget (it answers
/// HTTP 408 beyond it), so it can only ever transcribe a short clip. Wispr Flow
/// handles this by cutting dictations into 28-second chunks
/// (`basetenChunkSizeSeconds` in the Flow app) and POSTing each chunk to
/// /llm/asr in order, joining the per-chunk transcripts with spaces. We
/// replicate exactly that: fixed 28 s cuts, sequential requests, space-joined
/// result.
struct WisprTranscriber: Transcriber {
    private let endpoint = URL(string: "https://api.wisprflow.ai/llm/asr")!

    /// The custom-word source whose entries seed the transcription `prompt`.
    /// Defaults to the shared, cached live Wispr dictionary.
    private let dictionary: DictionaryContextProviding

    init(dictionary: DictionaryContextProviding = WisprDictionary.shared) {
        self.dictionary = dictionary
    }

    /// Wispr Flow's chunk size (`basetenChunkSizeSeconds` in the Flow app).
    static let chunkSeconds: Double = 28
    var liveChunkSeconds: Double { Self.chunkSeconds }

    private struct Response: Decodable {
        let content: String?
        let detected_language: String?
    }

    func transcribe(wavData: Data, language: String) async throws -> String {
        let token = try await WisprToken.shared.accessToken()
        // One dictionary snapshot for the whole dictation, so every chunk biases
        // toward the same words. Returns cached words immediately (empty on a
        // cold start) and refreshes in the background — never blocks dictation.
        let prompt = Self.prompt(from: await dictionary.contextWords())
        let wav = try WAVFile.parse(wavData)
        let chunks = wav.segments(maxSeconds: Self.chunkSeconds)
        if chunks.count > 1 {
            Log.log(String(format: "transcribe: %.1fs clip → %d chunks of ≤%.0fs",
                           wav.duration, chunks.count, Self.chunkSeconds))
        }
        var texts: [String] = []
        for (i, chunk) in chunks.enumerated() {
            do {
                texts.append(try await transcribeChunk(chunk.data, language: language,
                                                       token: token, prompt: prompt))
            } catch {
                if chunks.count > 1 { Log.log("transcribe: chunk \(i + 1)/\(chunks.count) failed") }
                throw error
            }
        }
        return Self.joinChunkTexts(texts)
    }

    /// The Whisper `prompt`: the custom words as a comma-separated list (Whisper's
    /// conventional hint format). Empty when there are no words yet.
    static func prompt(from words: [String]) -> String {
        words.joined(separator: ", ")
    }

    /// Flow's joining rule (`prevAsrText()`): drop empty chunks, one space between.
    static func joinChunkTexts(_ texts: [String]) -> String {
        texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Attempts per chunk: transient failures (Wispr's upstream answers 502
    /// "OpenAI request failed" sporadically, ~1 request in 20 observed) are
    /// retried with a short backoff before the whole transcription is failed.
    private static let chunkAttempts = 3

    private func transcribeChunk(_ wavData: Data, language: String, token: String,
                                 prompt: String) async throws -> String {
        for attempt in 1... {
            do { return try await transcribeChunkOnce(wavData, language: language,
                                                      token: token, prompt: prompt) }
            catch {
                guard attempt < Self.chunkAttempts, Self.isTransient(error) else { throw error }
                Log.log("transcribe: transient error (\(TranscriberError.userMessage(for: error))) — retry \(attempt)/\(Self.chunkAttempts - 1)")
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }
        fatalError("unreachable")   // the loop always returns or throws
    }

    /// Errors worth retrying: server-side hiccups and network drops. Client
    /// errors (bad auth, malformed request) fail immediately.
    private static func isTransient(_ error: Error) -> Bool {
        switch error {
        case TranscriberError.http(let status, _):
            return status == 408 || status == 429 || status >= 500
        case let e as URLError:
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed].contains(e.code)
        default:
            return false
        }
    }

    private func transcribeChunkOnce(_ wavData: Data, language: String, token: String,
                                     prompt: String) async throws -> String {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "Authorization")   // raw JWT, not "Bearer"
        req.timeoutInterval = 20   // matches Flow's twentySecondTimeout for this endpoint
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "audio": wavData.base64EncodedString(), "language": language, "prompt": prompt,
        ])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw TranscriberError.badResponse }
        guard http.statusCode == 200 else {
            throw TranscriberError.http(status: http.statusCode,
                                        body: String(decoding: data, as: UTF8.self))
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.content ?? ""
    }
}
