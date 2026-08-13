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
/// **Ctrl+Fn (command mode) is decided the same way**: on the stop side of the
/// question, not by blocking the start. Whether Control is part of the gesture
/// stays open for `DictationModeDecision.window` after key-down, so a chord whose
/// halves land in either order — Control first, or Fn first by tens of
/// milliseconds — is read as a chord. See `DictationModeDecision` for why that
/// window is free.
///
/// A keyboard `CGEventTap` needs BOTH Accessibility (to install) and **Input
/// Monitoring** (to receive un-redacted keycodes — without it, every event
/// arrives with keycode/flags zeroed). See `AppCoordinator`.
///
/// ## Why this runs on its own thread
///
/// The tap and the gesture state machine live on a dedicated run-loop thread,
/// not the main one, and every callback is hopped to main. Key events must be
/// handled the moment they arrive, and the main thread is not somewhere that can
/// be promised: it draws the menu bar, tracks menus, and used to spend the best
/// part of a second inside `AVAudioEngine.start()` waking an idle microphone.
/// When key handling stalls, the damage is not merely late — it is *wrong*. The
/// key-up of a quick tap arrives a second after its key-down, the gesture reads
/// as a hold rather than as half of a double-tap, and the dictation the user was
/// locking on stops instead. macOS compounds it by disabling an event tap whose
/// callback is too slow, which drops the events either side of the gap.
///
/// Durations are therefore taken from the **events' own timestamps** rather than
/// from the clock at the moment we handle them, so even a stalled thread reports
/// the gesture the user actually performed. `CGEvent.timestamp` is nanoseconds
/// since boot (not mach ticks) — see `heldDuration`.
final class HotkeyMonitor: @unchecked Sendable {
    /// Whether Input Monitoring (kIOHIDRequestTypeListenEvent) is granted.
    static func inputMonitoringGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Prompt for Input Monitoring (adds us to the System Settings list).
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// All callbacks are delivered on the **main thread**, in the order the key
    /// events arrived. Assign them before calling `start()`: they are read from
    /// the tap thread and are not synchronised.
    typealias Action = @MainActor @Sendable () -> Void

    /// Dictation started. The mode (Ctrl+Fn = command, Fn = paste) arrives as a
    /// `DictationModeDecision` rather than a value, because at this instant it may
    /// genuinely not be known yet: capture begins the moment Fn goes down, and the
    /// Control half of the chord is often still a few tens of milliseconds away.
    ///
    /// The `DictationTrace` is created here, at the key event itself, so every
    /// later phase is measured against the instant the user actually pressed.
    var onStart: (@MainActor @Sendable (DictationModeDecision, DictationTrace) -> Void)?
    var onStop: Action?
    /// Fired on ⌘⌃V — re-paste the last pasted text.
    var onRepaste: Action?
    /// Fired on ⌘⌃B — toggle narration mute.
    var onToggleMute: Action?
    /// Fired on ⌘⌃S — speak the clipboard aloud (or stop if already speaking).
    var onSpeakClipboard: Action?
    /// Fired on ⌘⌃A — summarize the clipboard via Haiku.
    var onSummarizeClipboard: Action?
    /// Fired on ⌘⌃N — skip the clip playing now (no-op when nothing is playing).
    var onSkip: Action?
    /// Fired on ⌘⌃J — focus the surface of the last agent that spoke.
    var onFocusLast: Action?

