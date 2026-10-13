import Foundation

/// Wispr Flow speech-to-text over the proven HTTP path (DESIGN.md, Milestone A):
///
///     POST https://api.wisprflow.ai/llm/asr
///     Authorization: <raw access token>        (NOT "Bearer …")
///     Content-Type: application/json
///     { "audio": base64(16 kHz mono WAV), "language": "en", "prompt": "" }
///     -> 200 { "content": "<transcript>", "detected_language": "en" }
///
/// The `prompt` is intentionally **always empty** here. This endpoint is raw
/// Whisper, and Whisper's `prompt` is not a spelling dictionary — it is
/// autoregressive "previous transcript" context the model conditions on.
/// Stuffing it with the user's custom-word list (as we briefly did) backfires:
/// on quiet/short chunks Whisper regurgitates the prompt verbatim, injects the
/// listed words when they were never spoken, over-corrects common words toward
/// them, and silently truncates past its 224-token window. Proper-noun spelling
/// belongs on the flow-request path instead (`/llm/asr_audio_chunks` with a real
/// `dictionary_context`) — see DESIGN.md Milestone C — which is a purpose-built
/// biasing channel rather than a context hack. Do not route `WisprDictionary`
/// into this prompt.
///
/// The endpoint enforces a ~20 s server-side processing budget (it answers
/// HTTP 408 beyond it), so it can only ever transcribe a short clip. Wispr Flow
/// handles this by cutting dictations into 28-second chunks
/// (`basetenChunkSizeSeconds` in the Flow app) and POSTing each chunk to
/// /llm/asr in order, joining the per-chunk transcripts with spaces. We
/// replicate exactly that: fixed 28 s cuts, sequential requests, space-joined
/// result.
struct WisprTranscriber {
    private let endpoint = URL(string: "https://api.wisprflow.ai/llm/asr")!

    /// Wispr Flow's chunk size (`basetenChunkSizeSeconds` in the Flow app). Only
    /// this raw HTTP path needs it — the streaming gRPC path has no such limit.
    static let chunkSeconds: Double = 28

    private struct Response: Decodable {
        let content: String?
        let detected_language: String?
    }

    func transcribe(wavData: Data, language: String) async throws -> String {
        let token = try await WisprToken.shared.accessToken()
        let wav = try WAVFile.parse(wavData)
        let chunks = wav.segments(maxSeconds: Self.chunkSeconds)
        if chunks.count > 1 {
            Log.log(String(format: "transcribe: %.1fs clip → %d chunks of ≤%.0fs",
                           wav.duration, chunks.count, Self.chunkSeconds))
        }
        var texts: [String] = []
        for (i, chunk) in chunks.enumerated() {
            do {
                texts.append(try await transcribeChunk(chunk.data, language: language, token: token))
            } catch {
                if chunks.count > 1 { Log.log("transcribe: chunk \(i + 1)/\(chunks.count) failed") }
                throw error
            }
        }
        return Self.joinChunkTexts(texts)
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

    private func transcribeChunk(_ wavData: Data, language: String, token: String) async throws -> String {
        for attempt in 1... {
            do { return try await transcribeChunkOnce(wavData, language: language, token: token) }
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

    private func transcribeChunkOnce(_ wavData: Data, language: String, token: String) async throws -> String {
        try Incognito.check(.network("Wispr Flow"))
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "Authorization")   // raw JWT, not "Bearer"
        req.timeoutInterval = 20   // matches Flow's twentySecondTimeout for this endpoint
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "audio": wavData.base64EncodedString(), "language": language, "prompt": "",
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
