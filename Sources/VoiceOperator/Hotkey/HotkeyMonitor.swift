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
/// Gestures:
///   • **Hold** the key (past `holdThreshold`) → push-to-talk: dictate while held.
///   • **Double-tap** (two quick taps within `doubleTapWindow`) → hands-free
///     toggle: start dictating; the next key press stops it.
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
    /// Dictation started. The mode is decided by whether **Control** is held when
    /// dictation begins (Ctrl+Fn = command, Fn = paste). Read at start time — the
    /// hold threshold naturally debounces the Ctrl/Fn key-order skew.
    var onStart: ((DictationMode) -> Void)?
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

    // Fn (Globe): keycode 63 (kVK_Function), flagged by kCGEventFlagMaskSecondaryFn.
    private static let triggerKeycode: Int64 = 63
    private static let triggerBit: UInt64 = 0x800000

    private let holdThreshold: TimeInterval = 0.25
    private let doubleTapWindow: TimeInterval = 0.35

    private var tap: CFMachPort?
    private var isDown = false
    private var downTime: Date = .distantPast
    private var holdTimer: Timer?
    private var lastTapTime: Date = .distantPast

    private enum Mode { case idle, pushToTalk, toggled }
    private var mode: Mode = .idle

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
        // In hands-free toggle mode, any press ends dictation.
        if mode == .toggled {
            mode = .idle
            onStop?()
            return
        }
        downTime = Date()
        // If still held past the threshold, it's a genuine push-to-talk hold.
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: holdThreshold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isDown, self.mode == .idle else { return }
                self.mode = .pushToTalk
                self.onStart?(self.currentMode)
            }
        }
    }

    private func keyUp() {
        holdTimer?.invalidate(); holdTimer = nil
        switch mode {
        case .pushToTalk:
            mode = .idle
            onStop?()
        case .idle:
            // A short tap. Two within the window → hands-free toggle start.
            let now = Date()
            if now.timeIntervalSince(lastTapTime) <= doubleTapWindow {
                lastTapTime = .distantPast
                mode = .toggled
                onStart?(currentMode)
            } else {
                lastTapTime = now
            }
        case .toggled:
            break
        }
    }
}
