import Foundation

/// Kokoro TTS (kokoro-82m) over HTTP (DESIGN.md). The streaming path
/// (`POST /synthesize`) returns a single `audio/wav` body — a 44-byte PCM WAV
/// header (with placeholder `0xffffffff` sizes, since the length isn't knowable
/// up front) followed by raw **s16le PCM, mono, 24000 Hz**, flushed as it's
/// generated so playback can start on the first chunk:
///
///     POST <base>/synthesize
///     Content-Type: application/json
///     { "text": <string>, "voice": <voice id>, "speed": <0.5–2.0> }
///
/// Always the Kokoro server Voice Operator runs on this Mac (`KokoroService`),
/// at `baseURL`. There is deliberately no way to point it anywhere else: what
/// is spoken never leaves the machine.
///
/// To fit the app's f32le streaming pipeline (`TTSEngine`/`PCMReframer`), this
/// strips the WAV header and converts the s16le samples to `pcm_f32le` before
/// yielding them. Unlike Cartesia there is no API key and no volume control.
struct KokoroSynthesizer: SpeechSynthesizer {
    /// The local Kokoro. An IPv4 literal, not `localhost`: the server binds
    /// 127.0.0.1 only, and `localhost` would try `::1` first.
    static let baseURL = "http://127.0.0.1:56841"
    /// Kokoro's own default voice, used when a caller names none.
    static let defaultVoiceID = "af_heart"
    /// Ephemeral: nothing about a request reaches the disk. The shared session
    /// keeps an HTTP cache in ~/Library/Caches, which stored every request's text,
    /// the word timings and the audio itself — found leaking an incognito
    /// sentence, and never wanted in any mode (`AudioCache` is the TTS cache).
    static let session = URLSession(configuration: .ephemeral)

    /// Kokoro's native output rate (s16le, mono). See `TTSEngine.streamFormat`.
    let sampleRate = 24_000

    /// How often a synthesis that has not finished reports where it is stuck.
    private static let stallReportSeconds = 15
    /// When to stop waiting altogether and cancel the request.
    ///
    /// A backstop, not the usual exit: `URLRequest.timeoutInterval` does fire on
    /// the stall seen in the wild, and the observed clip died at 30.3s. This has
    /// to sit above that so the timeout — which names its own cause — gets first
    /// refusal, and above a retry of the same, so it only catches a stall the
    /// URL loading system somehow does not. Cancelling throws, which the
    /// existing error path already turns into a failed job the caller can see.
    private static let stallHardCapSeconds = 90
    /// Generation speed passed to Kokoro; 1.2 is the server's own default.
    private let speed = 1.2
    /// Bytes of leading WAV header to drop from the `/synthesize` body. Kokoro
    /// always emits a canonical 44-byte PCM header (RIFF/WAVE/fmt /data).
    private static let wavHeaderSize = 44

