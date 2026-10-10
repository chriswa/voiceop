import AppKit

/// The small window that shows Kokoro being set up — fetching uv and Python,
/// installing packages, starting the server — so a first launch that is busy
/// downloading a gigabyte says so instead of just being silent.
///
/// Not modal: it floats, can be hidden, and dictation keeps working meanwhile.
/// It closes itself when the server answers; on a failure it stays up with the
/// reason and a way to the log.
@MainActor
final class KokoroSetupWindow: NSObject, NSWindowDelegate {
    var onCancel: (() -> Void)?
    var onShowLog: (() -> Void)?
    /// The latest line of the install log, polled while the window is up.
    var detailProvider: (() -> String?)?

    private var panel: NSPanel?
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let primary = NSButton(title: "Hide", target: nil, action: nil)
    private let secondary = NSButton(title: "Cancel", target: nil, action: nil)
    private var timer: Timer?
    /// Fixed: the log line changes twice a second and must never resize the window.
    private static let width: CGFloat = 440
    private var hiddenByUser = false

    enum State: Equatable {
        case working(step: String, progress: Double, cancellable: Bool)
        case done
        case failed(String)
    }

    /// Show or update the window for `state`. A window the user hid stays
    /// hidden while work continues, but comes back for a failure.
    func show(_ state: State) {
        switch state {
        case .working(let step, let progress, let cancellable):
            guard !hiddenByUser else { return }
            ensurePanel()
            title.stringValue = "Setting up speech: \(step)…"
            bar.isIndeterminate = false
            bar.doubleValue = progress
            primary.title = "Hide"; primary.action = #selector(hide)
            secondary.title = "Cancel"; secondary.action = #selector(cancel)
            secondary.isHidden = !cancellable
            startPolling()
        case .done:
            guard panel != nil else { return }
            title.stringValue = "Speech is ready."
            detail.stringValue = ""
            bar.doubleValue = 1
            stopPolling()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.close() }
        case .failed(let reason):
            hiddenByUser = false
            ensurePanel()
            stopPolling()
            title.stringValue = "Speech setup failed: \(reason)"
            detail.stringValue = detailProvider?() ?? ""
            primary.title = "Close"; primary.action = #selector(close)
            secondary.title = "Show Log"; secondary.action = #selector(showLog)
            secondary.isHidden = false
        }
        panel?.orderFrontRegardless()
    }

    /// The window's current width, nil when it isn't up (tests).
    var currentWidth: CGFloat? { panel?.frame.width }

    @objc func close() {
        stopPolling()
        panel?.orderOut(nil)
        panel = nil
        hiddenByUser = false
    }

    @objc private func hide() {
        hiddenByUser = true
        stopPolling()
        panel?.orderOut(nil)
        panel = nil
    }

    @objc private func cancel() { onCancel?() }
    @objc private func showLog() { onShowLog?() }

    func windowWillClose(_ notification: Notification) {
        stopPolling()
        panel = nil
        hiddenByUser = true
    }

    private func startPolling() {
        guard timer == nil else { return }
        detail.stringValue = detailProvider?() ?? ""
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.detail.stringValue = self?.detailProvider?() ?? "" }
        }
    }

    private func stopPolling() {
        timer?.invalidate(); timer = nil
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 150),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Voice Operator"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 2
        detail.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.maximumNumberOfLines = 1
        // Long text truncates or wraps inside the fixed width instead of
        // pushing the window wider.
        for label in [title, detail] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.preferredMaxLayoutWidth = Self.width - 40
        }
        bar.style = .bar
        bar.minValue = 0; bar.maxValue = 1
        for button in [primary, secondary] { button.target = self; button.bezelStyle = .rounded }
        primary.keyEquivalent = "\r"

        let buttons = NSStackView(views: [NSView(), secondary, primary])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [title, bar, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            panel.contentView!.widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        panel.center()
        self.panel = panel
    }
}
