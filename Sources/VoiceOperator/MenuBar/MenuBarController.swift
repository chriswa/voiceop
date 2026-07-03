import AppKit

/// Owns the menu bar status item: a bullhorn silhouette that tints red while
/// recording and green while playing audio. Hosts the dropdown menu: status,
/// two independent toggles (dictation pause / narration mute), the recent-updates
/// and recent-dictations history, and Quit.
///
/// History submenus are rebuilt on open from the supplied providers.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let statusMenuItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
    private let pauseMenuItem = NSMenuItem(
        title: "Pause Dictation", action: #selector(togglePause), keyEquivalent: "d")
    private let narrationMenuItem = NSMenuItem(
        title: "Mute Claude Updates", action: #selector(toggleNarration), keyEquivalent: "m")
    private let loginMenuItem = NSMenuItem(
        title: "Open at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let ttsHistoryItem = NSMenuItem(title: "Recent Updates", action: nil, keyEquivalent: "")
    private let sttHistoryItem = NSMenuItem(title: "Recent Dictations", action: nil, keyEquivalent: "")

    var onTogglePause: ((Bool) -> Void)?
    var onToggleNarration: ((Bool) -> Void)?
    var onRestart: (() -> Void)?
    /// Returns the current launch-at-login state (for the checkmark).
    var launchAtLoginState: (() -> Bool)?
    /// Toggle launch-at-login; return the new effective state for the checkmark.
    var onToggleLaunchAtLogin: (() -> Bool)?
    // History providers + actions, supplied by the coordinator.
    var ttsHistoryProvider: (() -> [TTSHistoryEntry])?
    var sttHistoryProvider: (() -> [STTHistoryEntry])?
    /// Per-entry replay-audio state suffix + whether replay is currently useful.
    var ttsReplayStateProvider: ((UUID) -> TTSEngine.AudioState)?
    var onReplayTTS: ((UUID) -> Void)?
    var onSurfaceTTS: ((UUID) -> Void)?
    var onMoreDetailsTTS: ((UUID) -> Void)?
    var onRetrySTT: ((UUID) -> Void)?
    var onCopySTT: ((UUID) -> Void)?

    private(set) var isPaused = false
    private(set) var isNarrationMuted = false

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        buildMenu()
        apply(.idle)
    }

    private func buildMenu() {
        menu.delegate = self
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        pauseMenuItem.target = self
        menu.addItem(pauseMenuItem)
        narrationMenuItem.target = self
        menu.addItem(narrationMenuItem)
        loginMenuItem.target = self
        menu.addItem(loginMenuItem)
        menu.addItem(.separator())
        ttsHistoryItem.submenu = NSMenu()
        menu.addItem(ttsHistoryItem)
        sttHistoryItem.submenu = NSMenu()
        menu.addItem(sttHistoryItem)
        menu.addItem(.separator())
        let restart = NSMenuItem(title: "Restart Voice Operator", action: #selector(restartApp), keyEquivalent: "r")
        restart.target = self
        menu.addItem(restart)
        let quit = NSMenuItem(title: "Quit Voice Operator",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    // Rebuild history submenus each time the menu opens (fresh ages/entries).
    func menuWillOpen(_ menu: NSMenu) {
        rebuildTTSHistory()
        rebuildSTTHistory()
        loginMenuItem.state = (launchAtLoginState?() ?? false) ? .on : .off
    }

    private func rebuildTTSHistory() {
        let entries = ttsHistoryProvider?() ?? []
        let sub = NSMenu()
        if entries.isEmpty {
            sub.addItem(disabledItem("No updates yet"))
        } else {
            for e in entries {
                // Indicate whether replay is free (cached), still synthesizing,
                // or would re-synthesize (cache expired).
                var suffix = ""
                switch ttsReplayStateProvider?(e.id) ?? .ready {
                case .ready:          suffix = ""
                case .synthesizing:   suffix = "  ⋯ synthesizing"
                case .needsSynthesis: suffix = "  ↻ re-synthesize"
                }
                let item = NSMenuItem(title: e.menuTitle + suffix, action: nil, keyEquivalent: "")
                item.toolTip = "\(e.name) here. \(e.body)"
                let actions = NSMenu()
                let replay = NSMenuItem(title: "Replay", action: #selector(replayTTS(_:)), keyEquivalent: "")
                replay.target = self; replay.representedObject = e.id
                let surface = NSMenuItem(title: "Focus", action: #selector(surfaceTTS(_:)), keyEquivalent: "")
                surface.target = self; surface.representedObject = e.id
                let more = NSMenuItem(title: "More details", action: #selector(moreDetailsTTS(_:)), keyEquivalent: "")
                more.target = self; more.representedObject = e.id
                actions.addItem(replay)
                actions.addItem(surface)
                actions.addItem(more)
                item.submenu = actions
                sub.addItem(item)
            }
        }
        ttsHistoryItem.submenu = sub
    }

    private func rebuildSTTHistory() {
        let entries = sttHistoryProvider?() ?? []
        let sub = NSMenu()
        if entries.isEmpty {
            sub.addItem(disabledItem("No dictations yet"))
        } else {
            for e in entries {
                let item = NSMenuItem(title: e.menuTitle, action: nil, keyEquivalent: "")
                item.toolTip = e.transcript
                let actions = NSMenu()
                let retry = NSMenuItem(title: "Retry transcription", action: #selector(retrySTT(_:)), keyEquivalent: "")
                retry.target = self; retry.representedObject = e.id
                let copy = NSMenuItem(title: "Copy transcription", action: #selector(copySTT(_:)), keyEquivalent: "")
                copy.target = self; copy.representedObject = e.id
                copy.isEnabled = !e.transcript.isEmpty
                actions.addItem(retry)
                actions.addItem(copy)
                item.submenu = actions
                sub.addItem(item)
            }
        }
        sttHistoryItem.submenu = sub
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func replayTTS(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { onReplayTTS?(id) }
    }
    @objc private func surfaceTTS(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { onSurfaceTTS?(id) }
    }
    @objc private func moreDetailsTTS(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { onMoreDetailsTTS?(id) }
    }
    @objc private func retrySTT(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { onRetrySTT?(id) }
    }
    @objc private func copySTT(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { onCopySTT?(id) }
    }

    @objc private func togglePause() {
        isPaused.toggle()
        pauseMenuItem.title = isPaused ? "Resume Dictation" : "Pause Dictation"
        onTogglePause?(isPaused)
    }

    @objc private func toggleNarration() {
        isNarrationMuted.toggle()
        narrationMenuItem.title = isNarrationMuted ? "Unmute Claude Updates" : "Mute Claude Updates"
        onToggleNarration?(isNarrationMuted)
    }

    @objc private func restartApp() { onRestart?() }

    @objc private func toggleLaunchAtLogin() {
        let enabled = onToggleLaunchAtLogin?() ?? false
        loginMenuItem.state = enabled ? .on : .off
    }

    // MARK: - Status icon

    func update(status: OperatorStatus) {
        if Thread.isMainThread { apply(status) }
        else { DispatchQueue.main.async { self.apply(status) } }
    }

    private func apply(_ status: OperatorStatus) {
        guard let button = statusItem.button else { return }
        button.image = Self.bullhorn(tinted: status.tint)
        button.image?.accessibilityDescription = status.accessibilityLabel
        statusMenuItem.title = status.accessibilityLabel
    }

    /// A bullhorn (megaphone) silhouette. Template (adapts to menu bar) when
    /// untinted; solid red (recording) or green (playing) otherwise.
    private static func bullhorn(tinted tint: NSColor?) -> NSImage {
        let symbol = NSImage(systemSymbolName: "megaphone.fill",
                             accessibilityDescription: "Voice Operator")
            ?? NSImage(size: NSSize(width: 18, height: 18))
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let base = symbol.withSymbolConfiguration(config) ?? symbol

        guard let tint else {
            base.isTemplate = true
            return base
        }
        let tinted = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }
}
