import Foundation
import Network

/// Loopback-only HTTP/1.1 facade for the speech queue. It deliberately has no
/// authentication: the service chooses a private ephemeral port and publishes it
/// only in the current user's Application Support directory.
final class SpeechHTTPService: @unchecked Sendable {
    static let discoveryURL = HistoryStore.supportDir.appendingPathComponent("speech-service.json")
    /// Bumped when the API grows, so a client reading the discovery file can tell
    /// what it is talking to. 2 added `/v1/status` and `/v1/restart`; 3 added the
    /// `stream` / `stream_reason` fields to `/v1/status`; 4 added `speaking`,
    /// which now defers a restart just as `dictating` does; 5 added remote
    /// transcription (`/v1/transcriptions`, `remote_transcription` in status);
    /// 6 added remote synthesis (`/v1/synthesize`); 7 added multi-voice
    /// `parts` on `POST /v1/speech`; 8 added `/v1/wake-word`.
    static let discoveryVersion = 8
    private var listener: NWListener?

    /// What `/v1/status` reports: which build this is and what it is doing.
    struct Snapshot: Sendable {
        var status: OperatorStatus
        var dictating: Bool
        /// Whether speech is audible. Like `dictating`, this holds off a restart —
        /// `restart-app.sh` reads it to say which of the two it is waiting on.
        var speaking: Bool
        var restart: RestartCoordinator.State
        /// Which transcription path dictation is on. `restart-app.sh` reads this
        /// after every restart so a slow-path Mac is caught at build time, not
        /// after a week of mysteriously slow dictation (see `StreamHealth`).
        var stream: StreamHealth
        /// Remote transcriptions in flight. Like `dictating`, these hold off a
        /// restart — a phone mid-sentence would otherwise lose what it said.
        var remoteTranscriptions: Int