    /// The small, provider-neutral catalogue exposed by Voice Operator's local
    /// API. Kokoro's response has varied between builds, so accept both a bare
    /// string list and objects carrying an `id`/`name` field.
    static func availableVoiceIDs() async throws -> [String] {
        var req = URLRequest(url: endpoint("voices"))
        req.httpMethod = "GET"
        req.timeoutInterval = 30
        let (data, response) = try await Self.session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SpeakerError.synthesis("voice list unavailable")
        }
        try rejectNonJSON(http)
        if let strings = try? JSONSerialization.jsonObject(with: data) as? [String] { return strings.sorted() }
        if let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return objects.compactMap { ($0["id"] ?? $0["name"]) as? String }.sorted()
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let voices = object["voices"] as? [String] { return voices.sorted() }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let voices = object["voices"] as? [[String: Any]] {
            return voices.compactMap { ($0["id"] ?? $0["name"]) as? String }.sorted()
        }
        throw SpeakerError.synthesis("unrecognized voice list")
    }

    // MARK: - Streaming

    /// Stream `pcm_f32le` audio from `/synthesize`. The response body is a
    /// header-prefixed WAV whose bytes arrive incrementally; we drop the header,
    /// then convert each run of whole s16le samples to f32le and yield it. A
    /// single 16-bit sample can straddle two network reads, so a trailing odd
    /// byte is carried into the next chunk.
    func synthesizeStream(text: String, voiceID: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let label = Log.clip(text)
            let progress = StreamProgress()
            let startedAt = Date()
            let task = Task {
                do {
                    Log.log("kokoro \(label): requesting \(Self.endpoint("synthesize").absoluteString)")
                    do {
                        try await self.streamOnce(text: text, voiceID: voiceID, label: label,
                                                  progress: progress, startedAt: startedAt,
                                                  into: continuation)
                    } catch {
                        // Retry once, and only while nothing has reached the player:
                        // a half-delivered clip cannot be restarted without repeating
                        // audio the listener already heard.
                        //
                        // The failure this covers has been observed in the wild — a
                        // request that delivers not one byte, times out at 30s, and
                        // costs the listener the entire answer, on a service that
                        // answers a fresh request in a couple of seconds either side
                        // of it. Whatever the cause, a second attempt is far more
                        // likely to be heard than the silence it replaces.
                        guard progress.yieldedNothing, !(error is CancellationError) else { throw error }
                        Log.log("kokoro \(label): nothing delivered in \(Log.elapsed(since: startedAt)) (\(error)); retrying once")
                        progress.enter("retrying")
                        try await self.streamOnce(text: text, voiceID: voiceID, label: label,
                                                  progress: progress, startedAt: startedAt,
                                                  into: continuation)
                    }
                    progress.complete("finished")
                    Log.log("kokoro \(label): complete in \(Log.elapsed(since: startedAt)) — \(progress.snapshot)")
                    continuation.finish()
                } catch {
                    progress.complete("failed")
                    Log.log("kokoro \(label): failed after \(Log.elapsed(since: startedAt)) — \(progress.snapshot): \(error)")
                    continuation.finish(throwing: error)
                }
            }
            // Reports where a synthesis is stuck while it is still stuck, rather
            // than leaving the whole stretch invisible. Cancelling at the hard cap
            // makes the producer throw, which is a failure mode the callers
            // already handle — unlike an indefinite park, which none of them do.
            let watchdog = Task {
                var waited = 0
                while !progress.isFinished {
                    try? await Task.sleep(for: .seconds(Self.stallReportSeconds))
                    if progress.isFinished || Task.isCancelled { return }
                    waited += Self.stallReportSeconds
                    Log.log("kokoro \(label): STALLED \(waited)s — \(progress.snapshot)")
                    if waited >= Self.stallHardCapSeconds {
                        Log.log("kokoro \(label): giving up after \(waited)s; cancelling the request")
                        task.cancel()
                        return
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel(); watchdog.cancel() }
        }
    }

    /// One attempt at streaming the clip, yielding decoded chunks as they arrive.
    ///
    /// Separate from `synthesizeStream` so that a failed attempt which delivered
    /// nothing can simply be run again, rather than the retry having to
    /// reproduce the request, the validation and the framing.
    private func streamOnce(text: String, voiceID: String, label: String,
                            progress: StreamProgress, startedAt: Date,
                            into continuation: AsyncThrowingStream<Data, Error>.Continuation) async throws {
        progress.enter("awaiting response")
        let (bytes, resp) = try await Self.session.bytes(for: makeRequest(text: text, voiceID: voiceID))
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw SpeakerError.http(status: (resp as? HTTPURLResponse)?.statusCode ?? -1, body: "")
        }
        try Self.requireAudioContentType(http)
        Log.log("kokoro \(label): HTTP 200 after \(Log.elapsed(since: startedAt))")
        progress.enter("reading body")
        var headerRemaining = Self.wavHeaderSize
        var s16 = [UInt8]()
        s16.reserveCapacity(8192)
        var firstChunk = true
        for try await byte in bytes {
            if headerRemaining > 0 { headerRemaining -= 1; continue }
            s16.append(byte)
            // Flush on a whole-sample boundary once we've buffered a playable
            // chunk; keep any dangling odd byte for next time.
            if s16.count >= 4096, s16.count % 2 == 0 {
                let pcm = Self.f32le(fromS16le: s16)
                progress.advance(pcm.count)
                if firstChunk {
                    firstChunk = false
                    Log.log("kokoro \(label): first audio chunk after \(Log.elapsed(since: startedAt))")
                }
                continuation.yield(pcm)
                s16.removeAll(keepingCapacity: true)
            }
        }
        if s16.count % 2 != 0 { s16.removeLast() }   // drop a trailing partial sample
        if !s16.isEmpty {
            let pcm = Self.f32le(fromS16le: s16)
            progress.advance(pcm.count)
            continuation.yield(pcm)
        }
    }

    // MARK: - One-shot WAV (fallback)

    func synthesizeWAV(text: String, voiceID: String) async throws -> Data {
        let (data, resp) = try await Self.session.data(for: makeRequest(text: text, voiceID: voiceID))
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw SpeakerError.http(status: status, body: String(decoding: data.prefix(300), as: UTF8.self))
        }
        try Self.requireAudioContentType(http)
        // The server's streaming header carries placeholder (0xffffffff) sizes,
        // which `AVAudioPlayer` can't derive a duration from. Rebuild a canonical
        // WAV from the real sample bytes instead of replaying the raw body.
        guard data.count > Self.wavHeaderSize else { throw SpeakerError.synthesis("no audio") }
        let samples = data.subdata(in: Self.wavHeaderSize..<(data.count - (data.count - Self.wavHeaderSize) % 2))
        return WAVFile(sampleRate: sampleRate, samples: samples).data
    }

    // MARK: - Word timings

    private struct TimingsResponse: Decodable {
        let words: [Word]
        struct Word: Decodable { let word: String; let start: Double; let end: Double }
    }

    /// Fetch per-word timings from Kokoro's `/timestamps` endpoint (same body as
    /// `/synthesize`). A separate call from the audio stream on purpose — see the
    /// endpoint's own note — so it never touches the byte-exact PCM path.
    func wordTimings(text: String, voiceID: String) async throws -> [WordTiming] {
        var req = URLRequest(url: Self.endpoint("timestamps"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "text": text, "voice": voiceID, "speed": speed,
        ])
        let (data, resp) = try await Self.session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw SpeakerError.http(status: (resp as? HTTPURLResponse)?.statusCode ?? -1, body: "")
        }
        let decoded = try JSONDecoder().decode(TimingsResponse.self, from: data)
        return decoded.words.map { WordTiming(word: $0.word, start: $0.start, end: $0.end) }
    }

    // MARK: - Shared request / URL helpers

    private func makeRequest(text: String, voiceID: String) -> URLRequest {
        var req = URLRequest(url: Self.endpoint("synthesize"))
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

    static func endpoint(_ path: String) -> URL {
        // Safe to force-unwrap: a compile-time constant and a fixed path.
        URL(string: "\(baseURL)/\(path)")!
    }

    /// Reject Cloudflare Access (and similar) HTML login pages that arrive as
    /// HTTP 200 after `URLSession` follows a 302. Without this guard the app
    /// strips 44 bytes as a WAV header and plays the remaining HTML as PCM noise.
    static func requireAudioContentType(_ http: HTTPURLResponse) throws {
        let mime = mediaType(of: http)
        guard mime.hasPrefix("audio/") else {
            let shown = mime.isEmpty ? "(missing)" : mime
            throw SpeakerError.synthesis("expected audio response, got Content-Type: \(shown)")
        }
    }

    private static func rejectNonJSON(_ http: HTTPURLResponse) throws {
        let mime = mediaType(of: http)
        // Some local Kokoro builds omit Content-Type; accept that. Reject HTML
        // (Access login) and other clearly-wrong types.
        if mime.isEmpty { return }
        if mime.contains("json") || mime.hasPrefix("text/plain") { return }
        throw SpeakerError.synthesis("expected JSON voice list, got Content-Type: \(mime)")
    }

    private static func mediaType(of http: HTTPURLResponse) -> String {
        let raw = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        return raw.split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            ?? ""
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

/// Cross-task progress for one `synthesizeStream` call.
///
/// The producer advances it; a sibling watchdog task reads it. Lock-guarded
/// rather than actor-isolated so the watchdog can sample it without awaiting the
/// very task it is trying to prove is stuck.
private final class StreamProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var stage = "connecting"
    private var chunks = 0
    private var pcmBytes = 0
    private var done = false

    func enter(_ newStage: String) { lock.lock(); stage = newStage; lock.unlock() }
    func advance(_ byteCount: Int) { lock.lock(); chunks += 1; pcmBytes += byteCount; lock.unlock() }
    func complete(_ newStage: String) { lock.lock(); stage = newStage; done = true; lock.unlock() }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return done }
    /// Whether a failed attempt can be safely retried: nothing has been handed
    /// to the player yet, so starting over repeats no audio.
    var yieldedNothing: Bool { lock.lock(); defer { lock.unlock() }; return chunks == 0 }
    var snapshot: String {
        lock.lock(); defer { lock.unlock() }
        return "stage=\(stage) chunks=\(chunks) pcmBytes=\(pcmBytes)"
    }
}
