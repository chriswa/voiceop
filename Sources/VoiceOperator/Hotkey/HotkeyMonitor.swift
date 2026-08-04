import AppKit
import IOKit.hid

/// Global trigger-key monitor. The trigger is the **Fn (Globe) key** — Wispr Flow
/// has been retired, so we take over its key (DESIGN.md "Trigger key").
///
/// Fn is not an ordinary modifier: its flagsChanged event reports keycode 63
/// (kVK_Function) with the kCGEventFlagMaskSecondaryFn bit (0x800000), rather
/// than a device-dependent left/right bit. Ensure macOS System Settings →
/// Keyboard → "Press 🌐 key to" is set to "Do Nothing" so it doesn't also
/// trigger emoji/dictation/input-switching.
///
/// Gestures — note that **recording always begins on key-down**, with no hold
/// threshold. The old code waited 250 ms before starting so it could tell a hold
/// from a double-tap, which meant the microphone was not even opening until a
/// quarter-second after the user pressed the key, on top of however long
/// CoreAudio then took to deliver a first buffer. That is where the missing
/// opening words came from. The ambiguity is now resolved on the *stop* side,
/// which costs nothing: audio we did not need is simply discarded.
///
///   • **Hold** the key → push-to-talk: dictate while held, stop on release.
///   • **Quick tap then release** → recording keeps running until `lockWindow`
///     has elapsed since key-down, in case a second press is coming.
///   • **Second press inside that window** → hands-free lock: keep dictating
///     until the next press stops it.
///
/// `lockWindow` matches Wispr Flow's `DICTATION_DEBOUNCE_DELAY` (500 ms), which
/// it likewise uses only to recognise a second quick press — never to delay the
/// start of capture.
///
/// A keyboard `CGEventTap` needs BOTH Accessibility (to install) and **Input
/// Monitoring** (to receive un-redacted keycodes — without it, every event
/// arrives with keycode/flags zeroed). See `AppCoordinator`.
@MainActor
final class HotkeyMonitor {
    /// Whether Input Monitoring (kIOHIDRequestTypeListenEvent) is granted.
    static func inputMonitoringGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Prompt for Input Monitoring (adds us to the System Settings list).
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
    /// Dictation started. The mode is decided by whether **Control** is held at
    /// key-down (Ctrl+Fn = command, Fn = paste); chording naturally puts Control
    /// down first, and its flagsChanged event arrives before Fn's.
    ///
    /// The `DictationTrace` is created here, at the key event itself, so every
    /// later phase is measured against the instant the user actually pressed.
    var onStart: ((DictationMode, DictationTrace) -> Void)?
    var onStop: (() -> Void)?
    /// Fired on ⌘⌃V — re-paste the last pasted text.
    var onRepaste: (() -> Void)?
    /// Fired on ⌘⌃B — toggle narration mute.
    var onToggleMute: (() -> Void)?
    /// Fired on ⌘⌃S — speak the clipboard aloud (or stop if already speaking).
    var onSpeakClipboard: (() -> Void)?
    /// Fired on ⌘⌃A — summarize the clipboard via Haiku.
    var onSummarizeClipboard: (() -> Void)?
    /// Fired on ⌘⌃N — skip the clip playing now (no-op when nothing is playing).
    var onSkip: (() -> Void)?
    /// Fired on ⌘⌃J — focus the surface of the last agent that spoke.
    var onFocusLast: (() -> Void)?

    /// Suppresses the ⌘⌃ chord shortcuts while the status-bar menu is open. Those
    /// items carry real menu key equivalents (for the right-aligned shortcut hint),
    /// which the menu fires itself while open — so we mute the tap's copy to avoid
    /// firing twice. The Fn dictation trigger is unaffected.
    var chordsSuppressed = false

    /// Live Control-key state, updated from every flagsChanged event.
    private var controlDown = false
    private var currentMode: DictationMode { controlDown ? .command : .paste }

    // ⌘⌃V: V is keycode 9 (kVK_ANSI_V); requires Command + Control.
    private static let vKeycode: Int64 = 9
    // ⌘⌃B: B is keycode 11 (kVK_ANSI_B); requires Command + Control.
    private static let bKeycode: Int64 = 11
    // ⌘⌃S: S is keycode 1 (kVK_ANSI_S); requires Command + Control.
    private static let sKeycode: Int64 = 1
    // ⌘⌃A: A is keycode 0 (kVK_ANSI_A); requires Command + Control.
    private static let aKeycode: Int64 = 0
    // ⌘⌃N: N is keycode 45 (kVK_ANSI_N); requires Command + Control.
    private static let nKeycode: Int64 = 45
    // ⌘⌃J: J is keycode 38 (kVK_ANSI_J); requires Command + Control.
    private static let jKeycode: Int64 = 38