        var object: [String: Any] {
            var o: [String: Any] =
                ["version": BuildInfo.version, "build": BuildInfo.build, "commit": BuildInfo.commit,
                 "pid": Int(ProcessInfo.processInfo.processIdentifier),
                 "status": status.rawValue, "dictating": dictating, "speaking": speaking,
                 "restart": restart.wireName,
                 "stream": stream.wireName,
                 "remote_transcription": true, "remote_transcriptions": remoteTranscriptions]
            if let reason = stream.reason { o["stream_reason"] = reason }
            return o
        }
    }
    /// Wired by `AppCoordinator`; both run on the main actor because that is where
    /// dictation state lives and where the restart decision must be made.
    var snapshot: (@MainActor @Sendable () -> Snapshot)?
    var requestRestart: (@MainActor @Sendable () -> RestartCoordinator.State)?

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(IPv4Address("127.0.0.1")!), port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            if case .ready = state, let port = listener?.port { self?.publish(port: port) }
            if case let .failed(error) = state { Log.log("speech HTTP listener failed: \(error)") }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    func stop() { listener?.cancel(); listener = nil; try? FileManager.default.removeItem(at: Self.discoveryURL) }
    private func publish(port: NWEndpoint.Port) {
        let payload: [String: Any] = ["version": Self.discoveryVersion, "port": Int(port.rawValue), "pid": ProcessInfo.processInfo.processIdentifier]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: Self.discoveryURL, options: .atomic)
        Log.log("speech HTTP listening on loopback port \(port.rawValue)")
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receive(connection, data: Data())
    }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, complete, error in
            guard let self else { return }
            var all = data; if let chunk { all.append(chunk) }
            if let request = Self.parse(all) {
                Task { let response = await self.handle(request); self.respond(response, on: connection) }
            } else if all.count > 1_048_576 || complete || error != nil {
                self.respond(.init(status: 400, object: ["error": "bad_request"]), on: connection)
            } else { self.receive(connection, data: all) }
        }
    }

    private struct Request { let method: String; let path: String; let query: [String: String]; let body: Data }
    /// `object` nil means no body (204).
    /// `raw`, when set, is the body as-is with its content type — audio — in place of `object`.
    private struct Response {
        let status: Int; let object: [String: Any]?; var raw: (data: Data, contentType: String)? = nil
    }
    private static func parse(_ data: Data) -> Request? {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<headEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first?.split(separator: " "), first.count >= 2,
              let components = URLComponents(string: String(first[1])) else { return nil }
        let length = lines.dropFirst().first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        let bodyStart = headEnd.upperBound
        guard data.count >= bodyStart + length else { return nil }
        return Request(method: String(first[0]), path: components.path,
                       query: Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }),
                       body: data.subdata(in: bodyStart..<(bodyStart + length)))
    }
    private func handle(_ r: Request) async -> Response {
        if r.method == "GET", r.path == "/v1/status" {
            guard let snapshot else { return .init(status: 503, object: ["error": "status_unavailable"]) }
            return .init(status: 200, object: await snapshot().object)
        }
        // Ask the app to restart itself. Immediate when idle (200); deferred until
        // the dictation in flight has been pasted, or the speech the user is
        // listening to has finished (202). Repeating the request is harmless. See
        // RestartCoordinator for why the app, not the caller, decides.
        if r.method == "POST", r.path == "/v1/restart" {
            guard let requestRestart else { return .init(status: 503, object: ["error": "restart_unavailable"]) }
            switch await requestRestart() {
            case .pending:
                // Name which of the two it is, so the script can say so rather
                // than telling the user they are dictating when they are listening.
                let state = await snapshot?()
                let reason = state.map { s in
                    s.dictating ? "dictating" : !s.speaking && s.remoteTranscriptions > 0 ? "remote_transcription" : "speaking"
                } ?? "dictating"
                return .init(status: 202, object: ["restart": "pending", "reason": reason])
            case .restarting: return .init(status: 200, object: ["restart": "restarting"])
            case .none: return .init(status: 500, object: ["error": "restart_not_recorded"])
            }
        }
        if let route = TranscriptionRoute(method: r.method, path: r.path) {
            return await handle(route, body: r.body)
        }
        // Hands-free: is this short clip the wake word, alone? Raw s16le mono
        // PCM in, `?word=control&sample_rate=16000`. On-device only — see
        // WakeWordCheck for why this never touches Wispr.
        if r.path == "/v1/wake-word" {
            guard r.method == "POST" else { return .init(status: 405, object: ["error": "method_not_allowed"]) }
            let word = r.query["word"] ?? "control"
            let rate = Int(r.query["sample_rate"] ?? "") ?? PCM16Resampler.outputRate
            guard !r.body.isEmpty, r.body.count % 2 == 0 else { return .init(status: 400, object: ["error": "pcm_required"]) }
            do {
                let result = try await WakeWordCheck.check(pcm: r.body, sampleRate: rate, word: word)
                return .init(status: 200, object: ["match": result.match, "heard": result.heard, "elapsed_ms": result.elapsedMs])
            } catch WakeWordCheck.Failure.unavailable {
                return .init(status: 501, object: ["error": "wake_word_unavailable", "detail": "needs macOS 26 (SpeechTranscriber)"])
            } catch {
                Log.log("wake word: check failed: \(error)")
                return .init(status: 500, object: ["error": "wake_word_failed", "detail": "\(error)"])
            }
        }
        if r.method == "GET", r.path == "/v1/voices" {
            do { return .init(status: 200, object: ["provider": "kokoro", "default_voice": "af_heart", "voices": try await KokoroSynthesizer.availableVoiceIDs().map { ["id": $0] }]) }
            catch { return .init(status: 503, object: ["error": "tts_unavailable"]) }
        }
        // Remote synthesis: the audio for one piece of text, handed back rather
        // than played — for a client that plays it elsewhere (the phone, via
        // spaceterm). No queue, no playback, no ducking: the caller owns all of
        // that. The mirror of `/v1/transcriptions`, and like it the reason is
        // that this process holds the synthesizer's address and credentials.
        //
        // The text goes through `TTSPreprocess` first, as speech played here
        // does, so a path or a camelCase name sounds the same on the phone.
        //
        // With `"word_timings": true` the answer is JSON instead: the WAV as
        // base64 `audio`, and `words`, each word's `start`/`end` in seconds and
        // `character_end`, the UTF-16 offset in `text` just past it. That is
        // what lets the client say which word a listener cut in on, exactly as
        // `character_offset` does for speech played here. `words` is absent
        // when the timings could not be had or aligned; the audio still is.
        if r.method == "POST", r.path == "/v1/synthesize" {
            guard let o = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any],
                  let text = o["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .init(status: 400, object: ["error": "text_required"]) }
            guard text.unicodeScalars.count <= 5_000 else { return .init(status: 422, object: ["error": "text_too_long"]) }
            let voice = o["voice"] as? String ?? "af_heart"
            let synthesizer = KokoroSynthesizer()
            let prepared = TTSPreprocess.prepare(text)
            do {
                guard o["word_timings"] as? Bool == true else {
                    let wav = try await synthesizer.synthesizeWAV(text: prepared.ttsText, voiceID: voice)
                    Log.log("remote synthesis: \(text.count) chars as \(wav.count) bytes, voice=\(voice)")
                    return .init(status: 200, object: nil, raw: (wav, "audio/wav"))
                }
                async let timings = try? synthesizer.wordTimings(text: prepared.ttsText, voiceID: voice)
                let wav = try await synthesizer.synthesizeWAV(text: prepared.ttsText, voiceID: voice)
                let words = await timings.flatMap { Self.wordObjects(prepared: prepared, timings: $0) }
                Log.log("remote synthesis: \(text.count) chars as \(wav.count) bytes, voice=\(voice), \(words.map { "\($0.count) timed words" } ?? "untimed")")
                var answer: [String: Any] = ["audio": wav.base64EncodedString()]
                if let words { answer["words"] = words }
                return .init(status: 200, object: answer)
            } catch {
                Log.log("remote synthesis failed: \(error)")
                return .init(status: 502, object: ["error": "synthesis_failed", "detail": "\(error)"])
            }
        }
        if r.method == "POST", r.path == "/v1/speech" {
            let parts: [SpeechJobManager.Part]
            switch SpeechRequestBody.parts(from: r.body) {
            case .success(let parsed): parts = parsed
            case .failure(let rejection): return .init(status: rejection.status, object: rejection.object)
            }
            guard let result = await SpeechJobManager.shared.enqueue(parts: parts) else { return .init(status: 503, object: ["error": "speech_unavailable"]) }
            if result.error == "speech_muted" { return .init(status: 503, object: ["error": "speech_muted"]) }
            return .init(status: 202, object: object(result))
        }
        let components = r.path.split(separator: "/")
        guard components.count == 3, components[1] == "speech" else { return .init(status: 404, object: ["error": "not_found"]) }
        let id = String(components[2])
        if r.method == "DELETE" {
            guard let result = await SpeechJobManager.shared.cancel(id: id) else { return .init(status: 404, object: ["error": "unknown_job"]) }
            return .init(status: status(result), object: object(result))
        }
        if r.method == "GET" {
            let wait = min(30, max(0, UInt64(r.query["wait"] ?? "0") ?? 0))
            // `since` is opt-in: without it a long poll keeps its original
            // terminal-only meaning, so existing callers are unaffected.
            let since = r.query["since"].flatMap { Int($0) }
            guard let result = wait > 0 ? await SpeechJobManager.shared.wait(id: id, seconds: wait, since: since) : await SpeechJobManager.shared.liveResult(id: id) else { return .init(status: 404, object: ["error": "unknown_job"]) }
            return .init(status: status(result), object: object(result))
        }
        return .init(status: 405, object: ["error": "method_not_allowed"])
    }
    /// `words` for a timed `/v1/synthesize`: Kokoro times the prepared text, and
    /// each word is mapped back to where it ends in the text as sent — a spoken
    /// "slash" ends just past the `/` it stands for.
    static func wordObjects(prepared: TTSPrepared, timings: [WordTiming]) -> [[String: Any]]? {
        return SpokenNarration.wordRanges(prepared: prepared, words: timings)?.map {
            ["start": $0.timing.start, "end": $0.timing.end, "character_end": NSMaxRange($0.range)]
        }
    }

    /// Remote dictation — see `RemoteTranscriptionManager`.
    private func handle(_ route: TranscriptionRoute, body: Data) async -> Response {
        let manager = RemoteTranscriptionManager.shared
        do {
            switch route {
            case .create:
                guard let rate = TranscriptionRoute.sampleRate(fromCreateBody: body) else {
                    return .init(status: 400, object: ["error": "invalid_body"])
                }
                return .init(status: 201, object: ["id": try await manager.create(sampleRate: rate)])
            case .audio(let id):
                try await manager.append(id: id, pcm: body)
                return .init(status: 204, object: nil)
            case .finish(let id):
                return .init(status: 200, object: ["text": try await manager.finish(id: id)])
            case .cancel(let id):
                try await manager.cancel(id: id)
                return .init(status: 204, object: nil)
            case .methodNotAllowed:
                return .init(status: 405, object: ["error": "method_not_allowed"])
            }
        } catch let failure as RemoteTranscriptionManager.Failure {
            switch failure {
            case .unknownSession: return .init(status: 404, object: ["error": "unknown_transcription"])
            case .alreadyFinished: return .init(status: 409, object: ["error": "transcription_finished"])
            case .unsupportedSampleRate: return .init(status: 422, object: ["error": "unsupported_sample_rate"])
            case .upstream(let message, let unavailable):
                return .init(status: unavailable ? 503 : 502, object: ["error": "transcription_failed", "detail": message])
            }
        } catch {
            return .init(status: 500, object: ["error": "internal_error", "detail": "\(error)"])
        }
    }
    private func object(_ r: SpeechJobManager.Result) -> [String: Any] {
        ["id": r.id, "state": r.state.rawValue, "playback_state": r.playbackState?.rawValue as Any,
         "character_offset": r.characterOffset, "error": r.error as Any, "version": r.version]
    }
    private func status(_ r: SpeechJobManager.Result) -> Int {
        switch r.state { case .completed: return 200; case .interruptedByUser: return 409; case .cancelledByClient: return 410; case .synthesisFailed: return 500; default: return 202 }
    }
    private func respond(_ r: Response, on c: NWConnection) {
        let body = r.raw?.data ?? r.object.map { (try? JSONSerialization.data(withJSONObject: $0)) ?? Data("{}".utf8) } ?? Data()
        let reason = HTTPURLResponse.localizedString(forStatusCode: r.status)
        var head = "HTTP/1.1 \(r.status) \(reason)\r\n"
        if let raw = r.raw { head += "Content-Type: \(raw.contentType)\r\n" }
        else if r.object != nil { head += "Content-Type: application/json\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n"
        if r.status == 202 { head += "Retry-After: 1\r\n" }
        head += "\r\n"
        var out = Data(head.utf8); out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}

/// The `/v1/transcriptions` routes, split out of the handler so routing and body
/// parsing are testable without a socket.
enum TranscriptionRoute: Equatable {
    case create
    case audio(String)
    case finish(String)
    case cancel(String)
    /// A transcription path with the wrong method.
    case methodNotAllowed

    /// nil for any path outside `/v1/transcriptions`.
    init?(method: String, path: String) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard parts.count >= 2, parts[0] == "v1", parts[1] == "transcriptions" else { return nil }
        switch (method, parts.count) {
        case ("POST", 2): self = .create
        case (_, 2): self = .methodNotAllowed
        case ("DELETE", 3) where !parts[2].isEmpty: self = .cancel(parts[2])
        case (_, 3) where !parts[2].isEmpty: self = .methodNotAllowed
        case ("POST", 4) where !parts[2].isEmpty && parts[3] == "audio": self = .audio(parts[2])
        case ("POST", 4) where !parts[2].isEmpty && parts[3] == "finish": self = .finish(parts[2])
        case (_, 4) where !parts[2].isEmpty && (parts[3] == "audio" || parts[3] == "finish"): self = .methodNotAllowed
        default: return nil
        }
    }

    /// The create body is optional JSON `{"sample_rate": N}`; empty means 16 kHz.
    /// nil for a body that is present but not that shape.
    static func sampleRate(fromCreateBody body: Data) -> Int? {
        if body.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return PCM16Resampler.outputRate }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        guard let value = object["sample_rate"] else { return PCM16Resampler.outputRate }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let rate = Int(exactly: number.doubleValue) else { return nil }
        return rate
    }
}

