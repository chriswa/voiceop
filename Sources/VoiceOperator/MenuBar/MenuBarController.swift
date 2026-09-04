import AppKit
import Carbon

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let status = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
    /// Shown only while some app holds secure event input — see `update(secureInputHolder:)`.
    private let secureInputWarning = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// Shown only while dictation is on the slow fallback path — see `update(streamHealth:)`.
    private let streamWarning = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let mute = NSMenuItem(title: "Mute Speech", action: #selector(toggleMute), keyEquivalent: "")
    private let tapToToggle = NSMenuItem(title: "Tap to Toggle Dictation", action: #selector(toggleTapToToggle), keyEquivalent: "")
    private let wordOverlay = NSMenuItem(title: "Word Overlay", action: #selector(toggleWordOverlay), keyEquivalent: "")
    private let muteSystemAudio = NSMenuItem(title: "Mute System Audio While Dictating", action: #selector(toggleMuteSystemAudio), keyEquivalent: "")
    private let stt = NSMenuItem(title: "Recent Dictations", action: nil, keyEquivalent: "")
    private let commands = NSMenuItem(title: "Recent Commands", action: nil, keyEquivalent: "")
    var onMuteSpeech: ((Bool) -> Void)?
    var onSpeakClipboard: (() -> Void)?
    var onSummarizeClipboard: (() -> Void)?
    var onRestart: (() -> Void)?
    var launchAtLoginState: (() -> Bool)?
    var onToggleLaunchAtLogin: (() -> Bool)?
    /// Reads and flips the tap-to-toggle trigger preference. The flip closure
    /// returns the state afterwards so the checkmark can follow it.
    var tapToToggleState: (() -> Bool)?
    var onToggleTapToToggle: (() -> Bool)?
    var wordOverlayState: (() -> Bool)?
    var onToggleWordOverlay: (() -> Bool)?
    /// Reads and flips whether a dictation hardware-mutes the system output for
    /// its duration. Same shape as the other preference toggles: the flip closure
    /// returns the state afterwards so the checkmark follows it.
    var muteSystemAudioState: (() -> Bool)?
    var onToggleMuteSystemAudio: (() -> Bool)?
    var sttHistoryProvider: (() -> [STTHistoryEntry])?
    var commandHistoryProvider: (() -> [CommandHistoryEntry])?
    var onRetrySTT: ((UUID) -> Void)?
    var onCopySTT: ((UUID) -> Void)?
    var onRetryCommand: ((UUID) -> Void)?
    var onCopyCommand: ((UUID) -> Void)?
    /// The menu opened (true) or closed (false). Its items carry the same ⌘⌃
    /// shortcuts the global tap watches for, and AppKit fires them itself while
    /// the menu is open, so the tap must stand down for exactly that window.
    var onMenuOpenChanged: ((Bool) -> Void)?
    private var muted = false
    private var currentStatus: OperatorStatus = .idle
    private var currentStyle: TranscriptStyle = .normal
    private var streamHealth: StreamHealth = .unverified

    override init() {
        super.init(); menu.delegate = self; status.isEnabled = false; menu.addItem(status)
        secureInputWarning.isEnabled = false; secureInputWarning.isHidden = true
        menu.addItem(secureInputWarning)
        streamWarning.isEnabled = false; streamWarning.isHidden = true
        menu.addItem(streamWarning)
        mute.keyEquivalent = "b"; mute.keyEquivalentModifierMask = [.command, .control]
        mute.target = self; menu.addItem(mute); menu.addItem(.separator())
        stt.submenu = NSMenu(); commands.submenu = NSMenu(); menu.addItem(stt); menu.addItem(commands)
        menu.addItem(.separator())
        // Real key equivalents, so each item shows its shortcut right-aligned the
        // way every other menu does. While the menu is open AppKit fires these
        // itself, so the tap's copy of the same chord is muted for that window
        // (see `onMenuOpenChanged` and `HotkeyMonitor.chordsSuppressed`) — without
        // that, opening the menu and pressing ⌘⌃S would speak the clipboard twice.
        let speak = NSMenuItem(title: "Speak Clipboard", action: #selector(speakClipboard), keyEquivalent: "s")
        speak.keyEquivalentModifierMask = [.command, .control]
        speak.target = self; menu.addItem(speak)
        let summarize = NSMenuItem(title: "Summarize Clipboard", action: #selector(summarizeClipboard), keyEquivalent: "a")
        summarize.keyEquivalentModifierMask = [.command, .control]
        summarize.target = self; menu.addItem(summarize)
        menu.addItem(.separator())
        tapToToggle.target = self; menu.addItem(tapToToggle)
        wordOverlay.target = self; menu.addItem(wordOverlay)
        muteSystemAudio.target = self; menu.addItem(muteSystemAudio)
        let copyPath = NSMenuItem(title: "Copy Log Path", action: #selector(copyLogPath), keyEquivalent: "")
        copyPath.target = self; menu.addItem(copyPath)
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self; menu.addItem(login)
        // Which build is running, right next to the item that restarts it: the
        // version changing is how you know the restart picked up the last build
        // (see BuildInfo).
        let version = NSMenuItem(title: BuildInfo.menuLabel, action: nil, keyEquivalent: "")
        version.isEnabled = false; menu.addItem(version)
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
    /// Name the app holding secure event input, or nil when it is off. While it is
    /// on the ⌘⌃ shortcuts get no key events at all (see `SecureInput`), so the
    /// menu says which app to turn it off in rather than leaving them dead and
    /// unexplained. Dictation is unaffected, so the rest of the menu stays normal.
    func update(secureInputHolder: String?) {
        guard let holder = secureInputHolder else { secureInputWarning.isHidden = true; return }
        secureInputWarning.title = "⚠︎ Secure Keyboard Entry is on in \(holder) — ⌘⌃ shortcuts disabled"
        secureInputWarning.isHidden = false
    }
    /// Which transcription path dictation is getting. While it is the slow
    /// fallback the menu carries a warning line naming the reason, and the icon
    /// wears an amber badge in every state — including idle, so it is seen
    /// *before* the next dictation rather than after waiting on it.
    func update(streamHealth health: StreamHealth) {
        guard health != streamHealth else { return }
        streamHealth = health
        if let warning = health.menuWarning {
            streamWarning.title = warning; streamWarning.isHidden = false
        } else {
            streamWarning.isHidden = true
        }
        refreshIcon()
    }
    func refreshHistory() { }
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        onMenuOpenChanged?(true)
        tapToToggle.state = (tapToToggleState?() ?? false) ? .on : .off
        wordOverlay.state = (wordOverlayState?() ?? true) ? .on : .off
        muteSystemAudio.state = (muteSystemAudioState?() ?? true) ? .on : .off
        rebuild(stt.submenu!, entries: sttHistoryProvider?() ?? [], retry: onRetrySTT, copy: onCopySTT)
        rebuild(commands.submenu!, entries: commandHistoryProvider?() ?? [], retry: onRetryCommand, copy: onCopyCommand)
    }
    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        onMenuOpenChanged?(false)
    }
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
    /// Toggle narration mute from outside the menu — the global ⌘⌃B chord. Goes
    /// through the menu item's own action so the title, the icon and the mute
    /// listener stay in step however it was triggered.
    func toggleNarrationMute() { toggleMute() }
    @objc private func speakClipboard() { onSpeakClipboard?() }
    @objc private func summarizeClipboard() { onSummarizeClipboard?() }
    @objc private func restart() { onRestart?() }
    @objc private func toggleLogin() { _ = onToggleLaunchAtLogin?() }
    @objc private func toggleTapToToggle() { tapToToggle.state = (onToggleTapToToggle?() ?? false) ? .on : .off }
    @objc private func toggleWordOverlay() { wordOverlay.state = (onToggleWordOverlay?() ?? true) ? .on : .off }
    @objc private func toggleMuteSystemAudio() { muteSystemAudio.state = (onToggleMuteSystemAudio?() ?? true) ? .on : .off }
    @objc private func copyLogPath() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Log.fileURL.path, forType: .string) }

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        button.image = Self.icon(status: currentStatus, muted: muted, style: currentStyle,
                                 degraded: streamHealth.isDegraded)
        button.image?.accessibilityDescription = currentStatus.accessibilityLabel
            + (Self.badgesVisible(status: currentStatus, style: currentStyle)
               ? " (\(currentStyle.accessibilityLabel))" : "")
            + (streamHealth.isDegraded ? " — dictation on the slow path" : "")
    }

    /// Preserve the original megaphone and its red/magenta/yellow/cyan/green
    /// status palette. Idle remains a template image so macOS adapts it to the
    /// menu-bar appearance.
    static func icon(status: OperatorStatus, muted: Bool, style: TranscriptStyle = .normal,
                     degraded: Bool = false) -> NSImage {
        let showsDiscard = style.discard && (status == .listening || status == .commandListening)
        let base = NSImage(systemSymbolName: showsDiscard ? "trash.fill" : "megaphone.fill", accessibilityDescription: "Voice Operator")
        let symbol = base?.withSymbolConfiguration(.init(pointSize: showsDiscard ? 18 : 15,
                                                          weight: showsDiscard ? .bold : .regular))
            ?? NSImage(size: NSSize(width: 18, height: 18))
        // A degraded icon is badged in colour, so like the muted ring it cannot
        // be a template image even at idle.
        let template = status.tint == nil && !muted && !degraded
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
            if degraded { drawDegradedBadge(in: rect) }
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

    /// The slow-path mark: a filled amber dot in the top-right corner, ringed in
    /// the label colour (black on a light menu bar, white on a dark one) so it
    /// separates from the silhouette whatever the status tint — amber on the
    /// yellow "transcribing" icon has almost no contrast on its own. Top-right
    /// keeps it clear of the style badges, which own the bottom edge, and of the
    /// mute slash, which runs corner to corner.
    private nonisolated static func drawDegradedBadge(in rect: NSRect) {
        let diameter = round(rect.height * 0.38)
        // Inset by the ring width so the ring is not clipped at the image edge.
        let dot = NSRect(x: rect.maxX - diameter - 1, y: rect.maxY - diameter - 1, width: diameter, height: diameter)
        NSColor.labelColor.setFill(); NSBezierPath(ovalIn: dot.insetBy(dx: -1, dy: -1)).fill()
        badgeColor.setFill(); NSBezierPath(ovalIn: dot).fill()
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
