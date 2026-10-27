import Foundation
import Network

/// Hands-free as a service: clients connect, register a trigger word, and turn
/// hands-free on — on the Mac's microphone, or on a stream of audio they send
/// (a phone, through Voice Operator's iOS SDK). Nothing listens until a client
/// asks, and nothing outlives the connection that asked.
///
/// The protocol is newline-delimited JSON over a Unix socket in Application
/// Support (`hands-free.sock`, named in `speech-service.json` as
/// `hands_free_socket`); DESIGN.md "Hands-free" has it in full. In short:
///
/// - A **control** connection says `hello` with its client name and trigger
///   word, then `start` (`source: "mac"`) or `stop`. It may say `playing` while
///   it plays sound of its own on the Mac, which hands-free does not listen
///   through.
/// - A **stream** connection says `hello` with `role: "stream"` for a client
///   already registered, then `start` (or `resume` after a dropout), `audio`,
///   `playing`, and `stop`. It is the phone's whole session.
/// - A **speaker** connection says `hello` with `role: "speaker"` and a
///   device name, for speech played on that device (`DeviceSpeech`): it is
///   sent `sentence`s and `ended`, and says `progress`. No trigger word or
///   control connection needed.
/// - Voice Operator sends each session's `state`, `gauge`, `cue`, `duck`,
///   `cut-in`, `transcript` and `session-ended` to the connection that started
///   it, and `ack`s stream audio.
///
/// One session per client: starting one ends the client's other. The Mac's
/// microphone is one source shared by every client that started a session on
/// it, so each client's trigger word works there; a stream is its own source.
///
/// Every call into the engines happens on `queue`.
final class HandsFreeService: @unchecked Sendable {
    static let shared = HandsFreeService()
    static let protocolVersion = 1
    static let socketURL = HistoryStore.supportDir.appendingPathComponent("hands-free.sock")
    /// A stream that drops is kept this long for the client to `resume` it.
    static let resumeWindowMs: Double = 10_000
    /// Audio a resumed stream replays from before this far back is not acted on
    /// unless a dictation was under way: it is history, not the user talking now.
    static let lateAudioMs: Double = 2_000
    /// Voice Operator's own playback reaching the microphone on speakers: after
    /// it stops, hands-free stays deaf this much longer (the room's ring-out).
    static let playbackTailMs: Double = HandsFreeTuning.standard.playbackTailMs
    static let incognitoActivity = Incognito.Activity.spaceterm("hands-free")

    let queue = DispatchQueue(label: "com.voiceop.hands-free")

