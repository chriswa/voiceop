import AppKit
import Carbon.HIToolbox

/// How a finished transcript gets into the frontmost app. Chosen in the menu and
/// stored in `PastePreferences`.
enum PasteTechnique: String {
    /// Put the text on the pasteboard and synthesize ⌘V. Instant at any length,
    /// and what nearly every app expects.
    case clipboard
    /// Synthesize one key event per character (`KeystrokeTyper`). Slower, and it
    /// never touches the pasteboard, so it is the escape hatch for an app that
    /// mishandles a real paste.
    case keystrokes
}

/// Inserts text into the frontmost app by whichever technique is selected.
///
/// The clipboard path works the way Wispr's does — save the pasteboard, write our
/// text, synthesize ⌘V, then restore the original shortly after so the user's
/// clipboard survives (DESIGN.md "Text insertion"). We use the straightforward
/// save→set→paste→restore rather than Wispr's lazy `NSPasteboardItemDataProvider`;
/// the restore delay covers the async paste.
///
/// Both paths require the Accessibility grant (to post synthetic key events).
@MainActor
enum TextInserter {
    /// Restore delay after ⌘V, matching Wispr's ~500 ms.
    private static let restoreDelay: TimeInterval = 0.5

    /// `completion` runs on the main actor once the text is actually in the app —
    /// after the *last* character on the keystroke path, which takes the better
    /// part of a second. Callers use it for the "inserted" cue, so the cue never
    /// claims the transcript has landed while characters are still going out.
    static func insert(_ text: String,
                       using technique: PasteTechnique = PastePreferences.technique,
                       completion: @escaping @Sendable @MainActor () -> Void = {}) {
        guard !text.isEmpty else { return }
        switch technique {
        case .clipboard: pasteViaClipboard(text); completion()
        case .keystrokes: KeystrokeTyper.type(text, completion: completion)
        }
    }

    /// Removes `text` from the frontmost app by sending one backspace per
    /// character of it. Always keystrokes — there is no clipboard equivalent —
    /// and it goes through the same serial queue as typing, so an undo can never
    /// interleave with an insertion that is still going out.
    ///
    /// It deletes by *count*, not by content: whatever now sits to the left of
    /// the caret is what goes. That is exact when the insertion is the last thing
    /// that happened, which is the case this exists for.
    static func undo(_ text: String, completion: @escaping @Sendable @MainActor () -> Void = {}) {
        guard !text.isEmpty else { return }
        KeystrokeTyper.backspace(text.count, afterModifiersClear: true, completion: completion)
    }

    // MARK: - Clipboard + ⌘V

    private static func pasteViaClipboard(_ text: String) {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)

        pb.clearContents()
        pb.setString(text, forType: .string)
        SyntheticKey.post(key: CGKeyCode(kVK_ANSI_V), flags: .maskCommand, source: SyntheticKey.makeSource())

        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            restore(saved, to: pb)
        }
    }

    // MARK: - Pasteboard save/restore

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]],
                                to pb: NSPasteboard) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        let newItems = items.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(newItems)
    }
}

/// Types text into the frontmost app one character at a time, as though the user
/// had typed it. Nothing reaches the pasteboard, and the receiving app sees only
/// its ordinary key-event path.
enum KeystrokeTyper {
    /// Gap between characters, honoured as an absolute schedule rather than a
    /// sleep between events (see `send`), so this number is the real rate: 300
    /// characters take 300 × `interval`, not that plus the cost of posting 600
    /// events. Fast enough that a sentence lands in a fraction of a second, slow
    /// enough that the receiving app's event queue keeps up — a burst posted with
    /// no spacing is where characters get dropped or reordered.
    static let interval: TimeInterval = 0.0005
    /// Typing runs off the main thread: a 300-character transcript takes ~450 ms,
    /// and the menu bar, the overlay and the restart coordinator all live on the
    /// main actor. Serial, so two transcripts — or a transcript and the undo of
    /// the one before it — can never interleave their characters.
    private static let queue = DispatchQueue(label: "com.voiceoperator.text-inserter.typing")

    /// One synthesized key press. `unicode`, when set, is the grapheme the event
    /// carries regardless of the physical layout; otherwise `key` speaks for
    /// itself (Return, Delete).
    private struct Keystroke: Sendable {
        var key: CGKeyCode
        var flags: CGEventFlags = []
        var unicode: [UniChar]?

