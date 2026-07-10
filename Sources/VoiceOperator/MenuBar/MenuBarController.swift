import AppKit

/// Owns the menu bar status item: a bullhorn silhouette that tints red while
/// recording and green while playing audio. Hosts the dropdown menu: status,
/// two independent toggles (dictation pause / narration mute), the recent-updates
/// and recent-dictations history, a read-only "Command Patterns" reference, and Quit.
///
/// History submenus are rebuilt on open from the supplied providers.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let statusMenuItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
    private let skipItem = NSMenuItem(title: "Skip", action: #selector(skip), keyEquivalent: "n")
    private let focusAgentItem = NSMenuItem(title: "Focus last speaker", action: #selector(focusAgent), keyEquivalent: "j")
    // Key equivalents here are purely the right-aligned shortcut HINT in the menu.
    // The shortcuts fire globally via the CGEvent tap (HotkeyMonitor), since a
    // menu-bar accessory holds no keyboard focus while its menu is closed. While
    // the menu IS open its own key equivalents fire, so the tap is suppressed then
    // (see onMenuOpenChanged) to avoid a double trigger.
    private let narrationMenuItem = NSMenuItem(
        title: "Mute", action: #selector(toggleNarration), keyEquivalent: "")
    private let announceBlocksItem = NSMenuItem(
        title: "Use Hooks for Interactive Feedback", action: #selector(toggleAnnounceBlocks), keyEquivalent: "")
    private let loginMenuItem = NSMenuItem(
        title: "Open at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let ttsHistoryItem = NSMenuItem(title: "Recent Updates", action: nil, keyEquivalent: "")
    private let sttHistoryItem = NSMenuItem(title: "Recent Dictations", action: nil, keyEquivalent: "")
    private let cmdHistoryItem = NSMenuItem(title: "Recent Commands", action: nil, keyEquivalent: "")

    var onToggleNarration: ((Bool) -> Void)?
    /// Skip the clip playing now (same as ⌘⌃N). Only enabled while playing.
    var onSkip: (() -> Void)?
    /// Whether a clip is playing now, to enable/disable the "Skip" item on open.
    var isPlayingProvider: (() -> Bool)?
    /// Speak the current clipboard aloud (same as ⌘⌃S).
    var onSpeakClipboard: (() -> Void)?
    /// Summarize the current clipboard via Haiku and write it back to the clipboard.
    var onSummarizeClipboard: (() -> Void)?
    /// Fired when the menu opens (true) / closes (false), so the CGEvent-tap
    /// shortcuts can be suppressed while the menu handles its own key equivalents.
    var onMenuOpenChanged: ((Bool) -> Void)?
    /// Current on/off state of question/plan announcements (reads settings.json).
    var announceBlocksState: (() -> Bool)?
    /// Toggle question/plan announcements to `desired`; returns the effective new
    /// state (in case install/uninstall failed) for the checkmark.
    var onToggleAnnounceBlocks: ((Bool) -> Bool)?
    var onRestart: (() -> Void)?
    /// The agent to offer under "Focus <name>" (current/most-recent), or nil.
    var focusAgentProvider: (() -> (name: String, sessionKey: String)?)?
    /// Focus the given session's surface.
    var onFocusAgent: ((String) -> Void)?
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
    var onRetrySTT: ((UUID) -> Void)?
    var onCopySTT: ((UUID) -> Void)?
    var commandHistoryProvider: (() -> [CommandHistoryEntry])?
    var onRetryCommand: ((UUID) -> Void)?
    var onCopyCommand: ((UUID) -> Void)?

    private(set) var isNarrationMuted = false
    private var currentStatus: OperatorStatus = .idle
    private var unreadCount = 0

    /// The ⌘⌃ chord shared by every hinted shortcut (Mute, Speak, Summarize).
    private static let chordMask: NSEvent.ModifierFlags = [.command, .control]

    /// Read-only documentation of the voice-command grammar for the "Command
    /// Patterns" menu — these items do nothing when clicked. Prose mirror of
    /// `AppCoordinator.handleVoiceCommand`; keep it in sync when the grammar changes.
    /// `⟨…⟩` marks a spoken placeholder (an agent call-sign or free text).
    private static let commandPatterns: [(pattern: String, help: String)] = [
        ("⟨name⟩", "Focus that agent's surface"),
        ("⟨name⟩ focus", "Focus it (explicit synonym)"),
        ("⟨name⟩ repeat", "Replay its latest update"),
        ("⟨name⟩ ⟨message⟩", "Ask the summarizer about the update"),
        ("skip", "Drop the clip playing now"),
    ]

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        buildMenu()
        refreshIcon()
    }

    private func buildMenu() {
        menu.delegate = self
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        skipItem.target = self
        skipItem.keyEquivalentModifierMask = Self.chordMask   // ⌘⌃N (hint only; tap fires it)
        menu.addItem(skipItem)
        focusAgentItem.target = self
        focusAgentItem.keyEquivalentModifierMask = Self.chordMask   // ⌘⌃J (hint only; tap fires it)
        menu.addItem(focusAgentItem)
        menu.addItem(.separator())
        narrationMenuItem.target = self
        narrationMenuItem.keyEquivalent = "b"          // ⌘⌃B (hint only; tap fires it)
        narrationMenuItem.keyEquivalentModifierMask = Self.chordMask
        menu.addItem(narrationMenuItem)
        menu.addItem(.separator())
        ttsHistoryItem.submenu = NSMenu()
        menu.addItem(ttsHistoryItem)
        sttHistoryItem.submenu = NSMenu()
        menu.addItem(sttHistoryItem)
        cmdHistoryItem.submenu = NSMenu()
        menu.addItem(cmdHistoryItem)
        let patternsItem = NSMenuItem(title: "Command Patterns", action: nil, keyEquivalent: "")
        patternsItem.submenu = buildCommandPatternsMenu()   // static; documentation only
        menu.addItem(patternsItem)
        menu.addItem(.separator())
        // Clipboard actions. The key equivalents render the right-aligned shortcut
        // hint; the shortcuts themselves fire via the CGEvent tap (HotkeyMonitor).
        let speakClip = NSMenuItem(title: "Speak Clipboard",
                                   action: #selector(speakClipboard), keyEquivalent: "s")
        speakClip.keyEquivalentModifierMask = Self.chordMask   // ⌘⌃S
        speakClip.target = self
        menu.addItem(speakClip)
        let summarizeClip = NSMenuItem(title: "Summarize Clipboard",
                                       action: #selector(summarizeClipboard), keyEquivalent: "a")
        summarizeClip.keyEquivalentModifierMask = Self.chordMask   // ⌘⌃A
        summarizeClip.target = self
        menu.addItem(summarizeClip)
        menu.addItem(.separator())
        // TEMP: audition every cue while we retune them.
        let tones = NSMenuItem(title: "Play Tone (debug)", action: nil, keyEquivalent: "")
        let toneMenu = NSMenu()
        for effect in SoundEffect.allCases {
            let item = NSMenuItem(title: effect.menuLabel, action: #selector(playTone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = effect
            toneMenu.addItem(item)
        }
        tones.submenu = toneMenu
        menu.addItem(tones)
        menu.addItem(.separator())
        let copyLog = NSMenuItem(title: "Copy Log Path", action: #selector(copyLogPath), keyEquivalent: "")
        copyLog.target = self
        menu.addItem(copyLog)
        loginMenuItem.target = self
        menu.addItem(loginMenuItem)   // moved to the bottom, above Restart
        announceBlocksItem.target = self
        menu.addItem(announceBlocksItem)
        let restart = NSMenuItem(title: "Restart Voice Operator", action: #selector(restartApp), keyEquivalent: "")
        restart.target = self
        menu.addItem(restart)
        let quit = NSMenuItem(title: "Quit Voice Operator",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    // Rebuild history submenus each time the menu opens (fresh ages/entries).
    func menuWillOpen(_ menu: NSMenu) {
        onMenuOpenChanged?(true)   // menu handles its own key equivalents now; mute the tap's copy
        rebuildTTSHistory()
        rebuildSTTHistory()
        rebuildCommandHistory()
        skipItem.isEnabled = isPlayingProvider?() ?? false
        loginMenuItem.state = (launchAtLoginState?() ?? false) ? .on : .off
        announceBlocksItem.state = (announceBlocksState?() ?? false) ? .on : .off
        if let agent = focusAgentProvider?() {
            focusAgentItem.title = "Focus last speaker (\(agent.name))"
            focusAgentItem.representedObject = agent.sessionKey
            focusAgentItem.isEnabled = true
        } else {
            focusAgentItem.title = "Focus last speaker (none yet)"
            focusAgentItem.representedObject = nil
            focusAgentItem.isEnabled = false
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        onMenuOpenChanged?(false)   // re-arm the CGEvent-tap shortcuts
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
                actions.addItem(replay)
                actions.addItem(surface)
                item.submenu = actions
                sub.addItem(item)
            }
        }
        ttsHistoryItem.submenu = sub
    }

    /// The history *store* retains more than the menu shows (old dictation
    /// audio is kept a week for retry/recovery); the menu lists the newest few.
    private let maxHistoryMenuEntries = 10

    private func rebuildSTTHistory() {
        let entries = (sttHistoryProvider?() ?? []).prefix(maxHistoryMenuEntries)
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

    private func rebuildCommandHistory() {
        let entries = (commandHistoryProvider?() ?? []).prefix(maxHistoryMenuEntries)
        let sub = NSMenu()
        if entries.isEmpty {
            sub.addItem(disabledItem("No commands yet"))
        } else {
            for e in entries {
                let item = NSMenuItem(title: e.menuTitle, action: nil, keyEquivalent: "")
                item.toolTip = e.recognized ? e.transcript : "\(e.transcript)  (no matching tool)"
                let actions = NSMenu()
                let retry = NSMenuItem(title: "Retry", action: #selector(retryCommand(_:)), keyEquivalent: "")
                retry.target = self; retry.representedObject = e.id
                let copy = NSMenuItem(title: "Copy transcription", action: #selector(copyCommand(_:)), keyEquivalent: "")
                copy.target = self; copy.representedObject = e.id
                copy.isEnabled = !e.transcript.isEmpty
                actions.addItem(retry)
                actions.addItem(copy)
                item.submenu = actions
                sub.addItem(item)
            }
        }
        cmdHistoryItem.submenu = sub
    }

    /// Build the static "Command Patterns" reference submenu: every item is
    /// disabled (documentation, not actions). Framed by a name-first reminder and
    /// the omit-the-name fallback so the grammar reads top to bottom.
    private func buildCommandPatternsMenu() -> NSMenu {
        let sub = NSMenu()
        sub.addItem(disabledItem("Say the agent's name first:  ⟨name⟩ …"))
        sub.addItem(.separator())
        for p in Self.commandPatterns {
            sub.addItem(disabledItem("\(p.pattern)  —  \(p.help)"))
        }
        sub.addItem(.separator())
        sub.addItem(disabledItem("No name → your words go to the last agent"))
        return sub
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
    @objc private func retryCommand(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { onRetryCommand?(id) }
    }
    @objc private func copyCommand(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { onCopyCommand?(id) }
    }
    @objc private func retrySTT(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { onRetrySTT?(id) }
    }
    @objc private func copySTT(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { onCopySTT?(id) }
    }

    @objc private func toggleNarration() { toggleNarrationMute() }

    @objc private func skip() { onSkip?() }

    @objc private func speakClipboard() { onSpeakClipboard?() }
    @objc private func summarizeClipboard() { onSummarizeClipboard?() }

    /// Flip question/plan announcements. The checkmark follows the EFFECTIVE state
    /// returned by the handler (settings.json is the source of truth), so a failed
    /// install leaves the box unchecked rather than lying.
    @objc private func toggleAnnounceBlocks() {
        let desired = !(announceBlocksState?() ?? false)
        let effective = onToggleAnnounceBlocks?(desired) ?? false
        announceBlocksItem.state = effective ? .on : .off
    }

    /// Flip narration mute, keeping the menu title, the prohibition icon overlay,
    /// and the downstream `onToggleNarration` callback in sync. Public so the
    /// ⌘⌃B global hotkey drives the exact same path as the menu item.
    func toggleNarrationMute() {
        isNarrationMuted.toggle()
        narrationMenuItem.title = isNarrationMuted ? "Unmute" : "Mute"
        onToggleNarration?(isNarrationMuted)
        refreshIcon()   // show/hide the prohibition overlay immediately
    }

    @objc private func focusAgent(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String { onFocusAgent?(key) }
    }

    // TEMP: play the selected cue from the debug "Play Tone" menu.
    @objc private func playTone(_ sender: NSMenuItem) {
        if let effect = sender.representedObject as? SoundEffect { effect.play() }
    }

    @objc private func copyLogPath() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(Log.fileURL.path, forType: .string)
    }

    @objc private func restartApp() { onRestart?() }

    @objc private func toggleLaunchAtLogin() {
        let enabled = onToggleLaunchAtLogin?() ?? false
        loginMenuItem.state = enabled ? .on : .off
    }

    // MARK: - Status icon

    func update(status: OperatorStatus) {
        onMain { self.currentStatus = status; self.refreshIcon() }
    }

    /// Update the unread badge count.
    func setUnread(_ count: Int) {
        onMain { self.unreadCount = count; self.refreshIcon() }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        button.image = Self.icon(status: currentStatus, muted: isNarrationMuted, unread: unreadCount)
        button.image?.accessibilityDescription = currentStatus.accessibilityLabel
        statusMenuItem.title = currentStatus.accessibilityLabel
    }

    // MARK: - Icon rendering

    /// Bullhorn (megaphone) composited with: a tint (red recording / magenta
    /// command / yellow transcribing / cyan fetching / green playing), a
    /// prohibition overlay when muted, and an unread-count badge. Pure idle
    /// renders as an adaptive template.
    ///
    /// Every state renders onto the same canvas (the symbol's natural size) so
    /// the menu-bar item never changes width — a width change here shifts every
    /// icon to its left in the menu bar.
    private static func icon(status: OperatorStatus, muted: Bool, unread: Int) -> NSImage {
        let base = bullhornBase()
        let hasBadge = unread > 0
        // Pure idle, unmuted, no badge → template (adapts to light/dark menu bar).
        let isTemplate = status.tint == nil && !muted && !hasBadge
        let color = status.tint ?? .labelColor
        let img = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            if !isTemplate {
                color.set()
                rect.fill(using: .sourceAtop)
            }
            if muted {
                let d = min(rect.width, rect.height) - 1.5
                let square = NSRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)
                drawProhibition(in: square, color: color)
            }
            if hasBadge { drawBadge(unread, centeredAtBottomOf: rect) }
            return true
        }
        img.isTemplate = isTemplate
        return img
    }

    private static func bullhornBase() -> NSImage {
        let symbol = NSImage(systemSymbolName: "megaphone.fill", accessibilityDescription: "Voice Operator")
            ?? NSImage(size: NSSize(width: 18, height: 18))
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        return symbol.withSymbolConfiguration(config) ?? symbol
    }

    /// A circle with a diagonal slash (the "international no" sign).
    private static func drawProhibition(in rect: NSRect, color: NSColor) {
        color.setStroke()
        let circle = NSBezierPath(ovalIn: rect)
        circle.lineWidth = 1.6
        circle.stroke()
        let c = NSPoint(x: rect.midX, y: rect.midY)
        let r = rect.width / 2
        let k = 0.707 * r
        let line = NSBezierPath()
        line.move(to: NSPoint(x: c.x - k, y: c.y + k))
        line.line(to: NSPoint(x: c.x + k, y: c.y - k))
        line.lineWidth = 1.6
        line.stroke()
    }

    /// A small red badge with the unread count, bottom-centered in the canvas.
    /// Single digits get a circle; "9+" gets a capsule that still fits the canvas.
    private static func drawBadge(_ count: Int, centeredAtBottomOf canvas: NSRect) {
        let text = count > 9 ? "9+" : "\(count)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let h: CGFloat = 12
        let w = max(h, textSize.width + 5)
        let badge = NSRect(x: canvas.midX - w / 2, y: 0, width: w, height: h)
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: badge, xRadius: h / 2, yRadius: h / 2).fill()
        let origin = NSPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2)
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }
}
