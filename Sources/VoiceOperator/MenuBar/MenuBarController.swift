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
        let showsDiscard = style.discard && (status == .listening || status == .commandListening)
        let base = NSImage(systemSymbolName: showsDiscard ? "trash.fill" : "megaphone.fill", accessibilityDescription: "Voice Operator")
        let symbol = base?.withSymbolConfiguration(.init(pointSize: showsDiscard ? 18 : 15,
                                                          weight: showsDiscard ? .bold : .regular))
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
            if badges && !showsDiscard { drawStyleBadges(style, in: rect) }
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

    /// Draw the style flags as large, transparent bottom-edge badges: `a` for a
    /// lowercased first word always occupies the left half, and a struck-through
    /// comma for stripped end punctuation always occupies the right half. This
    /// makes the positions stable as flags are enabled and disabled.
    private nonisolated static func drawStyleBadges(_ style: TranscriptStyle, in rect: NSRect) {
        let badges: [(character: String, slot: Int)] = [
            style.lowercaseFirst ? ("a", 0) : nil,
            style.trimTrailingPunctuation ? ("trimPunctuation", 1) : nil,
        ].compactMap { $0 }
        guard !badges.isEmpty else { return }

        let badgeHeight = round(rect.height * 0.5)
        let badgeWidth = rect.width / 2
        let baselineLift = round(rect.height * 0.17)
        // Use a heavy monospaced face so `a` and `x` both use their full
        // half-width slots instead of leaving a conspicuous gap between them.
        // The font's visible ink is smaller than its point size, so it is allowed
        // to be taller than half the icon for legibility at menu-bar scale.
        let font = NSFont.monospacedSystemFont(ofSize: round(rect.height * 0.9), weight: .heavy)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: badgeColor,
            // A negative stroke width fills and strokes the glyph. The heavy
            // outline makes the transparent badge readable over either the
            // coloured megaphone or the menu-bar background.
            .strokeColor: NSColor.black.withAlphaComponent(0.9),
            .strokeWidth: -5.0,
        ]

        for badge in badges {
            let badgeRect = NSRect(x: rect.minX + CGFloat(badge.slot) * badgeWidth,
                                   y: rect.minY,
                                   width: badgeWidth,
                                   height: badgeHeight)
            if badge.character == "trimPunctuation" {
                drawTrimPunctuationBadge(in: badgeRect, verticallyCenteredAt: badgeRect.midY + baselineLift)
                continue
            }
            let glyph = NSAttributedString(string: badge.character, attributes: attrs)
            let size = glyph.size()
            glyph.draw(at: NSPoint(x: badgeRect.midX - size.width / 2,
                                   y: badgeRect.midY - size.height / 2 + baselineLift))
        }
    }

    /// The terminal-punctuation marker is a purpose-drawn SVG rather than text:
    /// a thick comma struck through with an X stays legible at menu-bar scale.
    private nonisolated static func drawTrimPunctuationBadge(in rect: NSRect, verticallyCenteredAt y: CGFloat) {
        // AppKit does not reliably decode SVGs into `NSImage` outside a full
        // asset catalogue, so the checked-in PNG is the faithful raster export
        // of `Resources/trim-punctuation.svg` used at runtime.
        let sourceAsset = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/trim-punctuation.png")
        let workingDirectoryAsset = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/trim-punctuation.png")
        let candidates = [
            Bundle.main.url(forResource: "trim-punctuation", withExtension: "png"),
            sourceAsset,
            workingDirectoryAsset,
        ].compactMap { $0 }
        guard let image = candidates.lazy.compactMap(NSImage.init(contentsOf:)).first else { return }
        let frame = NSRect(x: rect.minX,
                           y: y - rect.height * 0.72,
                           width: rect.width,
                           height: rect.height * 1.44)
        image.draw(in: frame)
    }
}
