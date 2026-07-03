import AppKit
import Carbon.HIToolbox

/// Inserts text into the frontmost app the way Wispr does: save the pasteboard,
/// write our text, synthesize ⌘V, then restore the original pasteboard shortly
/// after so the user's clipboard survives (DESIGN.md "Text insertion").
///
/// We use the straightforward save→set→paste→restore rather than Wispr's lazy
/// `NSPasteboardItemDataProvider`; the restore delay covers the async paste.
/// Requires the Accessibility grant (to post synthetic key events).
@MainActor
enum TextInserter {
    /// Restore delay after ⌘V, matching Wispr's ~500 ms.
    private static let restoreDelay: TimeInterval = 0.5

    func paste(_ text: String) { Self.paste(text) }

    static func paste(_ text: String) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        let saved = snapshot(pb)

        pb.clearContents()
        pb.setString(text, forType: .string)
        sendCommandV()

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

    // MARK: - Synthetic ⌘V

    private static func sendCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
