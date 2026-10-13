import AppKit

/// The few dialogs behind the Text to Speech submenu. A menu-bar app has no
/// window to hang a sheet on, so each is a modal alert brought to the front.
@MainActor
enum TTSDialogs {
    static func confirmUninstall() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Uninstall Kokoro?"
        alert.informativeText = """
            This stops the Kokoro speech server and removes it and its Python environment. \
            Speech stays off until you choose Install Kokoro… again; \
            Voice Operator won't reinstall it on its own. \
            The downloaded voice model in ~/.cache/huggingface is left in place.
            """
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        return present(alert) == .alertFirstButtonReturn
    }

    static func showError(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        present(alert)
    }

    @discardableResult
    private static func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate()
        return alert.runModal()
    }
}
