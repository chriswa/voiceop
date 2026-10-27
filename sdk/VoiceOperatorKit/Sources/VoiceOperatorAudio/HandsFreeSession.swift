#if os(iOS)
import Foundation
import VoiceOperatorHandsFree

/**
 * Hands-free on this phone: the engine's microphone streamed to Voice
 * Operator, and Voice Operator's answers applied to the engine.
 *
 * While on, every chunk the engine captures goes to `HandsFreeStream.audio`;
 * what the engine's one player plays goes to Voice Operator as `playing`
 * (speech, and whether echo cancellation spares the microphone it); `duck`
 * turns the speech down as `speech-duck` does; and a dictation under way
 * (`state` phase `hearing`) turns other audio down as `hands-free-dictating`
 * does. Cues, haptics and gauges are the app's: it gets every event.
 *
 * The transport is the app's: lines out through `sendLine`, in through
 * `receive(line:)`, and `transportOpened`/`transportClosed` as it comes and goes.
 *
 * It holds the microphone through the engine's own `start`, and only if the
 * engine was not already holding it for someone else; it lets go on `stop`
 * only what it took, and not while `microphoneHeldElsewhere` says otherwise.
 */
@MainActor
public final class HandsFreeSession {
    public let engine: VoiceAudioEngine
    /// The stream for the client and device last started; nil before the first `start`.
    public private(set) var stream: HandsFreeStream?

    /// A line for Voice Operator, for the app's transport to carry.
    public var sendLine: ((String) -> Void)?
    /// Every event Voice Operator sends, parsed.
    public var onEvent: ((HandsFreeEvent) -> Void)?
    /// Every line Voice Operator sends, as sent, but its stream bookkeeping (`welcome`, `ack`, `resumed`).
    public var onRawEvent: ((String) -> Void)?
    /// Whether the microphone is also held by something other than hands-free (a page's own `start`).
    public var microphoneHeldElsewhere: () -> Bool = { false }

    /// The transport is open: a stream made later says hello on it at once.
    private var transportOpen = false
    /// This session started the engine's microphone, and so may let it go.
    private var tookMicrophone = false
    /// The speech is turned down at Voice Operator's word.
    private var ducked = false
    private var dictating = false

    public var isOn: Bool { stream?.isOn ?? false }

    public init(engine: VoiceAudioEngine) {
        self.engine = engine
        engine.captureObserver = { [weak self] pcm in self?.stream?.audio(pcm) }
        engine.onPlaybackChange = { [weak self] in self?.reportPlayback() }
        engine.onSetupChange = { [weak self] in self?.reportSetup() }
    }

    /// Hands-free on: the microphone held (if it is not already), and the stream started.
    public func start(client: String, device: String) {
        if stream == nil || stream?.client != client || stream?.device != device {
            stream?.stop()
            let made = HandsFreeStream(client: client, device: device) { [weak self] line in self?.sendLine?(line) }
            made.onEvent = { [weak self] event in self?.received(event) }
            made.onRawEvent = { [weak self] line in self?.onRawEvent?(line) }
            stream = made
            if transportOpen { made.transportOpened() }
        }
        if !engine.microphoneWanted {
            tookMicrophone = true
            engine.handle(command: "start", body: [:])
        }
        stream?.start(sampleRate: HandsFreeStream.sampleRate)
        reportPlayback()
        reportSetup()
    }

    /// Hands-free off: the stream stopped, and the microphone let go if this took it and nothing else holds it.
    public func stop() {
        stream?.stop()
        finished()
    }

    public func transportOpened() {
        transportOpen = true
        stream?.transportOpened()
    }

    public func transportClosed() {
        transportOpen = false
        stream?.transportClosed()
    }

    public func receive(line: String) {
        stream?.receive(line: line)
    }

    // MARK: - Inside

    private func received(_ event: HandsFreeEvent) {
        switch event {
        case .duck(let on):
            ducked = on
            engine.handle(command: "speech-duck", body: ["on": on])
        case .state(let phase, _, _, _, _, _):
            let now = phase == "hearing"
            if now != dictating {
                dictating = now
                engine.handle(command: "hands-free-dictating", body: ["on": now])
            }
        case .ended:
            finished()
        default:
            break
        }
        onEvent?(event)
    }

    /// Off, by the app or by Voice Operator: anything this turned on, turned off.
    private func finished() {
        if ducked {
            ducked = false
            engine.handle(command: "speech-duck", body: ["on": false])
        }
        if dictating {
            dictating = false
            engine.handle(command: "hands-free-dictating", body: ["on": false])
        }
        if tookMicrophone {
            tookMicrophone = false
            if !microphoneHeldElsewhere() { engine.handle(command: "stop", body: [:]) }
        }
    }

    private func reportSetup() {
        let now = engine.setup
        stream?.route(now.route, voiceProcessing: now.voiceProcessing)
    }

    private func reportPlayback() {
        let now = engine.playback
        stream?.playing(on: now.on, speech: now.speech, echoCancelled: now.echoCancelled)
    }
}
#endif
