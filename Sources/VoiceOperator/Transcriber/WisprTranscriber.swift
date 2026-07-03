import Foundation

/// Wispr Flow speech-to-text over the proven HTTP path (DESIGN.md, Milestone A):
///
///     POST https://api.wisprflow.ai/llm/asr
///     Authorization: <raw access token>        (NOT "Bearer …")
///     Content-Type: application/json
///     { "audio": base64(16 kHz mono WAV), "language": "en", "prompt": "" }
///     -> 200 { "content": "<transcript>", "detected_language": "en" }
///
/// This is Whisper-backed; output is already punctuated/capitalized. The richer
/// context-aware "flow request" path (dictionary/proper-noun formatting) is a
/// later enhancement — see DESIGN.md Milestone C.
struct WisprTranscriber: Transcriber {
    private let endpoint = URL(string: "https://api.wisprflow.ai/llm/asr")!

    private struct Response: Decodable {
        let content: String?
        let detected_language: String?
    }

    func transcribe(wavURL: URL, language: String) async throws -> String {
        let token = try await WisprToken.shared.accessToken()
        let audioB64 = try Data(contentsOf: wavURL).base64EncodedString()

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "audio": audioB64, "language": language, "prompt": "",
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
