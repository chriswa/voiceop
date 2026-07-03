import Foundation

/// Cartesia TTS via the one-shot bytes endpoint (DESIGN.md, chosen over WS so we
/// get a complete WAV to cache and replay for free):
///
///     POST https://api.cartesia.ai/tts/bytes
///     Authorization: Bearer <CARTESIA_API_KEY>
///     Cartesia-Version: 2025-11-04
///     Accept: audio/wav
///     { model_id, transcript, voice:{mode:"id",id}, output_format, generation_config, language }
///
/// Matches cartesia-read's model (sonic-3) and volume (1.5). API key comes from
/// the CARTESIA_API_KEY env var, else cartesia-read's .env.
struct CartesiaSynthesizer: SpeechSynthesizer {
    private let endpoint = URL(string: "https://api.cartesia.ai/tts/bytes")!
    private let model = "sonic-3"
    private let volume = 1.5
    private let sampleRate = 44100

    func synthesizeWAV(text: String, voiceID: String) async throws -> Data {
        guard let apiKey = Self.resolveAPIKey() else { throw SpeakerError.noAPIKey }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("2025-11-04", forHTTPHeaderField: "Cartesia-Version")
        req.setValue("audio/wav", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model_id": model,
            "transcript": text,
            "voice": ["mode": "id", "id": voiceID],
            "output_format": ["container": "wav", "encoding": "pcm_s16le",
                              "sample_rate": sampleRate],
            "generation_config": ["volume": volume],
            "language": "en",
        ])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw SpeakerError.http(status: status, body: String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }

    // MARK: - API key

    static func resolveAPIKey() -> String? {
        if let key = ProcessInfo.processInfo.environment["CARTESIA_API_KEY"], !key.isEmpty {
            return key
        }
        let envPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent("chriswa-devkit/tools/cartesia-read/.env")
        guard let contents = try? String(contentsOfFile: envPath, encoding: .utf8) else { return nil }
        for line in contents.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "CARTESIA_API_KEY" {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