        /// A newline is sent as ⇧↩ rather than a bare ↩ because the apps this
        /// path exists for — Claude Code, chat boxes — read a bare Return as
        /// "send", which would split one dictation across two messages.
        static let newline = Keystroke(key: CGKeyCode(kVK_Return), flags: .maskShift)
        static let delete = Keystroke(key: CGKeyCode(kVK_Delete))
        static func character(_ character: Character) -> Keystroke {
            Keystroke(key: 0, unicode: Array(character.utf16))
        }
    }

    /// Types `text`, one grapheme per key event.
    static func type(_ text: String, completion: @escaping @Sendable @MainActor () -> Void = {}) {
        send(text.map { $0.isNewline ? .newline : .character($0) }, completion: completion)
    }

    /// Sends `count` backspaces. One per grapheme is what the caller wants,
    /// because that is what a text view deletes per press and what `type` emits
    /// per press.
    static func backspace(_ count: Int,
                          afterModifiersClear: Bool = false,
                          completion: @escaping @Sendable @MainActor () -> Void = {}) {
        send(Array(repeating: .delete, count: max(0, count)),
             afterModifiersClear: afterModifiersClear,
             completion: completion)
    }

    /// Posts `keystrokes` on an absolute schedule — event *i* fires at
    /// `start + i × interval` — so the cost of building and posting each pair is
    /// absorbed by the gap instead of added to it. Sleeping between events
    /// instead lets that cost accumulate: measured, a nominal 0.5 ms became
    /// 0.78 ms per character.
    private static func send(_ keystrokes: [Keystroke],
                             afterModifiersClear: Bool = false,
                             completion: @escaping @Sendable @MainActor () -> Void) {
        queue.async {
            if afterModifiersClear { waitForModifiersToClear() }
            let source = SyntheticKey.makeSource()
            let start = Date()
            var due = start
            for keystroke in keystrokes {
                Thread.sleep(until: due)
                SyntheticKey.post(key: keystroke.key,
                                  flags: keystroke.flags,
                                  unicode: keystroke.unicode,
                                  source: source)
                due.addTimeInterval(interval)
                // A post slow enough to miss its slot must not be repaid by
                // firing the backlog with no gap at all — that burst is the thing
                // the spacing exists to prevent. Give up the lost time instead.
                let now = Date()
                if due < now { due = now.addingTimeInterval(interval) }
            }
            let elapsed = Date().timeIntervalSince(start)
            Log.log(String(format: "keystroke typer: %d event(s) in %.0f ms (%.2f ms each, target %.2f)",
                           keystrokes.count, elapsed * 1000,
                           keystrokes.isEmpty ? 0 : elapsed / Double(keystrokes.count) * 1000,
                           interval * 1000))
            Task { @MainActor in completion() }
        }
    }

    /// Waits (on `queue`, never the main thread) for the user to let go of every
    /// modifier before the first event goes out.
    ///
    /// The chords fire on key-down, so ⌘ and ⌃ are still physically held when an
    /// undo starts, and it takes ~1.5 ms per character to finish. Our events carry
    /// their own empty flags, but an app that consults the *hardware* modifier
    /// state instead reads each Delete as ⌘⌫ — delete-to-line-start in a text
    /// field, "move to Trash" in Finder. Waiting removes the overlap entirely.
    ///
    /// The timeout is the escape hatch for a modifier the system thinks is stuck:
    /// late backspaces beat none at all.
    private static func waitForModifiersToClear(timeout: TimeInterval = 2) {
        let held: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if CGEventSource.flagsState(.combinedSessionState).isDisjoint(with: held) { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        Log.log("keystroke typer: modifiers still held after \(timeout)s — sending anyway")
    }
}

/// The one place synthetic key events are built, so every posted event gets the
/// same treatment whichever technique produced it.
enum SyntheticKey {
    static func makeSource() -> CGEventSource? { CGEventSource(stateID: .combinedSessionState) }

    /// Posts one down/up pair. `flags` is always set explicitly, never left to be
    /// inherited: the source reports the *hardware* modifier state, so a modifier
    /// the user still happens to be holding would otherwise ride along on every
    /// character we type.
    static func post(key: CGKeyCode,
                     flags: CGEventFlags,
                     unicode: [UniChar]? = nil,
                     source: CGEventSource?) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }
        for event in [down, up] {
            event.flags = flags
            if let unicode, !unicode.isEmpty {
                event.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode)
            }
            event.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
