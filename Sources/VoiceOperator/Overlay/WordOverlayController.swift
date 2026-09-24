import AppKit
import CoreGraphics

/// The visual reader follows source-audio position across the retained job.
/// Context stays available during the two-second completion grace, so rewind
/// restores the original sentence and word without fetching timings again.
///
/// The words themselves live in `SpokenNarration`, which this draws. The split
/// is what lets the speech queue ask where an interruption landed without
/// depending on a panel being on screen, or on the overlay being switched on.
@MainActor
final class WordOverlayController {
    var playbackRate: Float = 1 { didSet { view?.playbackRate = playbackRate } }
    /// Where the bar sits. Takes effect immediately, mid-narration included, so
    /// ⌘⌃/ moves the bar the user is looking at rather than the next one.
    var placement: OverlayPlacement = .bottom {
        didSet {
            view?.placement = placement
            if !isVisible { panel?.orderOut(nil) }
            else if active { show(); refresh() }
        }
    }
    private var isVisible: Bool { placement != .hidden }
    private var panel: NSPanel?
    private var view: WordOverlayView?
    private var timer: Timer?
    private var previewTimer: Timer?
    private var active = false
    /// What is being said. Owned here because the overlay's lifetime matches a
    /// narration's, and read by the speech queue through this property.
    let narration = SpokenNarration()
    private var position: (() -> Double)?
    private static let warmLine = OverlayLine(text: "\u{00A0}", pivotUTF16Offset: 0, highlightRange: NSRange(location: 0, length: 0))

    func beginSession(position: @escaping () -> Double) {
        stop()
        self.position = position
    }

    @discardableResult
    func appendSentence(start: Double, prepared: TTSPrepared,
                        timings: @escaping @Sendable () async -> [WordTiming]) -> Task<Void, Never> {
        let task = narration.append(start: start, prepared: prepared, timings: timings)
        return Task { [weak self] in
            await task.value
            self?.refresh()
        }
    }

    /// ⌘⌃/ with nothing being read: flash the empty bar at its new placement
    /// for a moment, so it can be moved without starting a narration to see
    /// where it went. A press mid-narration needs none of this (the live bar
    /// moves), and `.hidden` has nothing to show.
    func previewPlacement() {
        guard !active, isVisible else { return }
        previewTimer?.invalidate()
        show()
        view?.line = nil
        let timer = Timer(timeInterval: 0.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.active else { return }
                self.panel?.orderOut(nil)
            }
        }
        // `.common`, so the flash still ends while the menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
        previewTimer = timer
    }

    func activate() {
        guard !active else { return }
        active = true
        previewTimer?.invalidate(); previewTimer = nil
        if isVisible { show() }
        view?.line = Self.warmLine
        let timer = Timer(timeInterval: 1 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    /// Hide on natural completion while retaining contexts for a quick rewind.
    func hide() {
        active = false
        timer?.invalidate(); timer = nil
        view?.line = nil
        panel?.orderOut(nil)
    }

    func stop() {
        hide()
        narration.reset()
        position = nil
    }

    func refresh() {
        guard active, isVisible, let position else { return }
        view?.line = line(at: position())
    }

    /// Pure display lookup, also used by silent tests without creating a panel.
    func line(at seconds: Double) -> OverlayLine? {
        guard let word = narration.word(at: seconds) else { return nil }
        return OverlayLine(text: word.sentenceText, pivotUTF16Offset: word.pivotOffset,
                           highlightRange: word.range)
    }

    // MARK: - Window

    private func show() {
        let panel = panel ?? makePanel()
        layout(panel)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true          // never intercepts clicks
        panel.level = .screenSaver               // above ordinary and full-screen app windows
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = WordOverlayView(frame: .zero)
        view.playbackRate = playbackRate
        view.placement = placement
        panel.contentView = view
        self.panel = panel
        self.view = view
        return panel
    }

    /// Cover the primary display. The view paints only the crosshair, the word
    /// band and the word; the rest stays transparent and click-through.
    /// Re-run on every `activate` so it follows a display reconnection.
    ///
    /// The panel spans the whole screen, menu bar included, so the view is told
    /// how tall the menu bar is: `.top` sits just under it rather than over it.
    private func layout(_ panel: NSPanel) {
        guard let screen = Self.primaryScreen else { return }
        panel.setFrame(screen.frame, display: true)
        view?.topInset = screen.frame.maxY - screen.visibleFrame.maxY
        view?.frame = panel.contentView?.bounds ?? .zero
        view?.needsDisplay = true
    }

    /// `NSScreen.main` follows keyboard focus, which can be a secondary
    /// display. Match the screen's display ID to Core Graphics' primary display
    /// ID so TTS always appears on the primary display instead.
    private static var primaryScreen: NSScreen? {
        let primaryID = CGMainDisplayID()
        return NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return number.uint32Value == primaryID
        } ?? NSScreen.screens.first
    }
}
