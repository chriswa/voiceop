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
        button.image = Self.icon(status: currentStatus, muted: muted)
        button.image?.accessibilityDescription = currentStatus.accessibilityLabel
    }

    /// Preserve the original megaphone and its red/magenta/yellow/cyan/green
    /// status palette. Idle remains a template image so macOS adapts it to the
    /// menu-bar appearance.
    private static func icon(status: OperatorStatus, muted: Bool) -> NSImage {
        let base = NSImage(systemSymbolName: "megaphone.fill", accessibilityDescription: "Voice Operator")
        let symbol = base?.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            ?? NSImage(size: NSSize(width: 18, height: 18))
        let template = status.tint == nil && !muted
        let color = status.tint ?? .labelColor
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            if !template { color.set(); rect.fill(using: .sourceAtop) }
            if muted {
                color.setStroke()
                let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)); path.lineWidth = 1.5; path.stroke()
                let slash = NSBezierPath(); slash.move(to: NSPoint(x: rect.minX + 2, y: rect.maxY - 2)); slash.line(to: NSPoint(x: rect.maxX - 2, y: rect.minY + 2)); slash.lineWidth = 1.5; slash.stroke()
            }
            return true
        }
        image.isTemplate = template
        return image
    }
}
