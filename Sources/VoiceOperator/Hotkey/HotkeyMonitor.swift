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
///   • **⌘ pressed while the key is held** → the same hands-free lock, decided
///     mid-dictation: release the trigger whenever you like and keep talking
///     until the next press stops it. See `trackCommandLock`.
///
/// `lockWindow` matches Wispr Flow's `DICTATION_DEBOUNCE_DELAY` (500 ms), which
/// it likewise uses only to recognise a second quick press — never to delay the
/// start of capture.
///
/// ## Tap-to-toggle: a simpler alternative
///
/// Set `tapToToggle` (from the menu preference) and the trigger drops to a
/// single model: **every key-down flips recording on or off, and key-up is
/// ignored.** A first press starts dictating hands-free and the next press
/// stops it, so a hold, a tap and a double-tap all collapse to "press to start,
/// press to stop" (a double-tap being a quick start immediately stopped). It is
/// implemented as one change — a first press enters `.locked` rather than
/// `.holding` — because `.locked` already means "recording, next press ends it".
/// Everything downstream follows: key-up is a no-op in `.locked`, and the ⌘-lock
/// (which only fires from `.holding`) has nothing to do.
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
    /// Fired on ⌘⌃V — re-paste the last pasted text via the clipboard.
    var onRepaste: Action?
    /// Fired on ⌘⌃⇧V — re-insert the last pasted text by typing it.
    var onRetype: Action?
    /// Fired on ⌘⌃B — toggle narration mute.
    var onToggleMute: Action?
    /// Fired on ⌘⌃S — speak the clipboard aloud (or stop if already speaking).
    var onSpeakClipboard: Action?
    /// Fired on ⌘⌃A — summarize the clipboard via Haiku.
    var onSummarizeClipboard: Action?
    var onFasterSpeech: Action?
    var onSlowerSpeech: Action?
    var onRewindSpeech: Action?
    var onForwardSpeech: Action?
    /// A deliberate tap of the **left Shift key while a dictation is recording**:
    /// advance that dictation's `TranscriptStyle` by one. Never fires outside a
    /// dictation, and never for Shift used as a modifier — see `shiftArmed`.
    var onCycleStyle: Action?

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
    private var adjustPlaybackEnabled = false
    private var rewindPlaybackEnabled = false
    private var swallowedPlaybackKeys: Set<Int64> = [] // tap thread only
    private var lastPlaybackRepeat: UInt64 = 0

    func setPlaybackControls(canAdjust: Bool, canRewind: Bool) {
        stateLock.lock()
        adjustPlaybackEnabled = canAdjust
        rewindPlaybackEnabled = canRewind
        stateLock.unlock()
    }

    /// Selects the trigger's gesture model — see the tap-to-toggle section above.
    /// Guarded by `stateLock` because the menu flips it from the main thread while
    /// the state machine reads it on the hotkey thread (at key-down). Switching it
    /// mid-dictation needs no reset: the only difference is which state a first
    /// press enters, and every other transition already handles both.
    var tapToToggle: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return toggleMode }
        set { stateLock.lock(); toggleMode = newValue; stateLock.unlock() }
    }
    private var toggleMode = false

    /// Live Control-key state, updated from every flagsChanged event on the
    /// hotkey thread. Used only to seed `DictationModeDecision` at key-down;
    /// late Control presses are forwarded to the decision on the main thread.
    private var controlDown = false

    /// The mode decision of the dictation now in flight. Touched only on the
    /// main thread (via `onMain`), because `DictationModeDecision` is
    /// `@MainActor`. Forwarding to an already-latched decision is a no-op.
    private var modeDecision: DictationModeDecision?

    /// The ⌘⌃ chord shortcuts, as one table: keycode, the name it logs under, and
    /// the callback it fires. Kept together deliberately — a keycode constant, a
    /// switch case and a log string maintained separately are three places to
    /// forget, and a chord whose callback nobody assigned then fails
    /// indistinguishably from one the tap never saw.
    private enum Chord: CaseIterable {
        case repaste, retype, toggleMute, speakClipboard, summarizeClipboard
        case fasterSpeech, slowerSpeech, rewindSpeech, forwardSpeech

        /// The `kVK_ANSI_*` keycode the chord is typed on, and whether Shift is
        /// part of it. Shift is matched, not ignored, so two chords can share a
        /// keycode (⌘⌃V and ⌘⌃⇧V) and so a stray Shift cannot silently alias one
        /// chord onto another's handler.
        var keys: (keycode: Int64, shift: Bool) {
            switch self {
            case .repaste:            return (9, false)
            case .retype:             return (9, true)
            case .toggleMute:         return (11, false)
            case .speakClipboard:     return (1, false)
            case .summarizeClipboard: return (0, false)
            case .fasterSpeech:       return (47, false)
            case .slowerSpeech:       return (43, false)
            case .rewindSpeech:       return (123, false)
            case .forwardSpeech:      return (124, false)
            }
        }

        init?(keycode: Int64, shift: Bool) {
            guard let match = Self.allCases.first(where: { $0.keys == (keycode, shift) }) else { return nil }
            self = match
        }

        var name: String {
            switch self {
            case .repaste:            return "⌘⌃V (re-paste)"
            case .retype:             return "⌘⌃⇧V (re-type)"
            case .toggleMute:         return "⌘⌃B (toggle mute)"
            case .speakClipboard:     return "⌘⌃S (speak clipboard)"
            case .summarizeClipboard: return "⌘⌃A (summarize clipboard)"
            case .fasterSpeech:       return "⌘⌃. (faster speech)"
            case .slowerSpeech:       return "⌘⌃, (slower speech)"
            case .rewindSpeech:       return "⌘⌃← (rewind speech)"
            case .forwardSpeech:      return "⌘⌃→ (skip ahead)"
            }
        }
    }
    /// The callback a chord fires, or nil when nobody assigned one.
    private func action(for chord: Chord) -> Action? {
        switch chord {
        case .repaste:            return onRepaste
        case .retype:             return onRetype
        case .toggleMute:         return onToggleMute
        case .speakClipboard:     return onSpeakClipboard
        case .summarizeClipboard: return onSummarizeClipboard
        case .fasterSpeech:       return onFasterSpeech
        case .slowerSpeech:       return onSlowerSpeech
        case .rewindSpeech:       return onRewindSpeech
        case .forwardSpeech:      return onForwardSpeech
        }
    }

    // Fn (Globe): keycode 63 (kVK_Function), flagged by kCGEventFlagMaskSecondaryFn.
    private static let triggerKeycode: Int64 = 63
    private static let triggerBit: UInt64 = 0x800000

    /// Left Shift, by its **device-dependent** bit (`NX_DEVICELSHIFTKEYMASK`)
    /// rather than the generic `maskShift` (0x20000). The generic bit cannot tell
    /// the two Shift keys apart, so releasing the left one while the right one is
    /// still held would read as another left-Shift press.
    private static let leftShiftBit: UInt64 = 0x2
    /// Every modifier bit that is *not* left Shift, used to notice that some other
    /// modifier moved while a Shift tap was in progress (see `shiftArmed`).
    /// Enumerated rather than written `~leftShiftBit`, because an event can carry
    /// incidental non-modifier bits whose flicker would disarm a perfectly good
    /// tap: the generic masks (`alphaShift`…`secondaryFn`, 0xFF0000) and the
    /// device-dependent left/right bits (0x7F, plus right-Control at 0x2000).
    private static let otherModifierBits: UInt64 = (0x00FF_0000 | 0x0000_207F) & ~leftShiftBit

    /// The **generic** Command bit (`NSEvent.ModifierFlags.command`). Either
    /// Command key locks a dictation hands-free, so unlike left Shift there is
    /// nothing here to tell apart — see `trackCommandLock`.
    private static let commandBit: UInt64 = 0x0010_0000

    /// A left-Shift press that is still a candidate for a style-cycling *tap*.
    ///
    /// Cycling on Shift **down** would be a trap: during a hands-free locked
    /// dictation the user is free to type, and Shift is the most-pressed modifier
    /// there is — every shift-selected range and every capital letter would
    /// silently change the transcript's shape. So a press only arms the gesture,
    /// anything else pressed while Shift is held disarms it, and the cycle happens
    /// on release. A deliberate tap still costs nothing perceptible.
    private var shiftArmed = false
    private var leftShiftDown = false
    /// Live Command-key state, edge-detected so that only a *new* press locks a
    /// dictation — Command already held when the trigger went down belongs to
    /// whatever the user was doing, not to us. Compared against the real flag bit
    /// on every `flagsChanged`, so a press or release missed while the tap was
    /// disabled reconciles itself on the next event rather than sticking.
    private var commandDown = false
    /// The state of the other modifiers when the Shift press landed.
    private var shiftArmFlags: UInt64 = 0

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
            | (1 << CGEventType.keyUp.rawValue)
            // Clicks are of no interest in themselves; they only tell us a held
            // Shift is being used as a modifier (shift-click to extend a
            // selection) rather than tapped — see `shiftArmed`.
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                    if monitor.handlePlaybackKey(type: type, event: event) { return nil }
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

    /// Consume only active reader controls, so the frontmost editor/browser
    /// does not also navigate or change zoom. Everything else still passes
    /// through this tap. Menu tracking owns its own key equivalents.
    private func handlePlaybackKey(type: CGEventType, event: CGEvent) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp { return swallowedPlaybackKeys.remove(code) != nil }
        guard type == .keyDown, [43, 47, 123, 124].contains(code),
              event.flags.contains(.maskCommand), event.flags.contains(.maskControl),
              !event.flags.contains(.maskAlternate),
              !event.flags.contains(.maskShift) else { return false }
        stateLock.lock()
        let enabled = !suppressChords && (code == 123 ? rewindPlaybackEnabled : adjustPlaybackEnabled)
        stateLock.unlock()
        guard enabled, let chord = Chord(keycode: code, shift: false), let action = action(for: chord) else { return false }
        swallowedPlaybackKeys.insert(code)
        let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if repeated && event.timestamp >= lastPlaybackRepeat && event.timestamp - lastPlaybackRepeat < 150_000_000 { return true }
        lastPlaybackRepeat = event.timestamp
        Log.log("hotkey chord: \(chord.name)")
        onMain { action() }
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
            shiftArmed = false   // its release may well have been in the gap
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
        // Clicks are watched for one reason only: a Shift held across one is being
        // used as a modifier (shift-click to extend a selection), not tapped.
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            shiftArmed = false
            return
        }
        // ⌘⌃-chord keyDown shortcuts — see `Chord` for the table. Suppressed while
        // the menu is open, where the items' own key equivalents fire instead
        // (see chordsSuppressed).
        if type == .keyDown {
            // Shift was being held as a modifier for this key, not tapped.
            shiftArmed = false
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            guard event.flags.contains(.maskCommand), event.flags.contains(.maskControl) else { return }
            guard let chord = Chord(keycode: keycode, shift: event.flags.contains(.maskShift)) else { return }
            // Reader controls have their own active-only consuming handler.
            if chord == .fasterSpeech || chord == .slowerSpeech || chord == .rewindSpeech || chord == .forwardSpeech { return }
            // Every recognised chord logs, whatever becomes of it: a shortcut that
            // fires and does nothing is indistinguishable from one that never
            // arrived unless the tap says which of the two happened. (Nothing at
            // all here means the key events are not reaching us — see
            // `SecureInput`, which is the usual reason.)
            guard !chordsSuppressed else {
                Log.log("hotkey chord: \(chord.name) ignored — menu is open (its own key equivalent fires)")
                return
            }
            guard let action = action(for: chord) else {
                Log.log("hotkey chord: \(chord.name) has no handler wired — nothing to do")
                return
            }
            Log.log("hotkey chord: \(chord.name)")
            onMain { action() }
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
        trackLeftShift(flags: flags)
        trackCommandLock(flags: flags)
        guard keycode == Self.triggerKeycode else { return }
        let down = (flags & Self.triggerBit) != 0
        if down == isDown { return }   // ignore duplicates / confounding modifiers
        isDown = down
        if down { keyDown(at: event.timestamp) } else { keyUp(at: event.timestamp) }
    }

    /// Edge-detect the left Shift key and turn a clean tap of it, during a
    /// dictation, into one style cycle. Called for every `flagsChanged` event,
    /// whatever keycode it carries.
    private func trackLeftShift(flags: UInt64) {
        let down = (flags & Self.leftShiftBit) != 0
        let others = flags & Self.otherModifierBits
        guard down == leftShiftDown else {
            leftShiftDown = down
            if down {
                // Only a dictation in flight has a style to cycle; arming solely
                // while recording keeps Shift entirely ordinary the rest of the
                // time. Re-checked on release, since the dictation may have ended
                // in between (a push-to-talk release, say).
                shiftArmed = gesture != .idle
                shiftArmFlags = others
            } else {
                let tapped = shiftArmed && gesture != .idle
                shiftArmed = false
                if tapped { onMain { [weak self] in self?.onCycleStyle?() } }
            }
            return
        }
        // Shift itself did not move, so some *other* modifier did while it was
        // held: this is a chord (⇧⌘, a Ctrl+Fn landing mid-tap, …), not a tap.
        if shiftArmed, others != shiftArmFlags { shiftArmed = false }
    }

    /// Promote a push-to-talk hold to a hands-free lock when Command is pressed
    /// while the trigger key is still down. It is the third way to reach `.locked`
    /// — and the only one available *after* you have started talking, so a
    /// dictation that turns out to be longer than a hold is comfortable for does
    /// not have to be restarted as a double-tap.
    ///
    /// Two properties keep it from firing by accident:
    ///
    /// 1. **Only from `.holding`.** The trigger key is physically down, so the
    ///    user is unambiguously mid-dictation. Command is not consulted at any
    ///    other time — including during `.awaitingLock`, where the trigger has
    ///    already been released and a ⌘-shortcut the user meant for their own app
    ///    would otherwise leave the microphone open indefinitely.
    /// 2. **On the press edge, not the held state.** Command already down when the
    ///    trigger went down is somebody else's modifier and is ignored; only a
    ///    fresh press locks.
    ///
    /// Unlike the style-cycling Shift gesture this acts on key-*down* rather than
    /// waiting for a clean tap: there is no ambiguity to resolve (nothing else
    /// reads Command while the trigger is held), and locking immediately means the
    /// trigger key can be let go the instant the user thinks of it.
    private func trackCommandLock(flags: UInt64) {
        let down = (flags & Self.commandBit) != 0
        guard down != commandDown else { return }
        commandDown = down
        guard down, gesture == .holding else { return }
        gesture = .locked
        Log.log("hotkey: ⌘ pressed while holding the trigger — dictation locked hands-free")
    }

    private func keyDown(at timestamp: UInt64) {
        switch gesture {
        case .idle:
            // Start capturing this instant. Everything else — hold vs. tap vs.
            // double-tap, paste vs. command — is decided later, while audio is
            // already flowing.
            downTimestamp = timestamp
            downTime = Date()
            // Default model: begin as a hold, resolved later on the stop side.
            // Tap-to-toggle: lock immediately, so key-up is ignored and only the
            // next press stops it.
            gesture = tapToToggle ? .locked : .holding
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
