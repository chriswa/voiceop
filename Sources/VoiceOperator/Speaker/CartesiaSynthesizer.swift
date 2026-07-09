import Foundation

/// Cartesia TTS (DESIGN.md). Primary path is the SSE endpoint (`/tts/sse`), which
/// streams raw `pcm_f32le` chunks so playback starts on the first chunk;
/// `TTSEngine` accumulates the chunks and caches the finished clip for free
/// replay. The one-shot bytes endpoint (`/tts/bytes`, complete WAV) remains as a
/// fallback. Both share one request body, differing only in URL + `output_format`:
///
///     POST https://api.cartesia.ai/tts/{sse,bytes}
///     Authorization: Bearer <CARTESIA_API_KEY>
///     Cartesia-Version: 2025-11-04
///     { model_id, transcript, voice:{mode:"id",id}, output_format, generation_config, language }
///
/// SSE responds with `data: <json>\n\n` frames (base64 PCM in `data`, terminated
/// by a `done` frame). Matches cartesia-read's model (sonic-3) and volume (1.5).
/// API key comes from the CARTESIA_API_KEY env var, else cartesia-read's .env.
struct CartesiaSynthesizer: SpeechSynthesizer {
    private let bytesEndpoint = URL(string: "https://api.cartesia.ai/tts/bytes")!
    private let sseEndpoint = URL(string: "https://api.cartesia.ai/tts/sse")!
    private let model = "sonic-3"
    private let volume = 1.5
    /// Sample rate of both paths' PCM (44100 Hz mono). See `Speaker.swift`.
    static let sampleRate = 44100

    // MARK: - Streaming (SSE)

    /// Stream `pcm_f32le` audio over Cartesia's SSE endpoint. Response frames are
    /// `data: <json>\n\n`; chunk frames carry base64 PCM in `data`, the stream
    /// ends with a `done` frame, and an error frame throws `SpeakerError.synthesis`.
    /// The whole HTTP read + decode runs off the main actor inside the producer.
    func synthesizeStream(text: String, voiceID: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let apiKey = Self.resolveAPIKey() else { throw SpeakerError.noAPIKey }
                    let req = makeRequest(
                        url: sseEndpoint, apiKey: apiKey, text: text, voiceID: voiceID,
                        outputFormat: ["container": "raw", "encoding": "pcm_f32le",
                                       "sample_rate": Self.sampleRate])
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                        throw SpeakerError.http(
                            status: (resp as? HTTPURLResponse)?.statusCode ?? -1, body: "")
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }   // skip blank framing lines
                        let json = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                        guard let frame = try? JSONDecoder().decode(SSEFrame.self, from: Data(json.utf8))
                        else { continue }
                        if frame.type == "error" {
                            throw SpeakerError.synthesis(frame.message ?? frame.title ?? "unknown error")
                        }
                        if let b64 = frame.data, let pcm = Data(base64Encoded: b64) {
                            continuation.yield(pcm)
                        }
                        if frame.done == true { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A single SSE frame; only the fields we act on are decoded.
    private struct SSEFrame: Decodable {
        let type: String?
        let data: String?
        let done: Bool?
        let title: String?
        let message: String?
    }

    // MARK: - One-shot WAV (fallback)

    func synthesizeWAV(text: String, voiceID: String) async throws -> Data {
        guard let apiKey = Self.resolveAPIKey() else { throw SpeakerError.noAPIKey }
        var req = makeRequest(
            url: bytesEndpoint, apiKey: apiKey, text: text, voiceID: voiceID,
            outputFormat: ["container": "wav", "encoding": "pcm_s16le",
                           "sample_rate": Self.sampleRate])
        req.setValue("audio/wav", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw SpeakerError.http(status: status, body: String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }

    // MARK: - Shared request

    /// Build the common Cartesia TTS request; the two endpoints differ only in
    /// URL and `output_format` (WAV/s16le for bytes, raw/f32le for SSE).
    private func makeRequest(url: URL, apiKey: String, text: String, voiceID: String,
                             outputFormat: [String: Any]) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("2025-11-04", forHTTPHeaderField: "Cartesia-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model_id": model,
            "transcript": text,
            "voice": ["mode": "id", "id": voiceID],
            "output_format": outputFormat,
            "generation_config": ["volume": volume],
            "language": "en",
        ])
        return req
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
