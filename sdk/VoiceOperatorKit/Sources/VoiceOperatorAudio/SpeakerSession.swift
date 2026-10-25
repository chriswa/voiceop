#if os(iOS)
import Foundation
import VoiceOperatorSpeech

/**
 * Speech on this phone: what Voice Operator sends a `SpeechDevice` played
 * through the engine's one player — with echo cancellation while hands-free
 * holds the microphone, so the user can still be heard over it — and each
 * sentence's start and end reported back, from which Voice Operator keeps the
 * job: its status, and how far the listener got when it was stopped.
 *
 * The engine plays only while it is up, so while on this keeps it up without
 * the microphone (`stay-awake`) — which also keeps the app running in the
 * background, as speech arriving with the screen locked needs. An app that
 * sends `stay-awake` itself should leave it to this instead.
 *
 * The transport is the app's: lines out through `sendLine`, in through
 * `receive(line:)`, and `transportOpened`/`transportClosed` as it comes and goes.
 */
@MainActor
public final class SpeakerSession {
    public let engine: VoiceAudioEngine
    public let device: SpeechDevice

    /// A line for Voice Operator, for the app's transport to carry.
    public var sendLine: ((String) -> Void)?
    /// Every event Voice Operator sends, parsed, after it has been acted on.
    public var onEvent: ((SpeechDeviceEvent) -> Void)?

    /// Jobs with a sentence handed to the engine and not yet ended.
    private var playing: Set<String> = []
    public private(set) var isOn = false

    public init(engine: VoiceAudioEngine, client: String, device: String) {
        self.engine = engine
        var line: ((String) -> Void)?
        self.device = SpeechDevice(client: client, device: device) { line?($0) }
        line = { [weak self] in self?.sendLine?($0) }
        self.device.onEvent = { [weak self] in self?.received($0) }
        engine.speechObserver = { [weak self] id, index, event in self?.played(id, index, event) }
    }

    /// Ready to play: the engine kept up.
    public func start() {
        guard !isOn else { return }
        isOn = true
        engine.handle(command: "stay-awake", body: ["on": true])
    }

    /// Not any more: what is playing stops, and the engine may go down.
    public func stop() {
        guard isOn else { return }
        isOn = false
        for id in playing { engine.handle(command: "speech-stop", body: ["id": id]) }
        playing = []
        engine.handle(command: "stay-awake", body: ["on": false])
    }

    public func transportOpened() { device.transportOpened() }

    /// Voice Operator has ended what was playing here: it stops.
    public func transportClosed() {
        device.transportClosed()
        for id in playing { engine.handle(command: "speech-stop", body: ["id": id]) }
        playing = []
    }

    public func receive(line: String) { device.receive(line: line) }

    // MARK: - Inside

    private func received(_ event: SpeechDeviceEvent) {
        switch event {
        case .sentence(let sentence):
            guard isOn else {
                device.failed(id: sentence.id, index: sentence.index)
                break
            }
            playing.insert(sentence.id)
            engine.handle(command: "speech-play", body: [
                "id": sentence.id, "index": sentence.index, "count": sentence.count,
                "sampleRate": sentence.sampleRate, "pcm": sentence.pcm.base64EncodedString(),
            ])
        case .ended(let id, let state, _):
            if playing.remove(id) != nil, state != "completed" { engine.handle(command: "speech-stop", body: ["id": id]) }
        case .replaced:
            for id in playing { engine.handle(command: "speech-stop", body: ["id": id]) }
            playing = []
        default:
            break
        }
        onEvent?(event)
    }

    private func played(_ id: String, _ index: Int, _ event: String) {
        guard playing.contains(id) else { return }
        switch event {
        case "started": device.started(id: id, index: index)
        case "finished": device.finished(id: id, index: index)
        default: device.failed(id: id, index: index)
        }
    }
}
#endif
