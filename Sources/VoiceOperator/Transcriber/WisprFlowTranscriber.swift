import Foundation
import FlowAPI

/// Wispr-parity dictation over the **primary** transcription path: the duplex
/// gRPC `flow_api.v1.TranscriptionService/TranscribeStream` on Baseten, which
/// returns server-side *formatted* text (with the user's `dictionary_context`)
/// — unlike the raw `/llm/asr` fallback. Reverse-engineered from the Wispr Flow
/// app bundle; see `proto/flow_api_v1.proto`, `spike/flow_request.md`, and
/// DESIGN.md Milestone C.
///
///   host   model-<modelId>.grpc.api.baseten.co:443 (TLS, one warm connection —
///          see `FlowChannel`)
///   rpc    /flow_api.v1.TranscriptionService/TranscribeStream  (bidirectional;
///          audio uploads while the user speaks, `commit` closes it — see
///          `FlowSession`)
///   auth   authorization: Bearer <wispr jwt>
///          baseten-authorization: Api-Key <wispr's baseten key>
///          baseten-model-id / x-baseten-environment / disable-formatting: false
///
/// Two entry points:
///
///   • `openLiveSession` — what live dictation uses. The arbiter calls it the
///     instant the trigger key goes down, then streams packets into the session.
///   • `transcribe(wavData:)` — stored clips (history retry, the debug CLI). Also
///     a stream, just one that gets all its audio at once. It is deliberately
///     *not* cut into 28 s segments any more: the old code issued one sequential
///     unary call per segment, each with its own TLS handshake, which is why a
///     50 s clip took ten seconds and a four-minute one took thirty. A stream has
///     no such limit (Wispr's own dictation cap is 21 minutes), so one session
///     handles the whole clip.
///
/// Falls back to `WisprTranscriber` (raw `/llm/asr`) when the Baseten key is
/// absent or the stream fails, so dictation always degrades gracefully. That
/// fallback is a genuine failure path, not the normal one — if the log shows it
/// running routinely, something is broken.
struct WisprFlowTranscriber: LiveTranscriber {
    static var modelId: String { FlowChannel.modelId }
    static var host: String { FlowChannel.host }

    /// How much audio to put in one request message when replaying a stored clip.
    /// Only affects framing on the wire — every send goes down the same stream.
    private static let replayChunkSeconds: Double = 10

    private let fallback: WisprTranscriber
    private let dictionary: DictionaryContextProviding

    init(fallback: WisprTranscriber = WisprTranscriber(),
         dictionary: DictionaryContextProviding = WisprDictionary.shared) {
        self.fallback = fallback
        self.dictionary = dictionary
    }

    // MARK: - Live dictation

    func openLiveSession(app: FlowAppTarget, trace: DictationTrace?) async throws -> FlowSession {
        guard let apiKey = WisprBasetenKey.value else { throw TranscriberError.noBasetenKey }
        let token = try await WisprToken.shared.accessToken()
        trace?.mark("token")
        let words = await dictionary.contextWords()
        trace?.mark("dictionary")
        return try await FlowSession.open(
            words: words,
            token: token,
            apiKey: apiKey,
            app: FlowSession.app(bundleIdentifier: app.bundleIdentifier, name: app.name),
            trace: trace)
    }

    func transcribeWithoutStreaming(wavData: Data, language: String) async throws -> String {
        try await fallback.transcribe(wavData: wavData, language: language)
    }

    // MARK: - Stored clips

    /// `language` is honoured on the fallback path only. The reverse-engineered
    /// gRPC proto has an unresolved `Language` enum, so the flow request sends no
    /// language and lets the server detect it. This app is English-only, so
    /// detection is reliable and the formatted result is worth it.
    func transcribe(wavData: Data, language: String) async throws -> String {
        let wav = try WAVFile.parse(wavData)
        guard WisprBasetenKey.value != nil else {
            Log.log("flow: no Baseten key — using raw /llm/asr")
            return try await fallback.transcribe(wavData: wavData, language: language)
        }
        do {
            let text = try await replay(wav)
            Log.log("flow: stream ok — \(text.count) chars")
            return text
        } catch {
            Log.log("flow: stream failed (\(TranscriberError.userMessage(for: error))) — falling back to /llm/asr")
            return try await fallback.transcribe(wavData: wavData, language: language)
        }
    }

    /// Push a whole stored clip through one streaming session.
    private func replay(_ wav: WAVFile) async throws -> String {
        let trace = DictationTrace("replay")
        defer { trace.flush() }
        let session = try await openLiveSession(app: FlowAppTarget(), trace: trace)
        do {
            let encoder = try OpusEncoder()
            let packets = try encoder.encode(pcm: wav.samples).packets
            let perChunk = max(1, Int(Self.replayChunkSeconds / OpusEncoder.frameSeconds))

            // Everything but the last chunk streams ahead of the commit, exactly as
            // a live dictation would, so the server can start before we finish
            // sending.
            var index = 0
            while packets.count - index > perChunk {
                await session.send(packets: Array(packets[index ..< index + perChunk]))
                index += perChunk
            }
            trace.note(String(format: "%.1fs clip, %ld packets", wav.duration, packets.count))
            return try await session.commit(packets: Array(packets[index...]),
                                            timeout: FlowSession.defaultCommitTimeout)
        } catch {
            // Encoding blew up after the stream was already open — don't leak it.
            await session.cancel()
            throw error
        }
    }
}