    // Fn (Globe): keycode 63 (kVK_Function), flagged by kCGEventFlagMaskSecondaryFn.
    private static let triggerKeycode: Int64 = 63
    private static let triggerBit: UInt64 = 0x800000

    /// How long after key-down a second press still counts as "lock this on".
    /// Wispr Flow's `DICTATION_DEBOUNCE_DELAY`.
    private let lockWindow: TimeInterval = 0.5

    private var tap: CFMachPort?
    private var isDown = false
    private var downTime: Date = .distantPast
    private var lockTimer: Timer?

    private enum Gesture: Equatable {
        /// Not dictating.
        case idle
        /// Recording, key still held — a plain push-to-talk.
        case holding
        /// Recording, key released inside `lockWindow`. Still going, because a
        /// second press may yet arrive to lock it on; `lockTimer` stops it if not.
        case awaitingLock
        /// Recording hands-free. The next key press ends it.
        case locked
    }
    private var gesture: Gesture = .idle

    func start() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)   // for the ⌘⌃-chord shortcuts
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                    monitor.handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: refcon) else {
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // A slow/stalled tap gets disabled by the system; re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            Log.log("hotkey tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input")")
            // Events during the disabled window are gone — possibly including the
            // key-up that would have ended a dictation. Resynchronise rather than
            // trust stale state: otherwise `isDown` stays true, the recording runs
            // unbounded, and the duplicate-event filter below swallows the user's
            // next press as they try to recover.
            if gesture != .idle {
                Log.log("hotkey: dictation was in progress across the gap — stopping it")
                cancelLockTimer()
                gesture = .idle
                isDown = false
                onStop?()
            }
            return
        }
        // ⌘⌃-chord keyDown shortcuts (V = re-paste, B = toggle mute, S = speak
        // clipboard, A = summarize clipboard, N = skip current clip). Suppressed
        // while the menu is open,
        // where the items' own key equivalents fire instead (see chordsSuppressed).
        if type == .keyDown {
            guard !chordsSuppressed else { return }
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            if event.flags.contains(.maskCommand), event.flags.contains(.maskControl) {
                switch keycode {
                case Self.vKeycode: onRepaste?()
                case Self.bKeycode: onToggleMute?()
                case Self.sKeycode: onSpeakClipboard?()
                case Self.aKeycode: onSummarizeClipboard?()
                case Self.nKeycode: onSkip?()
                case Self.jKeycode: onFocusLast?()
                default: break
                }
            }
            return
        }
        guard type == .flagsChanged else { return }
        // Track Control from every modifier change, so we know at dictation-start
        // whether this is a Ctrl+Fn (command) or plain Fn (paste) trigger.
        controlDown = event.flags.contains(.maskControl)
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.rawValue
        guard keycode == Self.triggerKeycode else { return }
        let down = (flags & Self.triggerBit) != 0
        if down == isDown { return }   // ignore duplicates / confounding modifiers
        isDown = down
        if down { keyDown() } else { keyUp() }
    }

    private func keyDown() {
        switch gesture {
        case .idle:
            // Start capturing this instant. Everything else — hold vs. tap vs.
            // double-tap — is decided later, while audio is already flowing.
            downTime = Date()
            gesture = .holding
            onStart?(currentMode, DictationTrace())
        case .awaitingLock:
            // Second press inside the window: hands-free from here on.
            cancelLockTimer()
            gesture = .locked
        case .locked:
            gesture = .idle
            onStop?()
        case .holding:
            break   // duplicate down; the isDown guard normally filters these
        }
    }

    private func keyUp() {
        switch gesture {
        case .holding:
            let held = Date().timeIntervalSince(downTime)
            guard held < lockWindow else {
                // A real hold — this is push-to-talk, so stop on release.
                gesture = .idle
                onStop?()
                return
            }
            // Too quick to tell apart from the first half of a double-tap. Keep
            // recording (and keep uploading) until the window closes; if no
            // second press lands, stop then. The extra audio is free — worst case
            // it is a few hundred ms of room tone at the end of the clip.
            gesture = .awaitingLock
            lockTimer?.invalidate()
            let timer = Timer.scheduledTimer(withTimeInterval: lockWindow - held, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.gesture == .awaitingLock else { return }
                    self.lockTimer = nil
                    self.gesture = .idle
                    self.onStop?()
                }
            }
            // .common, or menu tracking (and any other run-loop mode switch) parks
            // this timer and the dictation it is supposed to end never stops: mic
            // open, audio uploading, system output muted, indefinitely. The event
            // tap itself is installed in .commonModes, so key events keep arriving
            // during tracking while a default-mode timer would not fire.
            RunLoop.main.add(timer, forMode: .common)
            lockTimer = timer
        case .awaitingLock, .locked, .idle:
            break   // release of the locking press, or of a press that already stopped
        }
    }

    private func cancelLockTimer() {
        lockTimer?.invalidate()
        lockTimer = nil
    }
}
