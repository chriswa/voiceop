import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import FlowAPI

/// Wispr-parity dictation over the **primary** transcription path: the gRPC
/// `flow_api.v1.TranscriptionService` on Baseten, which returns server-side
/// *formatted* text (with the user's `dictionary_context`) — unlike the raw
/// `/llm/asr` fallback. Reverse-engineered from the Wispr Flow app bundle; see
/// `proto/flow_api_v1.proto`, `spike/flow_request.md`, and DESIGN.md Milestone C.
///
///   host   model-<modelId>.grpc.api.baseten.co:443 (TLS)
///   rpc    /flow_api.v1.TranscriptionService/Transcribe   (unary; we send a
///          complete clip per call and commit to get the formatted result)
///   auth   authorization: Bearer <wispr jwt>
///          baseten-authorization: Api-Key <wispr's baseten key>
///          baseten-model-id / x-baseten-environment / disable-formatting: false
///
/// Falls back to `WisprTranscriber` (`/llm/asr`) when the Baseten key is absent
/// or the gRPC call fails, so dictation always degrades gracefully.
struct WisprFlowTranscriber: Transcriber {
    static let modelId = "v31pl413"                       // It.RT in the bundle
    static let host = "model-\(modelId).grpc.api.baseten.co"

    var liveChunkSeconds: Double { WisprTranscriber.chunkSeconds }

    private let fallback: WisprTranscriber
    private let dictionary: DictionaryContextProviding

    init(fallback: WisprTranscriber = WisprTranscriber(),
         dictionary: DictionaryContextProviding = WisprDictionary.shared) {
        self.fallback = fallback
        self.dictionary = dictionary
    }

    func transcribe(wavData: Data, language: String) async throws -> String {
        guard let apiKey = WisprBasetenKey.value else {
            return try await fallback.transcribe(wavData: wavData, language: language)
        }
        do {
            return try await transcribeViaFlow(wavData: wavData, language: language, apiKey: apiKey)
        } catch {
            Log.log("flow: gRPC failed (\(TranscriberError.userMessage(for: error))) — falling back to /llm/asr")
            return try await fallback.transcribe(wavData: wavData, language: language)
        }
    }

    private func transcribeViaFlow(wavData: Data, language: String, apiKey: String) async throws -> String {
        let token = try await WisprToken.shared.accessToken()
        let words = await dictionary.contextWords()
        let wav = try WAVFile.parse(wavData)
        let audio = try OpusEncoder().encode(pcm: wav.samples)

        let request = Self.buildRequest(packets: audio.packets, words: words, token: token)
        let metadata: Metadata = [
            "authorization": "Bearer \(token)",
            "baseten-authorization": "Api-Key \(apiKey)",
            "baseten-model-id": "model-\(Self.modelId)",
            "x-baseten-environment": "production",
            "disable-formatting": "false",
        ]

        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: Self.host, port: 443),
            transportSecurity: .tls()
        )
        return try await withGRPCClient(transport: transport) { grpc in
            let service = FlowApi_V1_TranscriptionService.Client(wrapping: grpc)
            let response = try await service.transcribe(request, metadata: metadata)
            return Self.text(from: response)
        }
    }

    /// Build a complete one-shot flow request (all packets + commit), mirroring
    /// Wispr's `serializeFlowRequest`/protobuf builder. The dictionary rides in
    /// `init.preferences.vocabulary` (StaticVocabulary) — the real biasing channel.
    static func buildRequest(packets: [Data], words: [String], token: String) -> FlowApi_V1_Request {
        var meta = FlowApi_V1_Metadata()
        meta.audioEncoding = .opus
        meta.environment = .production
        meta.sessionID = UUID().uuidString
        meta.requestID = UUID().uuidString
        var client = FlowApi_V1_Client()
        client.name = "Voice Operator"
        client.platform = .macos
        meta.client = client

        var vocab = FlowApi_V1_StaticVocabulary()
        vocab.dictionaryPersonal = words
        var prefs = FlowApi_V1_Preferences()
        prefs.vocabulary = vocab

        var initMsg = FlowApi_V1_Init()
        initMsg.metadata = meta
        initMsg.preferences = prefs

        var app = FlowApi_V1_App()
        app.name = "Terminal"
        app.bundleID = "com.apple.Terminal"
        app.type = .other
        var context = FlowApi_V1_Context()
        context.app = app

        var audioPackets = FlowApi_V1_AudioPackets()
        audioPackets.items = packets
        var payload = FlowApi_V1_Payload()
        payload.audioPackets = audioPackets

        var request = FlowApi_V1_Request()
        request.init_p = initMsg
        request.context = context
        request.payload = payload
        request.commit = FlowApi_V1_Commit(rawValue: 1) ?? .unspecified   // COMMIT_TRUE
        return request
    }

    /// Prefer the formatted transcript; fall back to raw. Mirrors Wispr's
    /// `llm_text || asr_text`.
    static func text(from response: FlowApi_V1_Response) -> String {
        if response.hasResult, !response.result.output.plaintext.isEmpty {
            return response.result.output.plaintext
        }
        if response.hasState {
            if response.state.hasFormattedText, !response.state.formattedText.content.isEmpty {
                return response.state.formattedText.content
            }
            if response.state.hasRawText { return response.state.rawText.content }
        }
        return ""
    }
}
