import AppKit

/// The few dialogs behind the Text to Speech submenu. A menu-bar app has no
/// window to hang a sheet on, so each is a modal alert brought to the front.
@MainActor
enum TTSDialogs {
    /// Ask for a Kokoro-compatible server's URL. Returns the normalized URL, or
    /// nil when cancelled. Re-asks on an unusable URL rather than storing it.
    static func customServerURL(current: String?) -> String? {
        var text = current ?? ""
        while true {
            let alert = NSAlert()
            alert.messageText = "Custom TTS Server"
            alert.informativeText = """
                The base URL of a Kokoro-compatible server (it must serve /synthesize and /voices; \
                /timestamps is optional and drives the word overlay). Extra headers, such as \
                Cloudflare Access tokens, go in config.json under tts.headers.
                """
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            field.placeholderString = "https://tts.example.com"
            field.stringValue = text
            alert.accessoryView = field
            alert.addButton(withTitle: "Use This Server")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard present(alert) == .alertFirstButtonReturn else { return nil }
            text = field.stringValue
            if let url = TTSProvider.normalizedCustomURL(text) { return url }
            let bad = NSAlert()
            bad.messageText = "That isn't a usable URL"
            bad.informativeText = "Enter a full http:// or https:// address with a host name."
            present(bad)
        }
    }

    static func confirmInstall(replacingLegacy: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Install Kokoro?"
        var info = """
            Voice Operator will set up the Kokoro speech server on this Mac: a Python environment \
            of about 900 MB in Application Support, and a background service that starts at login. \
            The first start downloads the voice model (about 325 MB). It takes several minutes; \
            the Text to Speech menu shows progress.
            """
        if replacingLegacy {
            info += """


                It replaces the Kokoro setup from ~/tts: those launchd agents are stopped and their \
                plists moved aside (the ~/tts folder itself is not touched). If the new server doesn't \
                come up, the old one is put back.
                """
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        return present(alert) == .alertFirstButtonReturn
    }

    static func confirmUninstall() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Uninstall Kokoro?"
        alert.informativeText = """
            This stops the Kokoro speech server and removes it and its Python environment. \
            Speech stays off until Kokoro is installed again or a custom server is chosen. \
            The downloaded voice model in ~/.cache/huggingface is left in place.
            """
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        return present(alert) == .alertFirstButtonReturn
    }

    static let uvInstallCommand = "curl -LsSf https://astral.sh/uv/install.sh | sh"

    /// Installing needs `uv`; say how to get it rather than fetching it ourselves.
    static func showUVMissing() {
        let alert = NSAlert()
        alert.messageText = "Kokoro needs uv"
        alert.informativeText = """
            Installing Kokoro uses uv, Astral's Python package manager, which isn't installed. \
            Install it in Terminal with Homebrew:

                brew install uv

            or with Astral's installer:

                \(uvInstallCommand)

            Then choose Install Kokoro… again.
            """
        alert.addButton(withTitle: "Copy Homebrew Command")
        alert.addButton(withTitle: "Copy Installer Command")
        alert.addButton(withTitle: "OK")
        let command: String?
        switch present(alert) {
        case .alertFirstButtonReturn: command = "brew install uv"
        case .alertSecondButtonReturn: command = uvInstallCommand
        default: command = nil
        }
        if let command {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
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
