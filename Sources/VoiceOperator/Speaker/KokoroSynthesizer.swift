import Foundation

/// Kokoro TTS (kokoro-82m), a local HTTP server (DESIGN.md). The streaming path
/// (`POST /synthesize`) returns a single `audio/wav` body — a 44-byte PCM WAV
/// header (with placeholder `0xffffffff` sizes, since the length isn't knowable
/// up front) followed by raw **s16le PCM, mono, 24000 Hz**, flushed as it's
/// generated so playback can start on the first chunk:
///
///     POST http://localhost:56841/synthesize
///     Content-Type: application/json
///     { "text": <string>, "voice": <voice id>, "speed": <0.5–2.0> }
///
/// To fit the app's f32le streaming pipeline (`TTSEngine`/`PCMReframer`), this
/// strips the WAV header and converts the s16le samples to `pcm_f32le` before
/// yielding them. Unlike Cartesia there is no API key and no volume control.
/// Override the base URL with `$VOICEOP_KOKORO_URL` (default the local server).
struct KokoroSynthesizer: SpeechSynthesizer {
    /// Kokoro's native output rate (s16le, mono). See `TTSEngine.streamFormat`.
    let sampleRate = 24_000
    /// Generation speed passed to Kokoro; 1.2 is the server's own default.
    private let speed = 1.2
    /// Bytes of leading WAV header to drop from the `/synthesize` body. Kokoro
    /// always emits a canonical 44-byte PCM header (RIFF/WAVE/fmt /data).
    private static let wavHeaderSize = 44

    private static let defaultBaseURL = "http://localhost:56841"

    private var synthesizeURL: URL {
        let base = ProcessInfo.processInfo.environment["VOICEOP_KOKORO_URL"]
            .flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultBaseURL
        return URL(string: base.hasSuffix("/") ? "\(base)synthesize" : "\(base)/synthesize")!
    }

    // MARK: - Streaming

    /// Stream `pcm_f32le` audio from `/synthesize`. The response body is a
    /// header-prefixed WAV whose bytes arrive incrementally; we drop the header,
    /// then convert each run of whole s16le samples to f32le and yield it. A
    /// single 16-bit sample can straddle two network reads, so a trailing odd
    /// byte is carried into the next chunk.
    func synthesizeStream(text: String, voiceID: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, resp) = try await URLSession.shared.bytes(for: makeRequest(text: text, voiceID: voiceID))
                    guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                        throw SpeakerError.http(
                            status: (resp as? HTTPURLResponse)?.statusCode ?? -1, body: "")
                    }
                    var headerRemaining = Self.wavHeaderSize
                    var s16 = [UInt8]()
                    s16.reserveCapacity(8192)
                    for try await byte in bytes {
                        if headerRemaining > 0 { headerRemaining -= 1; continue }
                        s16.append(byte)
                        // Flush on a whole-sample boundary once we've buffered a
                        // playable chunk; keep any dangling odd byte for next time.
                        if s16.count >= 4096, s16.count % 2 == 0 {
                            continuation.yield(Self.f32le(fromS16le: s16))
                            s16.removeAll(keepingCapacity: true)
                        }
                    }
                    if s16.count % 2 != 0 { s16.removeLast() }   // drop a trailing partial sample
                    if !s16.isEmpty { continuation.yield(Self.f32le(fromS16le: s16)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - One-shot WAV (fallback)

    func synthesizeWAV(text: String, voiceID: String) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: makeRequest(text: text, voiceID: voiceID))
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw SpeakerError.http(status: status, body: String(decoding: data.prefix(300), as: UTF8.self))
        }
        // The server's streaming header carries placeholder (0xffffffff) sizes,
        // which `AVAudioPlayer` can't derive a duration from. Rebuild a canonical
        // WAV from the real sample bytes instead of replaying the raw body.
        guard data.count > Self.wavHeaderSize else { throw SpeakerError.synthesis("no audio") }
        let samples = data.subdata(in: Self.wavHeaderSize..<(data.count - (data.count - Self.wavHeaderSize) % 2))
        return WAVFile(sampleRate: sampleRate, samples: samples).data
    }

    // MARK: - Shared request

    private func makeRequest(text: String, voiceID: String) -> URLRequest {
        var req = URLRequest(url: synthesizeURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "text": text,
            "voice": voiceID,
            "speed": speed,
        ])
        return req
    }

    // MARK: - PCM conversion

    /// Convert little-endian s16 sample bytes to native `pcm_f32le` in [-1, 1).
    /// `bytes.count` must be even (a whole number of samples).
    private static func f32le(fromS16le bytes: [UInt8]) -> Data {
        let n = bytes.count / 2
        var out = Data(count: n * 4)
        out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let dst = raw.bindMemory(to: Float.self)
            for i in 0..<n {
                let sample = Int16(bitPattern: UInt16(bytes[2 * i]) | (UInt16(bytes[2 * i + 1]) << 8))
                dst[i] = Float(sample) / 32768.0
            }
        }
        return out
    }
}
