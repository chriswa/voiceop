import Foundation

/// What Voice Operator tells a stream client, parsed. The wire format is in
/// DESIGN.md, "Hands-free (2026-10-24)" → "Protocol (version 1)".
public enum HandsFreeEvent: Equatable, Sendable {
    /// Hands-free is on, on this stream: the session's id.
    case session(String?)
    /// Off: `off`, `replaced`, `lost`, `disconnected`, `incognito`, `unsupported_audio`, `no_client`.
    case ended(String)
    case state(phase: String, conversation: Bool, closesAt: Double?, checking: Bool, pending: Bool)
    case gauge(quietSince: Double?, patienceMs: Double?, turn: Double?, threshold: Double, sampling: Bool)
    case cue(name: String, haptic: String?)
    case duck(Bool)
    case cutIn(msAgo: Int, at: Double)
    case transcript(text: String, trigger: String?, interrupted: Bool, reason: String, shutdown: Bool)
    /// The hello was refused (`protocol`, `invalid_client`, `no_client`, …); Voice Operator closes the connection.
    case refused(String)
    case error(String)
}

/**
 * The phone's side of a hands-free stream: Voice Operator's wire protocol
 * over whatever transport the app has. The app carries the lines — one JSON
 * object each, without the newline — and says when its transport opens and
 * closes; this does the rest: hello, start, resume, the numbered audio and
 * the buffer that makes a dropout survivable.
 *
 * Audio is 16 kHz signed 16-bit little-endian mono, which is also what
 * `VoiceAudioEngine` captures; other rates are refused (`start` reports an
 * error). Every chunk is kept until Voice Operator acks past it, at most
 * `bufferSeconds` (the oldest dropped), so a resumed stream sends again from
 * where Voice Operator says it got to.
 *
 * Not thread-safe: confine it to one thread or actor (the main actor on iOS).
 */
public final class HandsFreeStream {
    public static let protocolVersion = 1
    public static let sampleRate = 16_000
    /// The most audio kept for a resume, in seconds.
    public static let bufferSeconds = 60

    public let client: String
    public let device: String
    private let sendLine: (String) -> Void

    /// Every event, parsed.
    public var onEvent: ((HandsFreeEvent) -> Void)?
    /// Every line Voice Operator sends except its stream bookkeeping (`welcome`, `ack`, `resumed`), as it came.
    public var onRawEvent: ((String) -> Void)?

    /// The live session, if any: kept across a dropout, for `resume`.
    public private(set) var sessionID: String?
    /// Hands-free is wanted on this stream.
    public private(set) var isOn = false

    /// The transport is open (`transportOpened` since the last `transportClosed`).
    public private(set) var connected = false
    /// `start` sent on this connection, `session` not yet back.
    private var awaitingSession = false
    /// `resume` sent on this connection, `resumed` not yet back: audio waits for it.
    private var resuming = false

    /// Audio not yet acked, oldest first; each chunk's first sample's position in the session.
    private var chunks: [(at: Int, pcm: Data)] = []
    /// The position the next sample gets.
    private var nextAt = 0
    /// Half a sample left over from an odd-length chunk.
    private var carry: Data?

    private struct Playing: Equatable { var on: Bool; var speech: Bool; var echoCancelled: Bool }
    private var playingNow = Playing(on: false, speech: false, echoCancelled: false)

    public init(client: String, device: String, sendLine: @escaping (String) -> Void) {
        self.client = client
        self.device = device
        self.sendLine = sendLine
    }

    // MARK: - Transport

    /// The transport has (re)connected: hello, then `start` if hands-free is on and
    /// has no session, or `resume` if it has one.
    public func transportOpened() {
        connected = true
        awaitingSession = false
        resuming = false
        send(["type": "hello", "protocol": Self.protocolVersion, "client": client, "role": "stream", "device": device])
        if let sessionID {
            resuming = true
            send(["type": "resume", "session": sessionID])
        } else if isOn {
            sendStart()
        }
    }

    /// The transport has gone. The session is kept (Voice Operator keeps it 10 s), and the audio with it.
    public func transportClosed() {
        connected = false
        awaitingSession = false
        resuming = false
    }

    /// One line from Voice Operator.
    public func receive(line: String) {
        guard let data = line.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = message["type"] as? String else { return }
        switch type {
        case "welcome":
            return
        case "ack":
            if let at = Self.int(message["at"]) { trim(before: at) }
            return
        case "resumed":
            guard resuming else { return }
            resuming = false
            let at = Self.int(message["at"]) ?? 0
            trim(before: at)
            sendBuffered(from: at)
            if playingNow != Playing(on: false, speech: false, echoCancelled: false) { sendPlaying() }
            return
        case "session":
            awaitingSession = false
            if let id = message["session"] as? String {
                sessionID = id
                sendBuffered(from: 0)
                if playingNow.on { sendPlaying() }
            }
        case "session-ended":
            // Too late to resume (Voice Operator kept it 10 s; the way back took longer — a
            // server restart): still on, so a new session, unnoticed by the app.
            if resuming, isOn, message["why"] as? String == "lost" {
                endSession()
                isOn = true
                if connected { sendStart() }
                return
            }
            endSession()
            // Voice Operator is quitting to restart: still on, so the next connection starts afresh.
            if message["why"] as? String == "restarting" { isOn = true }
        default:
            break
        }
        onRawEvent?(line)
        if let event = Self.event(message) { onEvent?(event) }
    }

