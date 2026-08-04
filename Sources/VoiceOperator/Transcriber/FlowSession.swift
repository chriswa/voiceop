import Foundation
import GRPC
import NIOCore
import NIOHPACK
import FlowAPI

/// One live dictation on Wispr's **primary** transcription path: the duplex
/// `flow_api.v1.TranscriptionService/TranscribeStream` RPC.
///
/// This is the whole point of the rewrite. Wispr Flow opens this stream the
/// instant the trigger key goes down — concurrently with acquiring the
/// microphone, before a single sample exists — and then pushes every audio packet
/// up it as the packets are encoded (`sendAudioPackets` on each 40 ms chunk in
/// the app bundle). When the key is released it sends the last packets with
/// `commit: TRUE` and closes the request stream. By that point the server has
/// already transcribed everything except the final fraction of a second, so the
/// only latency the user perceives is the tail plus the LLM formatting pass.
///
/// The unary `Transcribe` RPC this app used to call is, in Wispr's own client,
/// only the **fallback** (`makeHttpRequest`, reached when the stream errors or a
/// heartbeat times out). Calling it as the primary meant no audio moved until the
/// key came up, so server-side ASR time scaled with clip length and landed
/// entirely after the user stopped talking.
///
/// Message shape, mirroring `processPendingRequest`:
///   • first request  — `init` (metadata + preferences) + `context`, `commit: FALSE`
///   • each subsequent — `payload.audio_packets`, `commit: FALSE`
///   • final          — remaining packets, `commit: TRUE`, then close the request stream
///
/// Responses arrive continuously and are of three kinds, handled the way Wispr's
/// `handleResponse` does: `heartbeat` (server progress/ack — never a result),
/// `state` (running raw/formatted text), and `result` (final; `result.output` is
/// what gets pasted).
actor FlowSession {
    typealias Call = GRPCAsyncBidirectionalStreamingCall<FlowApi_V1_Request, FlowApi_V1_Response>

    /// Wispr's fixed opus frame is 20 ms, so one packet is 20 ms of audio.
    private static let packetSeconds = OpusEncoder.frameSeconds

    /// Hang guard on the post-commit wait, after which the caller falls back to
    /// `/llm/asr`. Not a latency budget: on the streaming path the server already
    /// holds nearly all the audio at commit time, so a healthy dictation answers
    /// in well under a second. This only exists so a wedged stream cannot leave
    /// the user staring at a "transcribing" indicator forever.
    static let defaultCommitTimeout: Duration = .seconds(15)

    private let call: Call
    private let trace: DictationTrace?
    private let consumer: Task<String, Error>

    private var initMessage: FlowApi_V1_Init?
    private var contextMessage: FlowApi_V1_Context?
    private var committed = false
    private var closed = false
    private var packetsSent = 0
    private var bytesSent = 0

    /// Sends are chained rather than fired concurrently: audio packet order is
    /// load-bearing, and an actor `await` is a reentrancy point, so two callers
    /// racing into `send` could otherwise interleave frames on the wire.
    private var writeChain: Task<Void, Never>?
    private var writeFailure: Error?

    // MARK: - Open

    /// Opens the stream and immediately sends `init` + `context`, so the server
    /// starts setting up while the microphone is still warming.
    static func open(words: [String],
                     token: String,
                     apiKey: String,
                     app: FlowApi_V1_App,
                     trace: DictationTrace?) async throws -> FlowSession {
        var headers = HPACKHeaders()
        headers.add(name: "authorization", value: "Bearer \(token)")
        headers.add(name: "baseten-authorization", value: "Api-Key \(apiKey)")
        headers.add(name: "baseten-model-id", value: "model-\(FlowChannel.modelId)")
        headers.add(name: "x-baseten-environment", value: "production")
        headers.add(name: "disable-formatting", value: "false")
        var options = CallOptions(customMetadata: headers)
        // Wispr's STREAM_TIMEOUT. Generous by design: this bounds the whole
        // dictation, not the response, and its own dictation cap is 21 minutes.
        options.timeLimit = .timeout(.minutes(20))

        let client = try FlowChannel.shared.client()
        let call = client.makeTranscribeStreamCall(callOptions: options)
        trace?.mark("stream-open")
        let session = FlowSession(call: call,
                                  initMessage: Self.makeInit(words: words),
                                  contextMessage: Self.makeContext(app: app),
                                  trace: trace)
        await session.sendHandshake()
        return session
    }

    private init(call: Call,
                 initMessage: FlowApi_V1_Init,
                 contextMessage: FlowApi_V1_Context,
                 trace: DictationTrace?) {
        self.call = call
        self.initMessage = initMessage
        self.contextMessage = contextMessage
        self.trace = trace
        self.consumer = Self.makeConsumer(call: call, trace: trace)
    }

    /// The `init`/`context` request, sent on its own so the server can start work
    /// before any audio exists. Mirrors Wispr setting `pendingInit` in
    /// `startGrpcStream` and letting the queue worker flush it right away.
    private func sendHandshake() {
        guard let initMessage, let contextMessage else { return }
        var request = FlowApi_V1_Request()
        request.init_p = initMessage
        request.context = contextMessage
        request.commit = .false
        self.initMessage = nil
        self.contextMessage = nil
        enqueue(request, mark: "init-sent")
    }

    // MARK: - Streaming audio

    /// Push freshly encoded packets. Returns immediately; the write is chained
    /// behind any previous one so ordering on the wire is guaranteed.
    func send(packets: [Data]) {
        guard !committed, !closed, writeFailure == nil, !packets.isEmpty else { return }
        var request = FlowApi_V1_Request()
        request.payload = Self.payload(packets)
        request.commit = .false
        if let initMessage, let contextMessage {
            request.init_p = initMessage
            request.context = contextMessage
            self.initMessage = nil
            self.contextMessage = nil
        }
        packetsSent += packets.count
        bytesSent += packets.reduce(0) { $0 + $1.count }
        enqueue(request, mark: packetsSent == packets.count ? "first-audio-sent" : nil)
    }

    /// Seconds of audio handed to the server so far — the number that says how
    /// much work is already done when the key comes up.
    var audioSecondsSent: Double { Double(packetsSent) * Self.packetSeconds }

    // MARK: - Commit

    /// Send the final packets with `commit: TRUE`, close the request stream, and
    /// wait for the server's result.
    ///
    /// `timeout` bounds only the post-commit wait. It is not a latency budget —
    /// it is a hang guard, after which the caller falls back to `/llm/asr`.
    func commit(packets: [Data], timeout: Duration) async throws -> String {
        do {
            return try await performCommit(packets: packets, timeout: timeout)
        } catch {
            // Any failure — a queued write that already errored, the terminator
            // itself failing, or no result inside the hang guard — must tear the
            // RPC down. grpc-swift 1.x's response-stream delegate has an empty
            // `didTerminate()`, so simply dropping the stream leaks it (and its
            // consumer task) until the 20-minute time limit expires.
            cancel()
            throw error
        }
    }

    private func performCommit(packets: [Data], timeout: Duration) async throws -> String {
        guard !committed else { throw TranscriberError.badResponse }
        committed = true

        var request = FlowApi_V1_Request()
        if !packets.isEmpty {
            request.payload = Self.payload(packets)
            packetsSent += packets.count
            bytesSent += packets.reduce(0) { $0 + $1.count }
        }
        if let initMessage, let contextMessage {
            request.init_p = initMessage
            request.context = contextMessage
            self.initMessage = nil
            self.contextMessage = nil
        }
        request.commit = .true

        // Flush the ordered backlog before the commit message, or the server
        // would see the terminator ahead of audio it has not read yet.
        let pending = writeChain
        writeChain = nil
        _ = await pending?.value
        if let writeFailure { throw writeFailure }

        trace?.mark("commit")
        trace?.note(String(format: "%ld packets, %.1f KB, %.1fs audio uploaded",
                           packetsSent, Double(bytesSent) / 1024, audioSecondsSent))

        // The terminator send is inside the guarded window too. Under HTTP/2
        // flow-control backpressure (a server that has stopped reading) it can
        // suspend for as long as the RPC lives, which is exactly the wedge the
        // guard exists to break.
        let text = try await sendTerminatorAndAwaitResult(request, timeout: timeout)
        trace?.mark("result")
        // Tear the RPC down explicitly even on success. Abandoning the response
        // stream is *not* enough: grpc-swift 1.x's `GRPCAsyncSequenceProducerDelegate`
        // implements `didTerminate()` as a no-op, so the stream would stay open on
        // the shared warm connection until its 20-minute time limit. Wispr does the
        // same thing (`close()` → `shutdownStream()`) and ignores the resulting
        // CANCELLED, which nothing here awaits.
        cancel()
        return text
    }

    /// Abandon the stream (dictation dismissed, or we're giving up and falling
    /// back). Safe to call more than once.
    func cancel() {
        guard !closed else { return }
        closed = true
        writeChain?.cancel()
        writeChain = nil
        consumer.cancel()
        call.cancel()
    }

    // MARK: - Plumbing

    private func enqueue(_ request: FlowApi_V1_Request, mark: String?) {
        let previous = writeChain
        writeChain = Task { [weak self] in
            _ = await previous?.value
            await self?.write(request, mark: mark)
        }
    }

    private func write(_ request: FlowApi_V1_Request, mark: String?) async {
        guard writeFailure == nil, !closed else { return }
        do {
            try await call.requestStream.send(request)
            if let mark { trace?.mark(mark) }
        } catch {
            writeFailure = error
            Log.log("flow: stream write failed: \(error)")
        }
    }

    /// Send the `commit: TRUE` terminator, close the request stream, and wait for
    /// the server's result — the whole thing bounded by `timeout`.
    ///
    /// The cancellation handler is load-bearing, not decoration. `consumer` is an
    /// *unstructured* Task, and `await someTask.value` does not propagate the
    /// awaiting task's cancellation into it; a task group also drains its remaining
    /// children before rethrowing. Without the handler the timeout child would
    /// throw, then the group would sit waiting for a consumer nothing can complete
    /// — so the hang guard would itself hang, and dictation would freeze until the
    /// 20-minute RPC limit rather than falling back after `timeout`.
    private func sendTerminatorAndAwaitResult(_ terminator: FlowApi_V1_Request,
                                              timeout: Duration) async throws -> String {
        let call = self.call
        let consumer = self.consumer
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await call.requestStream.send(terminator)
                    call.requestStream.finish()
                    return try await consumer.value
                } onCancel: {
                    consumer.cancel()
                    call.cancel()
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TranscriberError.streamTimeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TranscriberError.streamEnded }
            return first
        }
    }

    /// Drains the response stream. Mirrors Wispr's `handleResponse` ordering:
    /// heartbeats are progress only and never carry text; `state` updates the
    /// running transcript; a `result` with an `output` is final.
    private static func makeConsumer(call: Call, trace: DictationTrace?) -> Task<String, Error> {
        Task {
            var lastStateText: String?
            var sawFirstResponse = false
            for try await response in call.responseStream {
                if !sawFirstResponse {
                    sawFirstResponse = true
                    trace?.mark("first-response")
                }
                if response.hasHeartbeat {
                    // Progress only — a heartbeat never carries text. `commitAck`
                    // is the server confirming it saw the terminator, which is the
                    // cleanest single measure of network round-trip on the path.
                    if response.heartbeat.commitAck { trace?.mark("commit-ack") }
                    continue
                }
                if response.hasState {
                    if let text = Self.text(fromState: response.state) { lastStateText = text }
                }
                guard response.hasResult else { continue }
                let result = response.result
                // Check the status before the output gate: an error result may
                // carry no `output` at all, and silently skipping it would leave
                // us waiting for a result that is never coming.
                if result.status == .error {
                    throw TranscriberError.serverError("transcription returned RESULT_STATUS_ERROR")
                }
                guard result.hasOutput else { continue }
                if let times = Self.serverTimings(result) { trace?.note(times) }
                // Wispr's `llm_text || asr_text`: the formatted output, else
                // whatever the running state last gave us.
                let plaintext = result.output.plaintext
                return plaintext.isEmpty ? (lastStateText ?? "") : plaintext
            }
            // The server closed without ever sending a result.
            if let lastStateText, !lastStateText.isEmpty { return lastStateText }
            throw TranscriberError.streamEnded
        }
    }

    private static func text(fromState state: FlowApi_V1_State) -> String? {
        if state.hasFormattedText, !state.formattedText.content.isEmpty {
            return state.formattedText.content
        }
        if state.hasRawText, !state.rawText.content.isEmpty { return state.rawText.content }
        return nil
    }

    /// Server-side breakdown, so a slow dictation can be blamed on the right
    /// side of the wire: if `total` is most of our post-commit time, it's them.
    private static func serverTimings(_ result: FlowApi_V1_Result) -> String? {
        guard result.hasResponseTime else { return nil }
        let time = result.responseTime
        // Spelled out field-by-field rather than taking a Google_Protobuf_Duration
        // parameter, so this file needs no direct SwiftProtobuf import.
        func ms(_ seconds: Int64, _ nanos: Int32) -> Int {
            Int(Double(seconds) * 1000 + Double(nanos) / 1_000_000)
        }
        let asr = ms(time.transcribe.seconds, time.transcribe.nanos)
        let format = ms(time.format.seconds, time.format.nanos)
        let total = ms(time.total.seconds, time.total.nanos)
        return "server asr=\(asr)ms format=\(format)ms total=\(total)ms"
    }

    // MARK: - Request building

    private static func payload(_ packets: [Data]) -> FlowApi_V1_Payload {
        var audioPackets = FlowApi_V1_AudioPackets()
        audioPackets.items = packets
        var payload = FlowApi_V1_Payload()
        payload.audioPackets = audioPackets
        return payload
    }

    /// The `init` message: encoding/environment metadata plus the user's custom
    /// words. The dictionary rides in `preferences.vocabulary` (StaticVocabulary)
    /// — the server's real biasing channel, not a Whisper prompt hack.
    static func makeInit(words: [String]) -> FlowApi_V1_Init {
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

        var initMessage = FlowApi_V1_Init()
        initMessage.metadata = meta
        initMessage.preferences = prefs
        return initMessage
    }

    static func makeContext(app: FlowApi_V1_App) -> FlowApi_V1_Context {
        var context = FlowApi_V1_Context()
        context.app = app
        return context
    }

    /// The app the transcript is destined for. Wispr sends the real frontmost app
    /// and the server uses it for tone; we send whatever the arbiter captured.
    static func app(bundleIdentifier: String?, name: String?) -> FlowApi_V1_App {
        var app = FlowApi_V1_App()
        app.name = name ?? "Terminal"
        app.bundleID = bundleIdentifier ?? "com.apple.Terminal"
        app.type = .other
        return app
    }
}