    /// Suppresses the ⌘⌃ chord shortcuts while the status-bar menu is open. Those
    /// items carry real menu key equivalents (for the right-aligned shortcut hint),
    /// which the menu fires itself while open — so we mute the tap's copy to avoid
    /// firing twice. The Fn dictation trigger is unaffected.
    var chordsSuppressed: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return suppressChords }
        set { stateLock.lock(); suppressChords = newValue; stateLock.unlock() }
    }
    private let stateLock = NSLock()
    private var suppressChords = false

    /// Live Control-key state, updated from every flagsChanged event on the
    /// hotkey thread. Used only to seed `DictationModeDecision` at key-down;
    /// late Control presses are forwarded to the decision on the main thread.
    private var controlDown = false

    /// The mode decision of the dictation now in flight. Touched only on the
    /// main thread (via `onMain`), because `DictationModeDecision` is
    /// `@MainActor`. Forwarding to an already-latched decision is a no-op.
    private var modeDecision: DictationModeDecision?

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
    /// `CGEvent.timestamp` of the key-down (nanoseconds since boot).
    private var downTimestamp: UInt64 = 0
    /// Fallback anchor, for the rare event that carries no timestamp.
    private var downTime: Date = .distantPast
    private var lockTimer: Timer?

    private var thread: Thread?

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

    /// Create the tap here — it is a mach port, not bound to any run loop, so
    /// whether it could be created is known synchronously and `AppCoordinator`
    /// can keep reporting installation success at launch. Which run loop
    /// *services* it is decided separately, by where the source is attached, and
    /// that is the private thread below.
    func start() -> Bool {
        guard thread == nil else { return tap != nil }
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
        self.tap = tap        // read back off `self` inside the thread: CF types are not Sendable

        let thread = Thread { [weak self] in
            guard let self, let tap = self.tap else { return }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            // Serviced forever. The source keeps this run loop alive, and the
            // lock-window timer is scheduled here too, so neither can be held up
            // by whatever the main thread happens to be doing.
            while !Thread.current.isCancelled {
                _ = CFRunLoopRunInMode(.defaultMode, 60, false)
            }
        }
        thread.name = "com.voiceoperator.hotkey"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        return true
    }

    /// Hand a callback to the main thread. `DispatchQueue.main` is FIFO, so a
    /// start can never overtake the stop that preceded it.
    private func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
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
                onMain { [weak self] in
                    self?.modeDecision = nil
                    self?.onStop?()
                }
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
                let action: Action?
                switch keycode {
                case Self.vKeycode: action = onRepaste
                case Self.bKeycode: action = onToggleMute
                case Self.sKeycode: action = onSpeakClipboard
                case Self.aKeycode: action = onSummarizeClipboard
                case Self.nKeycode: action = onSkip
                case Self.jKeycode: action = onFocusLast
                default: action = nil
                }
                if let action { onMain { action() } }
            }
            return
        }
        guard type == .flagsChanged else { return }
        // Track Control from every modifier change — including the ones that carry
        // some *other* keycode, which is exactly how the second half of an
        // Fn-then-Control chord reaches us. A Control press while the current
        // dictation's mode window is still open promotes it to command mode.
        controlDown = event.flags.contains(.maskControl)
        if controlDown {
            onMain { [weak self] in self?.modeDecision?.noteControlPressed() }
        }
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.rawValue
        guard keycode == Self.triggerKeycode else { return }
        let down = (flags & Self.triggerBit) != 0
        if down == isDown { return }   // ignore duplicates / confounding modifiers
        isDown = down
        if down { keyDown(at: event.timestamp) } else { keyUp(at: event.timestamp) }
    }

    private func keyDown(at timestamp: UInt64) {
        switch gesture {
        case .idle:
            // Start capturing this instant. Everything else — hold vs. tap vs.
            // double-tap, paste vs. command — is decided later, while audio is
            // already flowing.
            downTimestamp = timestamp
            downTime = Date()
            gesture = .holding
            // `DictationModeDecision` is `@MainActor`, so create it on main with
            // the Control state observed on this thread at the key event. FIFO
            // on `DispatchQueue.main` keeps a following Control press's hop
            // ordered after this creation.
            let controlAlreadyDown = controlDown
            let trace = DictationTrace()
            onMain { [weak self] in
                guard let self else { return }
                let decision = DictationModeDecision(controlAlreadyDown: controlAlreadyDown)
                self.modeDecision = decision
                self.onStart?(decision, trace)
            }
        case .awaitingLock:
            // Second press inside the window: hands-free from here on.
            cancelLockTimer()
            gesture = .locked
        case .locked:
            gesture = .idle
            onMain { [weak self] in self?.onStop?() }
        case .holding:
            break   // duplicate down; the isDown guard normally filters these
        }
    }

    /// How long the key was actually held, measured between the two events'
    /// **own** timestamps. Reading the clock here instead would measure how long
    /// we took to get to them, which is a different and much less useful number:
    /// a delivery hiccup would turn a 30 ms tap into a "hold" and stop a
    /// dictation the user was double-tapping to lock on.
    ///
    /// `CGEvent.timestamp` is nanoseconds since boot (Apple's
    /// `CGEventTimestamp` docs). It is *not* mach absolute time — converting
    /// with `mach_timebase_info` on a machine whose timebase is 125/3 inflated
    /// every duration by ~42×, so a quick tap read as a >500 ms hold, the
    /// first half of a double-tap stopped the dictation, and the second press
    /// started a brand-new one instead of locking.
    private func heldDuration(upTimestamp: UInt64) -> TimeInterval {
        guard downTimestamp != 0, upTimestamp > downTimestamp else {
            return Date().timeIntervalSince(downTime)
        }
        return Double(upTimestamp - downTimestamp) / 1_000_000_000
    }

    private func keyUp(at timestamp: UInt64) {
        switch gesture {
        case .holding:
            let held = heldDuration(upTimestamp: timestamp)
            guard held < lockWindow else {
                // A real hold — this is push-to-talk, so stop on release.
                gesture = .idle
                onMain { [weak self] in self?.onStop?() }
                return
            }
            // Too quick to tell apart from the first half of a double-tap. Keep
            // recording (and keep uploading) until the window closes; if no
            // second press lands, stop then. The extra audio is free — worst case
            // it is a few hundred ms of room tone at the end of the clip.
            gesture = .awaitingLock
            lockTimer?.invalidate()
            let timer = Timer(timeInterval: max(0, lockWindow - held), repeats: false) { [weak self] _ in
                guard let self, self.gesture == .awaitingLock else { return }
                self.lockTimer = nil
                self.gesture = .idle
                self.onMain { [weak self] in self?.onStop?() }
            }
            // Scheduled on *this* thread's run loop, alongside the tap, so the
            // second press of a double-tap and the timer that would otherwise end
            // the dictation are ordered against each other by the same loop.
            // .common because menu tracking (and any other mode switch) parks a
            // default-mode timer, and the dictation it is supposed to end never
            // stops: mic open, audio uploading, system output muted, indefinitely.
            RunLoop.current.add(timer, forMode: .common)
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