    /// What the rest of the app tells hands-free, from any thread.
    let host = Host()
    /// The microphone, handed in by `AppCoordinator`: `setListener` on
    /// `AudioRecorder`, through the arbiter.
    var setMicrophoneListener: (@Sendable ((@Sendable (Data) -> Void)?) -> Void)?
    /// Whether anything is being dictated hands-free right now — a restart waits.
    var isBusy: Bool { busyLock.withLock { busyCount > 0 } }
    /// Called (on any thread) when the last busy session goes idle.
    var onIdle: (@Sendable () -> Void)?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]
    /// Registered clients by name: their control connection and trigger word.
    private var clients: [String: Client] = [:]
    private var mac: MacSource?
    private var streams: [String: StreamSession] = [:]
    /// turn-1-mini, which ends dictations: loaded at start, then set here on `queue`.
    private let miniLoader = TurnOneMini.Loader()
    private var miniModel: TurnOneMini.Model?
    private let record = HandsFreeRecord.shared
    private let busyLock = NSLock()
    private var busyCount = 0
    private var busySessions: Set<String> = []

    private struct Client {
        let name: String
        let trigger: String
        let connection: Connection
    }

    // MARK: - Host state

    /// Flags the main actor sets as dictation, speech and the output device change.
    final class Host: @unchecked Sendable {
        private let lock = NSLock()
        private var _fnDictating = false
        private var _speaking = false
        private var _speechEndedAt: Date?
        private var _speakers = false

        var fnDictating: Bool {
            get { lock.withLock { _fnDictating } }
            set { lock.withLock { _fnDictating = newValue } }
        }
        /// Voice Operator speaking.
        var speaking: Bool {
            get { lock.withLock { _speaking } }
            set { lock.withLock { if _speaking && !newValue { _speechEndedAt = Date() }; _speaking = newValue } }
        }
        /// The output is the Mac's speakers, which the microphone hears.
        var speakers: Bool {
            get { lock.withLock { _speakers } }
            set { lock.withLock { _speakers = newValue } }
        }
        /// Voice Operator speaking, or stopped within `tailMs`.
        func speakingOrRinging(tailMs: Double) -> Bool {
            lock.withLock {
                _speaking || (_speechEndedAt.map { Date().timeIntervalSince($0) * 1000 < tailMs } ?? false)
            }
        }
    }

    // MARK: - Lifecycle

    func start() throws {
        let path = Self.socketURL.path
        try? FileManager.default.removeItem(atPath: path)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] nw in
            guard let self else { return }
            let connection = Connection(nw, queue: queue)
            queue.async { self.accept(connection) }
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state { Log.log("hands-free: listening on \(path)") }
            if case let .failed(error) = state { Log.log("hands-free: socket failed: \(error)") }
        }
        listener.start(queue: queue)
        self.listener = listener
        Task { [miniLoader, queue] in
            let model = await miniLoader.model()
            queue.async { [weak self] in self?.miniModel = model }
        }
    }

    /// Voice Operator is quitting — usually to restart: `restarting` tells
    /// clients it is not their doing, so they may wait for it to come back.
    func stop() {
        queue.sync {
            for session in Array(streams.values) { end(session, why: "restarting") }
            if let mac { for client in mac.engine.clients { stopMac(client, why: "restarting") } }
            listener?.cancel()
            listener = nil
        }
        try? FileManager.default.removeItem(at: Self.socketURL)
    }

    /// Incognito turned on ends every session: whatever hands-free hears goes to
    /// a client, which incognito refuses.
    func incognitoChanged() {
        guard Incognito.isOn else { return }
        queue.async { [self] in
            for session in Array(streams.values) { end(session, why: "incognito") }
            if let mac { for client in mac.engine.clients { stopMac(client, why: "incognito") } }
        }
    }

    /// The Mac's microphone stopped delivering audio, or came back — the
    /// recorder's stall watchdog (`AudioRecorder.Delivery`). While it is
    /// stalled the source is not live, so clients see hands-free stop listening
    /// rather than an idle button over a deaf microphone; a watchdog that has
    /// given up ends the session. From any thread.
    func microphoneDelivery(_ delivery: AudioRecorder.Delivery) {
        queue.async { [self] in
            guard let mac else { return }
            switch delivery {
            case .stalled:
                Log.log("hands-free: the Mac's microphone stalled — not listening until its audio is back")
                mac.engine.sourceStopped(final: false)
            case .resumed:
                mac.engine.sourceStarted(reopened: true)
            case .gaveUp:
                for client in mac.engine.clients { stopMac(client, why: "microphone") }
            }
        }
    }

    /// For `/v1/status`: sessions by client.
    func snapshot() -> [String: Any] {
        queue.sync {
            var sessions: [[String: Any]] = []
            if let mac {
                for client in mac.engine.clients {
                    sessions.append(["client": client, "source": "mac", "phase": mac.engine.phase.rawValue])
                }
            }
            for session in streams.values {
                sessions.append(["client": session.client, "source": "stream", "device": session.device,
                                 "phase": session.engine.phase.rawValue, "connected": session.connection != nil])
            }
            return ["clients": clients.keys.sorted(), "sessions": sessions]
        }
    }

    // MARK: - Connections

    private func accept(_ connection: Connection) {
        connections[ObjectIdentifier(connection)] = connection
        connection.onMessage = { [weak self, weak connection] message in
            guard let self, let connection else { return }
            self.handle(message, from: connection)
        }
        connection.onClose = { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.closed(connection)
        }
        connection.start()
    }

    private func handle(_ message: [String: Any], from connection: Connection) {
        guard let type = message["type"] as? String else {
            connection.send(["type": "error", "error": "no_type"])
            return
        }
        if type == "hello" { hello(message, from: connection); return }
        guard let role = connection.role else {
            connection.send(["type": "error", "error": "hello_first"])
            return
        }
        switch (role, type) {
        case (.control, "start"):
            guard (message["source"] as? String ?? "mac") == "mac" else {
                connection.send(["type": "error", "error": "unknown_source"])
                return
            }
            startMac(connection.client)
        case (.control, "stop"):
            stopClient(connection.client, why: "off")
        case (.control, "playing"):
            connection.playing = message["on"] as? Bool ?? false
            if !connection.playing { connection.playingEndedAt = Date() }
        case (.stream, "start"):
            startStream(on: connection, message)
        case (.stream, "resume"):
            resumeStream(on: connection, message)
        case (.stream, "audio"):
            streamAudio(on: connection, message)
        case (.stream, "playing"):
            guard let session = connection.session else { return }
            let wasSpeech = session.playing && session.speech
            session.playing = message["on"] as? Bool ?? false
            session.speech = message["speech"] as? Bool ?? session.playing
            session.echoCancelled = message["echoCancelled"] as? Bool ?? false
            if !session.playing {
                session.playingEndedAt = Date()
                session.endedOnSpeech = wasSpeech
            }
        case (.stream, "stop"):
            if let session = connection.session { end(session, why: "off") }
        case (.speaker, "progress"):
            guard let token = connection.speaker, let id = message["id"] as? String, let index = message["index"] as? Int,
                  let event = message["event"] as? String else { return }
            DeviceSpeech.shared.progress(token, id: id, index: index, event: event)
        default:
            connection.send(["type": "error", "error": "unknown_type", "detail": type])
        }
    }

    private func hello(_ message: [String: Any], from connection: Connection) {
        func refuse(_ error: String, _ detail: String) {
            connection.send(["type": "refused", "error": error, "detail": detail])
            connection.close()
        }
        guard connection.role == nil else { refuse("already_said_hello", "one hello per connection"); return }
        guard let version = message["protocol"] as? Int, version == Self.protocolVersion else {
            refuse("protocol", "this Voice Operator speaks hands-free protocol \(Self.protocolVersion)")
            return
        }
        guard let name = message["client"] as? String, !name.isEmpty, name.count <= 64 else {
            refuse("invalid_client", "a client name of 1–64 characters")
            return
        }
        if message["role"] as? String == "speaker" {
            guard let device = message["device"] as? String, !device.isEmpty, device.count <= 128 else {
                refuse("invalid_device", "a device name of 1–128 characters")
                return
            }
            connection.role = .speaker
            connection.client = name
            connection.device = device
            let queue = self.queue
            connection.speaker = DeviceSpeech.shared.connect(client: name, device: device) { [weak connection] message in
                queue.async { connection?.send(message) }
            }
            connection.send(["type": "welcome", "protocol": Self.protocolVersion])
            return
        }
        if message["role"] as? String == "stream" {
            guard clients[name] != nil else { refuse("no_client", "\(name) has no control connection"); return }
            connection.role = .stream
            connection.client = name
            connection.device = message["device"] as? String ?? "stream"
            connection.send(["type": "welcome", "protocol": Self.protocolVersion])
            return
        }
        guard let trigger = (message["trigger"] as? String).map(HandsFreePhrases.spokenWords), trigger.count == 1 else {
            refuse("invalid_trigger", "a trigger word: one word")
            return
        }
        guard clients[name] == nil else { refuse("client_taken", "\(name) is already connected"); return }
        if let other = clients.values.first(where: { $0.trigger == trigger[0] }) {
            refuse("trigger_taken", "\"\(trigger[0])\" belongs to \(other.name)")
            return
        }
        connection.role = .control
        connection.client = name
        clients[name] = Client(name: name, trigger: trigger[0], connection: connection)
        Log.log("hands-free: \(name) registered \"\(trigger[0])\"")
        connection.send(["type": "welcome", "protocol": Self.protocolVersion])
    }

    private func closed(_ connection: Connection) {
        connections[ObjectIdentifier(connection)] = nil
        switch connection.role {
        case .control:
            guard clients[connection.client]?.connection === connection else { return }
            Log.log("hands-free: \(connection.client) disconnected")
            stopClient(connection.client, why: "disconnected")
            clients[connection.client] = nil
        case .stream:
            if let session = connection.session { suspend(session) }
        case .speaker:
            if let token = connection.speaker { DeviceSpeech.shared.disconnect(token) }
        case nil:
            break
        }
    }

    private func stopClient(_ client: String, why: String) {
        if mac?.engine.clients.contains(client) == true { stopMac(client, why: why) }
        for session in streams.values where session.client == client { end(session, why: why) }
    }

    // MARK: - The Mac's microphone

    private final class MacSource {
        let engine: HandsFreeEngine
        init(engine: HandsFreeEngine) { self.engine = engine }
    }

    private func startMac(_ client: String) {
        guard let registered = clients[client] else { return }
        if let refusal = Incognito.refusal(Self.incognitoActivity) {
            registered.connection.send(["type": "session-ended", "why": "incognito", "detail": refusal.description])
            return
        }
        // One session per client.
        for session in streams.values where session.client == client { end(session, why: "replaced") }
        if let mac {
            guard !mac.engine.clients.contains(client) else { return }
            mac.engine.addClient(client, trigger: registered.trigger)
            registered.connection.send(["type": "session", "source": "mac"])
            Log.log("hands-free: \(client) listening on the Mac's microphone too")
            return
        }
        let engine = makeEngine(owner: client, trigger: registered.trigger, sessionKey: "mac") { [weak self] outgoing in
            self?.deliverMac(outgoing)
        }
        engine.sourceState = { [weak self] in self?.macState() ?? .init() }
        mac = MacSource(engine: engine)
        registered.connection.send(["type": "session", "source": "mac"])
        Log.log("hands-free: \(client) turned it on, on the Mac's microphone")
        let queue = self.queue
        setMicrophoneListener?({ [weak self, weak engine] data in
            queue.async {
                guard let self, let engine, self.mac?.engine === engine else { return }
                engine.push(Self.samples(data))
            }
        })
        engine.sourceStarted()
    }

    private func stopMac(_ client: String, why: String) {
        guard let mac, mac.engine.clients.contains(client) else { return }
        // The engine's last word (`state` off) goes before the session's end, not after it.
        if mac.engine.clients.count == 1 { mac.engine.sourceStopped(final: true) }
        clients[client]?.connection.send(["type": "session-ended", "why": why])
        mac.engine.removeClient(client)
        guard mac.engine.clients.isEmpty else { return }
        self.mac = nil
        setBusy("mac", false)
        setMicrophoneListener?(nil)
        Log.log("hands-free: off on the Mac's microphone (\(why))")
    }

    private func macState() -> HandsFreeEngine.SourceState {
        var state = HandsFreeEngine.SourceState()
        let speaking = host.speaking
        state.voiceOperatorSpeaking = speaking
        if host.fnDictating {
            state.deaf = .init(why: "a Fn dictation", cause: .dictation)
        } else if host.speakers, host.speakingOrRinging(tailMs: Self.playbackTailMs) {
            // Without a headset the microphone hears Voice Operator, and would take it for the user.
            state.deaf = .init(why: "Voice Operator speaking on speakers", cause: .speech)
        } else if let playing = clients.values.first(where: { $0.connection.isPlaying(tailMs: Self.playbackTailMs) }) {
            state.deaf = .init(why: "\(playing.name) playing", cause: .sound)
        }
        return state
    }

    private func deliverMac(_ outgoing: HandsFreeEngine.Outgoing) {
        let targets = outgoing.client.map { [$0] } ?? (mac?.engine.clients ?? [])
        for name in targets { clients[name]?.connection.send(Self.wire(outgoing.event)) }
        if case .state(let phase, _, _, _, _, _) = outgoing.event {
            setBusy("mac", phase == .hearing || phase == .sending)
        }
        // "Let me turn this off" ends hands-free hands-free: after the words and the cue have gone.
        if case .transcript(_, _, _, _, true) = outgoing.event, let client = outgoing.client {
            queue.async { [weak self] in self?.stopMac(client, why: "shutdown") }
        }
    }

    // MARK: - Streams

    private func startStream(on connection: Connection, _ message: [String: Any]) {
        let client = connection.client
        guard let registered = clients[client] else {
            connection.send(["type": "session-ended", "why": "no_client"])
            return
        }
        if let refusal = Incognito.refusal(Self.incognitoActivity) {
            connection.send(["type": "session-ended", "why": "incognito", "detail": refusal.description])
            return
        }
        let rate = message["sampleRate"] as? Int ?? HandsFreeAudio.sampleRate
        guard (message["codec"] as? String ?? "pcm16") == "pcm16", let resampler = PCM16Resampler(inputRate: rate) else {
            connection.send(["type": "session-ended", "why": "unsupported_audio"])
            return
        }
        // One session per client.
        if mac?.engine.clients.contains(client) == true { stopMac(client, why: "replaced") }
        for other in streams.values where other.client == client { end(other, why: "replaced") }
        let id = UUID().uuidString.lowercased()
        var session: StreamSession?
        let engine = makeEngine(owner: client, trigger: registered.trigger, sessionKey: id) { [weak self] outgoing in
            guard let self, let session else { return }
            session.connection?.send(Self.wire(outgoing.event))
            if case .state(let phase, _, _, _, _, _) = outgoing.event {
                self.setBusy(id, phase == .hearing || phase == .sending)
            }
            if case .transcript(_, _, _, _, true) = outgoing.event {
                self.queue.async { [weak self, weak session] in
                    if let self, let session { self.end(session, why: "shutdown") }
                }
            }
        }
        let created = StreamSession(id: id, client: client, device: connection.device, engine: engine, resampler: resampler)
        session = created
        engine.sourceState = { [weak self, weak created] in
            guard let self, let created else { return .init() }
            return self.streamState(created)
        }
        streams[id] = created
        connection.session = created
        created.connection = connection
        connection.send(["type": "session", "source": "stream", "session": id])
        Log.log("hands-free: \(client) turned it on, streaming from \(connection.device)")
        engine.sourceStarted()
    }

    private func resumeStream(on connection: Connection, _ message: [String: Any]) {
        guard let id = message["session"] as? String, let session = streams[id], session.client == connection.client else {
            connection.send(["type": "session-ended", "why": "lost"])
            return
        }
        session.expiry?.cancel()
        session.expiry = nil
        session.connection?.session = nil
        session.connection = connection
        connection.session = session
        let away = session.droppedAt.map { Date().timeIntervalSince($0) * 1000 } ?? 0
        session.droppedAt = nil
        Log.log(String(format: "hands-free: %@ resumed its stream after %.1fs", session.device, away / 1000))
        connection.send(["type": "resumed", "session": id, "at": session.received])
        session.engine.sourceStarted(reopened: true)
        if away > Self.lateAudioMs, session.engine.phase != .hearing { session.engine.gap() }
    }

    private func streamAudio(on connection: Connection, _ message: [String: Any]) {
        guard let session = connection.session, let encoded = message["data"] as? String,
              let bytes = Data(base64Encoded: encoded) else { return }
        let converted = session.resampler.convert(bytes)
        var pcm = Self.samples(converted)
        if let at = message["at"] as? Int {
            if at + pcm.count <= session.received { return }   // already had it
            if at < session.received { pcm.removeFirst(session.received - at) }
            if at > session.received {
                // A hole the client could not fill: what was in it is gone.
                session.engine.gap()
                session.received = at
            }
        }
        session.received += pcm.count
        session.engine.push(pcm)
        if session.received - session.lastAck >= HandsFreeAudio.sampleRate {
            session.lastAck = session.received
            connection.send(["type": "ack", "at": session.received])
        }
    }

    private func streamState(_ session: StreamSession) -> HandsFreeEngine.SourceState {
        var state = HandsFreeEngine.SourceState()
        state.voiceOperatorSpeaking = host.speaking
        let ringing = session.playing
            || (session.playingEndedAt.map { Date().timeIntervalSince($0) * 1000 < Self.playbackTailMs } ?? false)
        if ringing, !session.echoCancelled {
            let speech = session.playing ? session.speech : session.endedOnSpeech
            state.deaf = .init(why: "\(session.device) playing", cause: speech ? .speech : .sound)
        } else if session.playing, session.speech {
            state.clientSpeaking = true
        }
        return state
    }

    /// The stream's connection dropped: keep the session `resumeWindowMs` for
    /// the client to come back to.
    private func suspend(_ session: StreamSession) {
        guard streams[session.id] != nil else { return }
        session.connection = nil
        session.droppedAt = Date()
        session.engine.sourceStopped(final: false)
        Log.log("hands-free: \(session.device)'s stream dropped — waiting \(Int(Self.resumeWindowMs / 1000))s for it")
        let expiry = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session, session.connection == nil else { return }
            self.end(session, why: "lost")
        }
        session.expiry = expiry
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(Self.resumeWindowMs)), execute: expiry)
    }

    private func end(_ session: StreamSession, why: String) {
        guard streams.removeValue(forKey: session.id) != nil else { return }
        session.expiry?.cancel()
        session.engine.sourceStopped(final: true)
        session.connection?.send(["type": "session-ended", "why": why])
        session.connection?.session = nil
        setBusy(session.id, false)
        Log.log("hands-free: off on \(session.device) (\(why))")
    }

    // MARK: - Engines

    private func makeEngine(owner: String, trigger: String, sessionKey: String,
                            emit: @escaping (HandsFreeEngine.Outgoing) -> Void) -> HandsFreeEngine {
        let queue = self.queue
        let record = self.record
        let deps = HandsFreeEngine.Deps(
            check: { clip, done in
                let pcm = Self.data(clip)
                let done = Unchecked(done)
                Task {
                    let answer: HandsFreeEngine.CheckAnswer
                    do {
                        let result = try await WakeWordCheck.check(pcm: pcm, sampleRate: HandsFreeAudio.sampleRate,
                                                                   word: trigger, match: .speech)
                        answer = .heard(result.heard)
                        record.write("check", ["heard": result.heard, "elapsedMs": result.elapsedMs, "source": sessionKey],
                                     clip: pcm, label: "check")
                    } catch {
                        answer = .failed("\(error)")
                    }
                    queue.async { done.value(answer) }
                }
            },
            beginDictation: { client, backlog in
                HandsFreeTranscription(client: client, backlog: backlog, queue: queue, record: record)
            },
            after: { ms, block in
                let item = DispatchWorkItem(block: block)
                queue.asyncAfter(deadline: .now() + .milliseconds(Int(ms.rounded())), execute: item)
                return WorkItemTimer(item: item)
            },
            now: { Date().timeIntervalSince1970 * 1000 },
            emit: emit,
            record: { kind, detail in
                var detail = detail
                detail["source"] = sessionKey
                record.write(kind, detail)
            },
            log: { Log.log("hands-free: \($0)") },
            continuousTurn: { [weak self] in self?.miniModel?.stream() })
        let engine = HandsFreeEngine(owner: owner, trigger: trigger, scorer: EnergyScorer(), deps: deps)
        if let url = SileroVAD.bundledModelURL() {
            do { engine.setScorer(try SileroVAD(modelURL: url)) } catch {
                Log.log("hands-free: speech detector unavailable (\(error)) — using loudness, which hears music as speech")
            }
        } else {
            Log.log("hands-free: no speech detector in the bundle — using loudness, which hears music as speech")
        }
        return engine
    }

    private func setBusy(_ key: String, _ busy: Bool) {
        let idle: Bool = busyLock.withLock {
            let had = busySessions.contains(key)
            guard had != busy else { return false }
            if busy { busySessions.insert(key) } else { busySessions.remove(key) }
            busyCount = busySessions.count
            return !busy && busyCount == 0
        }
        if idle { onIdle?() }
    }

    private final class WorkItemTimer: HandsFreeEngine.Timer {
        let item: DispatchWorkItem
        init(item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }

    // MARK: - Wire format

    static func wire(_ event: HandsFreeEngine.Event) -> [String: Any] {
        func opt(_ value: Double?) -> Any { value.map { $0 } ?? NSNull() }
        switch event {
        case .state(let phase, let conversation, let closesAt, let checking, let pending, let standingAside):
            return ["type": "state", "phase": phase.rawValue, "conversation": conversation,
                    "closesAt": opt(closesAt), "checking": checking, "pending": pending,
                    "standingAside": standingAside.map { $0.rawValue as Any } ?? NSNull()]
        case .gauge(let g):
            return ["type": "gauge", "quietSince": opt(g.quietSince), "patienceMs": opt(g.patienceMs),
                    "mini": opt(g.mini), "miniPeak": opt(g.miniPeak), "miniThreshold": g.miniThreshold]
        case .cue(let cue):
            var message: [String: Any] = ["type": "cue", "name": cue.rawValue]
            if let haptic = cue.haptic { message["haptic"] = haptic }
            return message
        case .duck(let on):
            return ["type": "duck", "on": on]
        case .cutIn(let msAgo):
            return ["type": "cut-in", "msAgo": msAgo, "at": Date().timeIntervalSince1970 * 1000 - Double(msAgo)]
        case .transcript(let text, let trigger, let interrupted, let reason, let shutdown):
            return ["type": "transcript", "text": text, "trigger": trigger.map { $0 as Any } ?? NSNull(),
                    "interrupted": interrupted, "reason": reason, "shutdown": shutdown]
        }
    }

    static func samples(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { raw in
            (0..<(raw.count / 2)).map { raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self) }
        }
    }

    static func data(_ samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// A stream session: one client's audio from one device, and its engine.
fileprivate final class StreamSession {
    let id: String
    let client: String
    let device: String
    let engine: HandsFreeEngine
    var connection: Connection?
    let resampler: PCM16Resampler
    /// 16 kHz samples received: the next `audio` should start here.
    var received = 0
    var lastAck = 0
    var playing = false
    var speech = false
    var echoCancelled = false
    /// What ended when `playing` last went off was the client's voice: its tail is speech too.
    var endedOnSpeech = false
    var playingEndedAt: Date?
    var expiry: DispatchWorkItem?
    var droppedAt: Date?
    init(id: String, client: String, device: String, engine: HandsFreeEngine, resampler: PCM16Resampler) {
        self.id = id
        self.client = client
        self.device = device
        self.engine = engine
        self.resampler = resampler
    }
}

// MARK: - A dictation

/// One hands-free dictation through the user's transcription provider: opened
/// as the trigger word is heard, fed the backlog from the first syllable and
/// then live audio, committed when the engine decides they have finished. Like
/// `RemoteTranscriptionManager`, it shares nothing with `AudioArbiter` but the
/// provider and `TranscriptionLeg`: no paste, no cues, no muting, no
/// interrupting speech — the engine decides what happens to the client's voice.
final class HandsFreeTranscription: HandsFreeEngine.Dictation, @unchecked Sendable {
    static let streamOpenGrace: Duration = .seconds(2)

    private let leg: TranscriptionLeg
    private let queue: DispatchQueue
    private let record: HandsFreeRecord
    private let client: String
    private var pcm = Data()
    private var done = false

    init(client: String, backlog: [Int16], queue: DispatchQueue, record: HandsFreeRecord,
         provider: any TranscriptionProvider = TranscriptionProviders.primary) {
        self.client = client
        self.queue = queue
        self.record = record
        let trace = DictationTrace("hands-free")
        leg = TranscriptionLeg(provider: provider, target: DictationTarget(name: client), trace: trace,
                               logPrefix: "hands-free")
        append(backlog)
    }

    func append(_ samples: [Int16]) {
        guard !done, !samples.isEmpty else { return }
        let data = HandsFreeService.data(samples)
        pcm.append(data)
        leg.append(data)
    }

    func finish(_ completion: @escaping (Result<String, Error>) -> Void) {
        guard !done else { return }
        done = true
        let clip = WAVFile(sampleRate: HandsFreeAudio.sampleRate, samples: pcm).data
        let seconds = Double(pcm.count / 2) / Double(HandsFreeAudio.sampleRate)
        leg.trace.note(String(format: "%.1fs audio", seconds))
        let leg = self.leg, queue = self.queue, record = self.record, client = self.client
        let completion = Unchecked(completion)
        Task {
            do {
                try Incognito.check(HandsFreeService.incognitoActivity)
                let outcome = try await leg.finish(tail: Data(), openGrace: Self.streamOpenGrace, clip: { clip })
                leg.trace.note("\(outcome.text.count) chars")
                leg.trace.flush()
                record.write("dictation", ["client": client, "text": outcome.text, "seconds": seconds])
                queue.async { completion.value(.success(outcome.text)) }
            } catch {
                leg.trace.note("failed: \(TranscriberError.userMessage(for: error))")
                leg.trace.flush()
                record.write("dictation", ["client": client, "error": "\(error)", "seconds": seconds])
                queue.async { completion.value(.failure(error)) }
            }
        }
    }

    func cancel() {
        guard !done else { return }
        done = true
        leg.trace.note("cancelled")
        leg.trace.flush()
        leg.cancel()
    }
}

/// A value handed across to the service's queue, where it is used: the
/// engine's callbacks are confined to that queue, not `Sendable`.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

// MARK: - A connection

/// One client connection: newline-delimited JSON both ways. Confined to the
/// service's queue.
fileprivate final class Connection: @unchecked Sendable {
    enum Role { case control, stream, speaker }

    let nw: NWConnection
    let queue: DispatchQueue
    var role: Role?
    var client = ""
    var device = ""
    /// The control connection's own sound playing on the Mac.
    var playing = false
    var playingEndedAt: Date?
    /// A stream connection's session.
    weak var session: StreamSession?
    /// A speaker connection's device, as `DeviceSpeech` knows it.
    var speaker: Int?
    var onMessage: (([String: Any]) -> Void)?
    var onClose: (() -> Void)?
    private var buffer = Data()
    private var closed = false

    init(_ nw: NWConnection, queue: DispatchQueue) {
        self.nw = nw
        self.queue = queue
    }

    func start() {
        nw.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        nw.start(queue: queue)
        receive()
    }

    func isPlaying(tailMs: Double) -> Bool {
        playing || (playingEndedAt.map { Date().timeIntervalSince($0) * 1000 < tailMs } ?? false)
    }

    func send(_ message: [String: Any]) {
        guard !closed, var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        nw.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
    }

    func close() {
        nw.cancel()
        finish()
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        onClose?()
    }

    private func receive() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] chunk, _, complete, error in
            guard let self else { return }
            if let chunk { self.buffer.append(chunk) }
            while let newline = self.buffer.firstIndex(of: 0x0A) {
                let line = self.buffer[self.buffer.startIndex..<newline]
                self.buffer.removeSubrange(self.buffer.startIndex...newline)
                guard !line.isEmpty else { continue }
                if let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                    self.onMessage?(message)
                } else {
                    self.send(["type": "error", "error": "bad_json"])
                }
            }
            if self.buffer.count > 4 << 20 {
                self.send(["type": "error", "error": "line_too_long"])
                self.close()
                return
            }
            if complete || error != nil { self.close(); return }
            self.receive()
        }
    }
}