/// The `POST /v1/speech` body, split out of the handler so validation is
/// testable without a socket. Two shapes, exactly one of which a body uses:
///
///     {"text": "...", "voice": "af_heart"}                    // one voice
///     {"parts": [{"text": "...", "voice": "am_adam"}, ...]}  // several, one job
///
/// A missing voice falls back to `defaultVoice` in either shape.
enum SpeechRequestBody {
    static let defaultVoice = "af_heart"
    /// Applies to the job's whole text — for `parts`, the joined text.
    static let maxScalars = 50_000

    struct Rejection: Error, Equatable {
        let status: Int
        let error: String
        /// The offending part, for errors about one part.
        var index: Int? = nil
        var object: [String: Any] {
            var o: [String: Any] = ["error": error]
            if let index { o["index"] = index }
            return o
        }
    }

    static func parts(from body: Data) -> Swift.Result<[SpeechJobManager.Part], Rejection> {
        guard let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return .failure(Rejection(status: 400, error: "text_required"))
        }
        let parts: [SpeechJobManager.Part]
        switch (o["text"], o["parts"]) {
        case (.some, .some):
            return .failure(Rejection(status: 400, error: "text_and_parts_exclusive"))
        case (_, .some(let raw)):
            guard let list = raw as? [Any] else { return .failure(Rejection(status: 400, error: "parts_invalid")) }
            guard !list.isEmpty else { return .failure(Rejection(status: 400, error: "parts_empty")) }
            var parsed: [SpeechJobManager.Part] = []
            for (index, item) in list.enumerated() {
                guard let part = item as? [String: Any],
                      let text = part["text"] as? String, !isBlank(text) else {
                    return .failure(Rejection(status: 400, error: "part_text_required", index: index))
                }
                parsed.append(.init(text: text, voice: part["voice"] as? String ?? defaultVoice))
            }
            parts = parsed
        case (let raw, nil):
            guard let text = raw as? String, !isBlank(text) else { return .failure(Rejection(status: 400, error: "text_required")) }
            parts = [.init(text: text, voice: o["voice"] as? String ?? defaultVoice)]
        }
        guard SpeechJobManager.Part.joined(parts).unicodeScalars.count <= maxScalars else {
            return .failure(Rejection(status: 422, error: "text_too_long"))
        }
        return .success(parts)
    }

    private static func isBlank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
