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
///   • `openSession` — what live dictation uses. The arbiter calls it the
///     instant the trigger key goes down, then streams PCM into the session,
///     which opus-encodes it (`WisprFlowSession`).
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
struct WisprFlowProvider: TranscriptionProvider {
    static var modelId: String { FlowChannel.modelId }
    static var host: String { FlowChannel.host }

    let id = TranscriptionProviderID.wisprFlow
    let fallbackLabel = "raw /llm/asr"

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

    func prewarm() async -> String? {
        FlowChannel.shared.warmUp()
        Task { await WisprToken.shared.prewarm() }
        Task { _ = await dictionary.contextWords() }
        return WisprBasetenKey.value == nil ? TranscriberError.noBasetenKey.userMessage : nil
    }

    // MARK: - Live dictation

    func openSession(target: DictationTarget, trace: DictationTrace?) async throws -> any TranscriptionSession {
        // Nudge the pooled connection in case it dropped while the Mac slept.
        FlowChannel.shared.warmUp()
        let packetizer = try OpusPacketizer()
        let flow = try await openFlowSession(target: target, trace: trace)
        return WisprFlowSession(flow: flow, packetizer: packetizer)
    }

    private func openFlowSession(target: DictationTarget, trace: DictationTrace?) async throws -> FlowSession {
        guard let apiKey = WisprBasetenKey.value else { throw TranscriberError.noBasetenKey }
        let token = try await WisprToken.shared.accessToken()
        trace?.mark("token")
        let words = await dictionary.contextWords()
        trace?.mark("dictionary")
        return try await FlowSession.open(
            words: words,
            token: token,
            apiKey: apiKey,
            app: FlowSession.app(bundleIdentifier: target.bundleIdentifier, name: target.name),
            trace: trace)
    }

    func transcribeAfterLiveFailure(wavData: Data) async throws -> String {
        try await fallback.transcribe(wavData: wavData, language: "en")
    }

    // MARK: - Stored clips

    /// The reverse-engineered gRPC proto has an unresolved `Language` enum, so the
    /// flow request sends no language and lets the server detect it. This app is
    /// English-only, so detection is reliable and the formatted result is worth it.
    func transcribe(wavData: Data) async throws -> String {
        let wav = try WAVFile.parse(wavData)
        guard WisprBasetenKey.value != nil else {
            Log.log("flow: no Baseten key — using raw /llm/asr")
            return try await fallback.transcribe(wavData: wavData, language: "en")
        }
        do {
            let text = try await replay(wav)
            Log.log("flow: stream ok — \(text.count) chars")
            return text
        } catch {
            Log.log("flow: stream failed (\(TranscriberError.userMessage(for: error))) — falling back to /llm/asr")
            return try await fallback.transcribe(wavData: wavData, language: "en")
        }
    }

    /// Push a whole stored clip through one streaming session.
    private func replay(_ wav: WAVFile) async throws -> String {
        let trace = DictationTrace("replay")
        defer { trace.flush() }
        let session = try await openFlowSession(target: DictationTarget(), trace: trace)
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
            // An empty stored clip has no valid array index to slice at. It is
            // still a well-formed stream commit (and lets the server decide how
            // to represent no speech), so send an empty final payload instead
            // of trapping locally before the fallback can run.
            let finalPackets = index < packets.count ? Array(packets[index...]) : []
            return try await session.commit(packets: finalPackets,
                                            timeout: FlowSession.defaultCommitTimeout)
        } catch {
            // Encoding blew up after the stream was already open — don't leak it.
            await session.cancel()
            throw error
        }
    }
}

/// A live Wispr dictation: PCM in, 20 ms opus packets up the `FlowSession`.
actor WisprFlowSession: TranscriptionSession {
    private let flow: FlowSession
    private let packetizer: OpusPacketizer
    /// An encode failure leaves a hole in the audio, so the stream's answer could
    /// only be missing words. Remembered so `commit` fails and the clip is
    /// transcribed from the recording instead.
    private var encodeFailure: Error?

    init(flow: FlowSession, packetizer: OpusPacketizer) {
        self.flow = flow
        self.packetizer = packetizer
    }

    func send(pcm: Data) async {
        guard encodeFailure == nil else { return }
        let packets: [Data]
        do { packets = try packetizer.append(pcm) }
        catch {
            Log.log("dictation: opus encode failed: \(error)")
            encodeFailure = error
            return
        }
        guard !packets.isEmpty else { return }
        await flow.send(packets: packets)
    }

    func commit(pcm: Data) async throws -> String {
        if let encodeFailure {
            await flow.cancel()
            throw encodeFailure
        }
        var tail: [Data] = []
        do { tail = try packetizer.finish(pcm) }
        catch { Log.log("dictation: final opus encode failed: \(error)") }
        return try await flow.commit(packets: tail, timeout: FlowSession.defaultCommitTimeout)
    }

    func cancel() async { await flow.cancel() }
}

/// Turns a dictation's PCM, arriving in arbitrary slices, into opus packets.
/// Only whole 20 ms frames are encoded as audio arrives; a trailing partial frame
/// is held back for the next slice, so no silence is ever spliced into the middle
/// of the stream. `finish` pads the last partial frame, which is correct there —
/// the recording really has ended. One encoder per dictation: opus is stateful
/// across frames.
final class OpusPacketizer {
    private let encoder: OpusEncoder
    private var remainder = Data()

    init() throws { encoder = try OpusEncoder() }

    func append(_ pcm: Data) throws -> [Data] {
        remainder.append(pcm)
        let (audio, consumed) = try encoder.encodeWholeFrames(pcm: remainder)
        remainder = Data(remainder.dropFirst(consumed))
        return audio.packets
    }

    func finish(_ pcm: Data) throws -> [Data] {
        remainder.append(pcm)
        defer { remainder = Data() }
        guard !remainder.isEmpty else { return [] }
        return try encoder.encode(pcm: remainder).packets
    }
}
