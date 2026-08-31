import AppKit

/// Shows the word currently being spoken as a crosshair-anchored overlay,
/// flipping words in time with TTS playback.
///
/// Visibility is job-scoped, timing is sentence-scoped. `activate()` puts the
/// overlay on screen the moment synthesis begins — before any audio — so the
/// window is already warm and no per-sentence spin-up eats the opening words;
/// it then stays up (showing just the crosshair between sentences) until the
/// whole job finishes and `stop()` hides it. `begin(anchor:)` (re)starts the
/// word clock for one sentence, anchored at its first audible sample.
///
/// The clock is monotonic wall-time from that anchor, not playback callbacks:
/// Kokoro plays a sentence's audio contiguously, so elapsed time tracks the
/// audio position closely enough to highlight words without threading a sample
/// clock out of the player.
@MainActor
final class WordOverlayController {
    /// Master on/off. When false, `activate`/`begin` do nothing and any visible
    /// overlay hides.
    var isEnabled = true { didSet { if !isEnabled { stop() } } }

    private var panel: NSPanel?
    private var view: WordOverlayView?
    private var timer: Timer?
    /// Whether the overlay window is currently on screen for a speech job.
    private var active = false

    private var anchor: Date?
    private var words: [WordTiming] = []
    /// Grace period after the last word before its word is cleared, so a
    /// trailing word doesn't blink out the instant its `end` passes.
    private let tailSeconds = 0.3
    private var shownIndex: Int?

    /// Put the overlay on screen (crosshair only, no word yet). Call when a
    /// speech job starts synthesizing. Idempotent; leaves it up across the job.
    func activate() {
        guard isEnabled, !active else { return }
        show()
        active = true
    }

    /// Start the word clock for one sentence. The window is already visible from
    /// `activate`; this anchors at the first audible sample and installs the
    /// sentence's timings as they arrive.
    func begin(anchor: Date, timings: @escaping @Sendable () async -> [WordTiming]) {
        guard isEnabled else { return }
        activate()   // belt-and-suspenders: ensure visible even without a prior activate
        self.anchor = anchor
        self.words = []
        self.shownIndex = nil
        view?.word = nil
        startTimer()
        Task { [weak self] in
            let resolved = await timings()
            guard let self, self.anchor == anchor else { return }   // superseded meanwhile
            self.words = resolved
            self.tick()
        }
    }

    /// Hide the overlay entirely. Call when the whole speech job has finished or
    /// been interrupted. Idempotent.
    func stop() {
        endSentence()
        active = false
        panel?.orderOut(nil)
    }

    // MARK: - Timing

    private func startTimer() {
        timer?.invalidate()
        // 60 Hz is far finer than word granularity, but keeps the flip crisp and
        // clears the word promptly at the tail. Common mode so it keeps firing
        // while a menu is tracking.
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let anchor else { return }
        let elapsed = Date().timeIntervalSince(anchor)

        // Hold the latest word whose start has passed (so it stays lit through
        // the pause after punctuation) until the next word begins.
        var index: Int?
        for (i, w) in words.enumerated() where w.start <= elapsed { index = i }

        if let last = words.last, elapsed > last.end + tailSeconds {
            endSentence()   // sentence spoken; clear the word but keep the overlay up
            return
        }
        if index != shownIndex {
            shownIndex = index
            view?.word = index.map { words[$0].word }
        }
    }

    /// One sentence finished; stop its clock and clear its word, but leave the
    /// crosshair on screen so the overlay persists through the gap before the
    /// next sentence.
    private func endSentence() {
        timer?.invalidate(); timer = nil
        anchor = nil
        words = []
        shownIndex = nil
        view?.word = nil
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
        panel.contentView = view
        self.panel = panel
        self.view = view
        return panel
    }

    /// Cover the current main screen. The view paints only the crosshair, the
    /// word band and the word; the rest stays transparent and click-through.
    /// Re-run on every `activate` so it follows the active screen.
    private func layout(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        panel.setFrame(screen.frame, display: true)
        view?.frame = panel.contentView?.bounds ?? .zero
        view?.needsDisplay = true
    }
}