    // MARK: - The app

    /// Hands-free on, on this stream. `sampleRate` must be 16000.
    public func start(sampleRate: Int = HandsFreeStream.sampleRate) {
        guard sampleRate == Self.sampleRate else {
            onEvent?(.error("unsupported_sample_rate: \(sampleRate) (send 16 kHz)"))
            return
        }
        guard !isOn else { return }
        isOn = true
        if connected, sessionID == nil, !awaitingSession { sendStart() }
    }

    /// Hands-free off.
    public func stop() {
        guard isOn || sessionID != nil else { return }
        if connected, sessionID != nil || awaitingSession { send(["type": "stop"]) }
        endSession()
    }

    /// Captured audio: 16 kHz s16le mono. Kept until acked; sent at once while a session is live.
    public func audio(_ pcm16: Data) {
        guard isOn else { return }
        var pcm = pcm16
        if let carry { pcm = carry + pcm; self.carry = nil }
        if pcm.count % 2 == 1 { carry = pcm.suffix(1); pcm = pcm.prefix(pcm.count - 1) }
        guard !pcm.isEmpty else { return }
        let at = nextAt
        chunks.append((at, Data(pcm)))
        nextAt += pcm.count / 2
        // At most `bufferSeconds` kept: the oldest go first.
        let cap = Self.bufferSeconds * Self.sampleRate
        while let first = chunks.first, nextAt - first.at > cap, chunks.count > 1 { chunks.removeFirst() }
        if live { sendAudio(at: at, pcm) }
    }

    /// What the device is playing: `speech`, the client's voice; `echoCancelled`, the microphone does not hear it.
    /// Sent when it changes, and again after a resume.
    public func playing(on: Bool, speech: Bool, echoCancelled: Bool) {
        let now = Playing(on: on, speech: speech, echoCancelled: echoCancelled)
        guard now != playingNow else { return }
        playingNow = now
        if live { sendPlaying() }
    }

    // MARK: - Inside

    /// Audio can go now: connected, a session, and not waiting on a resume.
    private var live: Bool { connected && sessionID != nil && !resuming }

    private func sendStart() {
        // A new session numbers its audio from 0, and has no use for what was heard before it was asked for.
        chunks = []
        nextAt = 0
        carry = nil
        awaitingSession = true
        send(["type": "start", "sampleRate": Self.sampleRate, "codec": "pcm16"])
    }

    private func endSession() {
        isOn = false
        sessionID = nil
        awaitingSession = false
        resuming = false
        chunks = []
        nextAt = 0
        carry = nil
    }

    private func trim(before at: Int) {
        while let first = chunks.first, first.at + first.pcm.count / 2 <= at { chunks.removeFirst() }
    }

    private func sendBuffered(from at: Int) {
        for chunk in chunks {
            let end = chunk.at + chunk.pcm.count / 2
            guard end > at else { continue }
            if chunk.at >= at {
                sendAudio(at: chunk.at, chunk.pcm)
            } else {
                let skip = (at - chunk.at) * 2
                sendAudio(at: at, chunk.pcm.subdata(in: chunk.pcm.startIndex + skip ..< chunk.pcm.endIndex))
            }
        }
    }

    private func sendAudio(at: Int, _ pcm: Data) {
        send(["type": "audio", "at": at, "data": pcm.base64EncodedString()])
    }

    private func sendPlaying() {
        send(["type": "playing", "on": playingNow.on, "speech": playingNow.speech, "echoCancelled": playingNow.echoCancelled])
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        sendLine(line)
    }

    // MARK: - Parsing

    /// One of Voice Operator's lines, parsed; nil for bookkeeping and anything unknown.
    public static func event(fromLine line: String) -> HandsFreeEvent? {
        guard let data = line.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return event(message)
    }

    static func event(_ m: [String: Any]) -> HandsFreeEvent? {
        switch m["type"] as? String {
        case "session":
            return .session(m["session"] as? String)
        case "session-ended":
            return .ended(m["why"] as? String ?? "")
        case "state":
            return .state(phase: m["phase"] as? String ?? "off", conversation: bool(m["conversation"]),
                          closesAt: double(m["closesAt"]), checking: bool(m["checking"]), pending: bool(m["pending"]))
        case "gauge":
            return .gauge(quietSince: double(m["quietSince"]), patienceMs: double(m["patienceMs"]), turn: double(m["turn"]),
                          threshold: double(m["threshold"]) ?? 0, sampling: bool(m["sampling"]))
        case "cue":
            return .cue(name: m["name"] as? String ?? "", haptic: m["haptic"] as? String)
        case "duck":
            return .duck(bool(m["on"]))
        case "cut-in":
            return .cutIn(msAgo: int(m["msAgo"]) ?? 0, at: double(m["at"]) ?? 0)
        case "transcript":
            return .transcript(text: m["text"] as? String ?? "", trigger: m["trigger"] as? String,
                               interrupted: bool(m["interrupted"]), reason: m["reason"] as? String ?? "",
                               shutdown: bool(m["shutdown"]))
        case "refused":
            return .refused(m["error"] as? String ?? "")
        case "error":
            return .error(m["error"] as? String ?? "")
        default:
            return nil
        }
    }

    private static func bool(_ value: Any?) -> Bool { (value as? Bool) ?? false }

    private static func double(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        return number.doubleValue
    }

    private static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        return Int(number.doubleValue.rounded())
    }
}
