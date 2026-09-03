import Foundation

/// How a dictation is interpreted: Fn = paste the transcript; Ctrl+Fn = route the
/// transcript through the voice-command router instead of pasting it.
enum DictationMode: String {
    case paste, command

    /// The cue that says "the microphone is live, start talking".
    var startCue: SoundEffect { self == .command ? .commandListeningStarted : .listeningStarted }
    /// The cue that says "we heard you, transcribing now".
    var finishCue: SoundEffect { self == .command ? .commandListeningFinished : .listeningFinished }
    /// The finish cue when the live stream has already failed and this dictation
    /// is going the slow way (see `StreamHealth`).
    var slowFinishCue: SoundEffect { self == .command ? .commandListeningFinishedSlow : .listeningFinishedSlow }
}

/// The mode of one dictation, which is **not knowable at the instant capture
/// begins**.
///
/// Ctrl+Fn is physically two key presses and nobody lands them simultaneously. In
/// practice Fn goes down a few tens of milliseconds *before* Control, so reading
/// the Control flag at Fn key-down — the single instant the mode used to be
/// decided — reported "no Control" and ran a command dictation as a paste.
///
/// Waiting for Control before opening the microphone is not an option: capture
/// starts on key-down precisely so no opening words are lost (`HotkeyMonitor`).
/// So the mode is a *decision* that starts provisional and closes `window` after
/// key-down, while audio is already flowing. Nothing on the capture path consults
/// it — only the start cue, the menu-bar tint, the end cue, and whether the
/// transcript is pasted or routed. The earliest of those, the start cue, cannot
/// fire until CoreAudio hands over a first buffer, which on this hardware has
/// never taken less than ~175 ms; the window therefore costs no user-visible
/// latency, and callers must simply ask through `whenResolved`.
///
/// Once resolved the mode is **latched**. Control pressed later belongs to
/// whatever the user is doing in the app they are dictating into, not to us.
@MainActor
final class DictationModeDecision {
    /// How long after trigger key-down a Control press still reads as half of a
    /// Ctrl+Fn chord. Sits just under the fastest observed microphone-live time
    /// (~175 ms after key-down), so closing the window never delays the cue that
    /// depends on it.
    static let window: TimeInterval = 0.2

    /// The mode as currently known — provisional until `isResolved`.
    private(set) var mode: DictationMode
    private(set) var isResolved = false

    private var observers: [(DictationMode) -> Void] = []
    private var deadline: Timer?

    /// - Parameter controlAlreadyDown: Control was held when the trigger went
    ///   down, so this is unambiguously a command dictation with nothing to wait
    ///   for — the decision is born resolved.
    init(controlAlreadyDown: Bool) {
        mode = controlAlreadyDown ? .command : .paste
        guard !controlAlreadyDown else {
            isResolved = true
            return
        }
        let timer = Timer(timeInterval: Self.window, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.resolve()
            }
        }
        // .common, not the default mode: menu tracking (or any other run-loop mode
        // switch) parks a default-mode timer, which would leave the mode pending
        // and the start cue that waits on it silent for the whole dictation.
        RunLoop.main.add(timer, forMode: .common)
        deadline = timer
    }

    /// Control went down while the window was still open — this was a Ctrl+Fn
    /// chord after all, just an unevenly-timed one. A no-op once latched.
    func noteControlPressed() {
        guard !isResolved else { return }
        mode = .command
        resolve()
    }

    /// Latch the mode as it stands and hand it to everyone waiting. Idempotent, so
    /// the deadline, an early Control press, and a caller that needs the answer
    /// *now* can all call it.
    @discardableResult
    func resolve() -> DictationMode {
        guard !isResolved else { return mode }
        isResolved = true
        deadline?.invalidate()
        deadline = nil
        let waiting = observers
        observers = []
        for body in waiting { body(mode) }
        return mode
    }

    /// Run `body` with the final mode: synchronously if it is already known,
    /// otherwise as soon as it is. Fires exactly once per registration.
    func whenResolved(_ body: @escaping (DictationMode) -> Void) {
        guard !isResolved else {
            body(mode)
            return
        }
        observers.append(body)
    }
}
