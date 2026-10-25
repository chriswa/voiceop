import Foundation

/// One sentence of a speech job to play, after any before it: signed 16-bit
/// little-endian mono PCM at `sampleRate`.
public struct SpeechSentence: Equatable, Sendable {
    public let id: String
    public let index: Int
    /// Sentences in the whole job; the last is `count - 1`.
    public let count: Int
    public let sampleRate: Double
    public let pcm: Data
    /// When Voice Operator sent it, epoch ms on the Mac's clock: for a record of how late it came.
    public let sentAt: Double?

    public init(id: String, index: Int, count: Int, sampleRate: Double, pcm: Data, sentAt: Double? = nil) {
        self.id = id
        self.index = index
        self.count = count
        self.sampleRate = sampleRate
        self.pcm = pcm
        self.sentAt = sentAt
    }
}

/// What Voice Operator tells a speaker, parsed. The wire format is in
/// DESIGN.md, "Speech on a device".
public enum SpeechDeviceEvent: Equatable, Sendable {
    /// The connection is this device's now.
    case welcome
    /// A sentence to play, queued behind whatever is playing.
    case sentence(SpeechSentence)
    /// The job is over: `completed`, `interrupted_by_user`, `cancelled_by_client` or
    /// `synthesis_failed`. Anything still to play of it is to be dropped, unless it completed.
    case ended(id: String, state: String, characterOffset: Int)
    /// Another connection said hello as this device: this one gets no more speech.
    case replaced
    /// The hello was refused (`protocol`, `invalid_client`, `invalid_device`); Voice Operator closes the connection.
    case refused(String)
    case error(String)
}

/**
 * A device's side of speech on a device: Voice Operator makes the speech a
 * client asked for on this device (`POST /v1/speech` with `client` and
 * `device`), sends it here a sentence at a time, and keeps the job — its
 * status, how far the listener got, a stop dated back to when they began
 * talking. The device plays the sentences in order and says when each starts
 * and finishes; nothing else.
 *
 * Transport-agnostic, as `HandsFreeStream` is: the app carries the lines — one
 * JSON object each, without the newline — and says when its transport opens
 * and closes. A device is named by its client and `device`, which the client
 * that asks for speech must use too. A connection that drops ends whatever it
 * was playing, at what had been heard; reconnecting says hello again and
 * carries on with the next job.
 *
 * Not thread-safe: confine it to one thread or actor (the main actor on iOS).
 * `VoiceOperatorAudio`'s `SpeakerSession` plays it through `VoiceAudioEngine`.
 */
public final class SpeechDevice {
    public static let protocolVersion = 1

    public let client: String
    public let device: String
    private let sendLine: (String) -> Void

    /// Every event, parsed.
    public var onEvent: ((SpeechDeviceEvent) -> Void)?
    /// The transport is open (`transportOpened` since the last `transportClosed`).
    public private(set) var connected = false

    public init(client: String, device: String, sendLine: @escaping (String) -> Void) {
        self.client = client
        self.device = device
        self.sendLine = sendLine
    }

    /// The transport has (re)connected: hello.
    public func transportOpened() {
        connected = true
        send(["type": "hello", "protocol": Self.protocolVersion, "client": client, "role": "speaker", "device": device])
    }

    /// The transport has gone, and Voice Operator has ended what was playing here.
    public func transportClosed() {
        connected = false
    }

    /// One line from Voice Operator.
    public func receive(line: String) {
        guard let data = line.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = message["type"] as? String else { return }
        switch type {
        case "welcome":
            onEvent?(.welcome)
        case "sentence":
            guard let id = message["id"] as? String, let index = Self.int(message["index"]),
                  let count = Self.int(message["count"]), let rate = (message["sampleRate"] as? NSNumber)?.doubleValue,
                  let pcm = (message["pcm"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
                onEvent?(.error("a sentence without id, index, count, sampleRate and pcm"))
                return
            }
            onEvent?(.sentence(SpeechSentence(id: id, index: index, count: count, sampleRate: rate, pcm: pcm,
                                              sentAt: (message["sentAt"] as? NSNumber)?.doubleValue)))
        case "ended":
            guard let id = message["id"] as? String, let state = message["state"] as? String else { return }
            onEvent?(.ended(id: id, state: state, characterOffset: Self.int(message["characterOffset"]) ?? 0))
        case "replaced":
            onEvent?(.replaced)
        case "refused":
            onEvent?(.refused(message["error"] as? String ?? "refused"))
        case "error":
            onEvent?(.error(message["error"] as? String ?? "error"))
        default:
            return
        }
    }

    /// The sentence's first sample is playing.
    public func started(id: String, index: Int) { progress(id, index, "started") }
    /// The sentence played to its last sample.
    public func finished(id: String, index: Int) { progress(id, index, "finished") }
    /// The sentence could not be played: the job ends.
    public func failed(id: String, index: Int) { progress(id, index, "failed") }

    private func progress(_ id: String, _ index: Int, _ event: String) {
        guard connected else { return }
        send(["type": "progress", "id": id, "index": index, "event": event])
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        sendLine(String(decoding: data, as: UTF8.self))
    }

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }
}
