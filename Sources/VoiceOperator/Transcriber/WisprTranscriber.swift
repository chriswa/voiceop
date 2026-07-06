import Foundation

/// Wispr Flow speech-to-text over the proven HTTP path (DESIGN.md, Milestone A):
///
///     POST https://api.wisprflow.ai/llm/asr
///     Authorization: <raw access token>        (NOT "Bearer …")
///     Content-Type: application/json
///     { "audio": base64(16 kHz mono WAV), "language": "en", "prompt": "" }
///     -> 200 { "content": "<transcript>", "detected_language": "en" }
///
/// The endpoint enforces a ~20 s server-side processing budget (it answers
/// HTTP 408 beyond it), so it can only ever transcribe a short clip. Wispr Flow
/// handles this by cutting dictations into 28-second chunks
/// (`basetenChunkSizeSeconds` in the Flow app) and, on its HTTP fallback path,
/// POSTing each chunk to /llm/asr in order, joining the per-chunk transcripts
/// with spaces. We replicate exactly that: fixed 28 s cuts, sequential
/// requests, space-joined result.
///
/// This is Whisper-backed; output is already punctuated/capitalized. The richer
/// context-aware "flow request" path (dictionary/proper-noun formatting) is a
/// later enhancement — see DESIGN.md Milestone C.
struct WisprTranscriber: Transcriber {
    private let endpoint = URL(string: "https://api.wisprflow.ai/llm/asr")!

    /// Wispr Flow's chunk size (`basetenChunkSizeSeconds` in the Flow app).
    static let chunkSeconds: Double = 28
    var liveChunkSeconds: Double { Self.chunkSeconds }

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
        // Same joining rule as Flow's prevAsrText(): drop empty chunks, one space between.
        return texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func transcribeChunk(_ wavData: Data, language: String, token: String) async throws -> String {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "Authorization")
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
