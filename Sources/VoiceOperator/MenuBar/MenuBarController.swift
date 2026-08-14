import AppKit
import Carbon

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let status = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
    private let mute = NSMenuItem(title: "Mute Speech", action: #selector(toggleMute), keyEquivalent: "")
    private let stt = NSMenuItem(title: "Recent Dictations", action: nil, keyEquivalent: "")
    private let commands = NSMenuItem(title: "Recent Commands", action: nil, keyEquivalent: "")
    var onMuteSpeech: ((Bool) -> Void)?
    var onSpeakClipboard: (() -> Void)?
    var onSummarizeClipboard: (() -> Void)?
    var onRestart: (() -> Void)?
    var launchAtLoginState: (() -> Bool)?
    var onToggleLaunchAtLogin: (() -> Bool)?
    var sttHistoryProvider: (() -> [STTHistoryEntry])?
    var commandHistoryProvider: (() -> [CommandHistoryEntry])?
    var onRetrySTT: ((UUID) -> Void)?
    var onCopySTT: ((UUID) -> Void)?
    var onRetryCommand: ((UUID) -> Void)?
    var onCopyCommand: ((UUID) -> Void)?
    private var muted = false
    private var currentStatus: OperatorStatus = .idle
    private var currentStyle: TranscriptStyle = .normal

    override init() {
        super.init(); menu.delegate = self; status.isEnabled = false; menu.addItem(status)
        mute.target = self; menu.addItem(mute); menu.addItem(.separator())
        stt.submenu = NSMenu(); commands.submenu = NSMenu(); menu.addItem(stt); menu.addItem(commands)
        menu.addItem(.separator())
        let speak = NSMenuItem(title: "Speak Clipboard", action: #selector(speakClipboard), keyEquivalent: "")
        speak.target = self; menu.addItem(speak)
        let summarize = NSMenuItem(title: "Summarize Clipboard", action: #selector(summarizeClipboard), keyEquivalent: "")
        summarize.target = self; menu.addItem(summarize)
        menu.addItem(.separator())
        let copyPath = NSMenuItem(title: "Copy Log Path", action: #selector(copyLogPath), keyEquivalent: "")
        copyPath.target = self; menu.addItem(copyPath)
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self; menu.addItem(login)
        let restart = NSMenuItem(title: "Restart Voice Operator", action: #selector(restart), keyEquivalent: "")
        restart.target = self; menu.addItem(restart)
        menu.addItem(NSMenuItem(title: "Quit Voice Operator", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        statusItem.menu = menu; update(status: .idle)
    }
    func update(status state: OperatorStatus) {
        currentStatus = state
        status.title = state.accessibilityLabel.replacingOccurrences(of: "Voice Operator — ", with: "")
        refreshIcon()
    }
    /// The transcript style of the dictation being recorded, shown as badges on
    /// the icon. Only visible while capturing, which is where the key that cycles
    /// it does anything (see `AudioArbiter.cycleTranscriptStyle`).
    func update(style: TranscriptStyle) {
        guard style != currentStyle else { return }
        currentStyle = style
        refreshIcon()
    }
    func refreshHistory() { }
    func menuWillOpen(_ menu: NSMenu) { rebuild(stt.submenu!, entries: sttHistoryProvider?() ?? [], retry: onRetrySTT, copy: onCopySTT); rebuild(commands.submenu!, entries: commandHistoryProvider?() ?? [], retry: onRetryCommand, copy: onCopyCommand) }
    private func rebuild<T>(_ menu: NSMenu, entries: [T], retry: ((UUID) -> Void)?, copy: ((UUID) -> Void)?) {
        menu.removeAllItems()
        if entries.isEmpty { menu.addItem(NSMenuItem(title: "None yet", action: nil, keyEquivalent: "")); return }
        for e in entries.prefix(10) {
            let id: UUID; let title: String
            if let x = e as? STTHistoryEntry { id = x.id; title = x.menuTitle }
            else if let x = e as? CommandHistoryEntry { id = x.id; title = x.menuTitle }
            else { continue }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(); let retryItem = NSMenuItem(title: "Retry", action: #selector(runRetry(_:)), keyEquivalent: "")
            retryItem.target = self; retryItem.representedObject = Action(id: id, handler: retry); sub.addItem(retryItem)
            let copyItem = NSMenuItem(title: "Copy transcription", action: #selector(runCopy(_:)), keyEquivalent: "")
            copyItem.target = self; copyItem.representedObject = Action(id: id, handler: copy); sub.addItem(copyItem)
            item.submenu = sub; menu.addItem(item)
        }
    }
    private final class Action: NSObject { let id: UUID; let handler: ((UUID) -> Void)?; init(id: UUID, handler: ((UUID) -> Void)?) { self.id = id; self.handler = handler } }
    @objc private func runRetry(_ sender: NSMenuItem) { (sender.representedObject as? Action)?.handler?((sender.representedObject as! Action).id) }
    @objc private func runCopy(_ sender: NSMenuItem) { (sender.representedObject as? Action)?.handler?((sender.representedObject as! Action).id) }
    @objc private func toggleMute() { muted.toggle(); mute.title = muted ? "Unmute Speech" : "Mute Speech"; refreshIcon(); onMuteSpeech?(muted) }
    @objc private func speakClipboard() { onSpeakClipboard?() }
    @objc private func summarizeClipboard() { onSummarizeClipboard?() }
    @objc private func restart() { onRestart?() }
    @objc private func toggleLogin() { _ = onToggleLaunchAtLogin?() }
    @objc private func copyLogPath() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Log.fileURL.path, forType: .string) }

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        button.image = Self.icon(status: currentStatus, muted: muted, style: currentStyle)
        button.image?.accessibilityDescription = currentStatus.accessibilityLabel
            + (Self.badgesVisible(status: currentStatus, style: currentStyle)
               ? " (\(currentStyle.accessibilityLabel))" : "")
    }

    /// Preserve the original megaphone and its red/magenta/yellow/cyan/green
    /// status palette. Idle remains a template image so macOS adapts it to the
    /// menu-bar appearance.
    static func icon(status: OperatorStatus, muted: Bool, style: TranscriptStyle = .normal) -> NSImage {
        let base = NSImage(systemSymbolName: "megaphone.fill", accessibilityDescription: "Voice Operator")
        let symbol = base?.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            ?? NSImage(size: NSSize(width: 18, height: 18))
        let template = status.tint == nil && !muted
        let color = status.tint ?? .labelColor
        let badges = badgesVisible(status: status, style: style)
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            if !template { color.set(); rect.fill(using: .sourceAtop) }
            if muted {
                color.setStroke()
                let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)); path.lineWidth = 1.5; path.stroke()
                let slash = NSBezierPath(); slash.move(to: NSPoint(x: rect.minX + 2, y: rect.maxY - 2)); slash.line(to: NSPoint(x: rect.maxX - 2, y: rect.minY + 2)); slash.lineWidth = 1.5; slash.stroke()
            }
            // After the tint fill, or `sourceAtop` would repaint the badges in the
            // status colour and they would vanish into the silhouette.
            if badges { drawStyleBadges(style, in: rect) }
            return true
        }
        // A badged icon is no longer monochrome, so it must not be a template
        // image even when the status itself would have been.
        image.isTemplate = template && !badges
        return image
    }

    /// The badges describe the dictation being recorded, so they show only while
    /// it is — the same instants the icon is red (or magenta for a command).
    private static func badgesVisible(status: OperatorStatus, style: TranscriptStyle) -> Bool {
        !style.isNormal && (status == .listening || status == .commandListening)
    }

    /// Amber, not another red: it has to sit on a red silhouette and still be
    /// picked out, without competing with "recording" for attention. Computed
    /// rather than stored so it stays outside the main actor — it is read from
    /// inside `NSImage`'s drawing handler.
    private nonisolated static var badgeColor: NSColor {
        NSColor(srgbRed: 1.0, green: 0.62, blue: 0.11, alpha: 1)
    }

    /// Draw the style flags along the bottom edge: `a` for a lowercased first
    /// word, `x` for stripped end punctuation, both when both are on.
    private nonisolated static func drawStyleBadges(_ style: TranscriptStyle, in rect: NSRect) {
        var glyphs: [String] = []
        if style.lowercaseFirst { glyphs.append("a") }
        if style.trimTrailingPunctuation { glyphs.append("x") }
        guard !glyphs.isEmpty else { return }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: round(rect.height * 0.42), weight: .bold),
            .foregroundColor: badgeColor,
            // A negative stroke width fills *and* strokes, giving each glyph its
            // own dark outline in one draw — without it, amber on red is mush at
            // menu-bar size.
            .strokeColor: NSColor.black.withAlphaComponent(0.8),
            .strokeWidth: -5.0,
        ]
        let drawn = glyphs.map { NSAttributedString(string: $0, attributes: attrs) }
        let gap: CGFloat = 1
        let total = drawn.reduce(0) { $0 + $1.size().width } + gap * CGFloat(drawn.count - 1)
        // Bottom-right: the megaphone's handle occupies the bottom-left, and its
        // horn the top, so this is the quietest corner of the silhouette. Held a
        // half-point off the edge, since the glyph's last column of antialiasing
        // would otherwise be clipped by the image bounds.
        var x = max(rect.minX, rect.maxX - total - 0.5)
        for glyph in drawn {
            glyph.draw(at: NSPoint(x: x, y: rect.minY - round(rect.height * 0.06)))
            x += glyph.size().width + gap
        }
    }
}
