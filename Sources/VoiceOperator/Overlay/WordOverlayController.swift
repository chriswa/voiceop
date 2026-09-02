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

    /// One word's timing, its UTF-16 range in the rendered line, and its pivot.
    private struct WordSpan { let start: Double; let end: Double; let range: NSRange; let pivotOffset: Int }
    /// The whole sentence as one rendered line, plus each word's span within it.
    /// Built once when a sentence's timings arrive.
    private struct Context { let text: String; let spans: [WordSpan] }

    private var anchor: Date?
    private var context: Context?
    /// Grace period after the last word before the line is cleared, so a
    /// trailing word doesn't blink out the instant its `end` passes.
    private let tailSeconds = 0.3
    private var shownIndex: Int?
    /// A zero-width character rendered while the overlay is up but no word is
    /// current yet, so Core Text's font/glyph machinery is warm before the first
    /// real word — otherwise the opening word of a fresh job can render a beat late.
    private static let warmLine = OverlayLine(text: "\u{00A0}", pivotUTF16Offset: 0, highlightRange: NSRange(location: 0, length: 0))

    /// Put the overlay on screen (crosshair only, no word yet). Call when a
    /// speech job starts synthesizing. Idempotent; leaves it up across the job.
    func activate() {
        guard isEnabled, !active else { return }
        show()
        view?.line = Self.warmLine   // prime Core Text before the first word
        active = true
    }

    /// Start the word clock for one sentence. The window is already visible from
    /// `activate`; this anchors at the first audible sample and installs the
    /// sentence's timings as they arrive.
    func begin(anchor: Date, prepared: TTSPrepared, timings: @escaping @Sendable () async -> [WordTiming]) {
        guard isEnabled else { return }
        activate()   // belt-and-suspenders: ensure visible even without a prior activate
        self.anchor = anchor
        self.context = nil
        self.shownIndex = nil
        startTimer()
        Task { [weak self] in
            let resolved = await timings()
            guard let self, self.anchor == anchor else { return }   // superseded meanwhile
            self.context = Self.buildContext(prepared: prepared, words: resolved)
            self.tick()
        }
    }

    /// Build the render line for a sentence. Preferred path: align the timing
    /// tokens against the text that was actually synthesized (`prepared.ttsText`)
    /// and map each match back onto the ORIGINAL through `origPositions`, so the
    /// line shows the text as written and a `/` or `.` spoken as a word still
    /// highlights the literal character. If a token can't be located (Kokoro
    /// normalised it), fall back to joining the tokens with spaces, and log it so
    /// the real-world fallback rate is observable.
    private static func buildContext(prepared: TTSPrepared, words: [WordTiming]) -> Context {
        if let aligned = alignedContext(prepared: prepared, words: words) { return aligned }
        if !words.isEmpty {
            Log.log("overlay: token alignment failed, using space-join for \(Log.clip(prepared.original))")
        }
        return joinedContext(words)
    }

    /// Greedy forward substring scan of the timing tokens through `ttsText`, each
    /// match mapped back to an original range via `origPositions`. Returns nil if
    /// any token isn't a substring at/after the cursor, signalling the fallback.
    private static func alignedContext(prepared: TTSPrepared, words: [WordTiming]) -> Context? {
        guard !words.isEmpty else { return nil }
        let display = prepared.original as NSString
        let tts = prepared.ttsText as NSString
        let pos = prepared.origPositions
        guard pos.count == tts.length else { return nil }
        var cursor = 0
        var spans: [WordSpan] = []
        for w in words {
            let searchRange = NSRange(location: cursor, length: tts.length - cursor)
            var found = tts.range(of: w.word, options: [], range: searchRange)
            if found.location == NSNotFound {
                found = tts.range(of: w.word, options: [.caseInsensitive], range: searchRange)
            }
            guard found.location != NSNotFound, found.length > 0 else { return nil }
            let start = pos[found.location]
            let end = pos[found.location + found.length - 1] + 1
            guard start >= 0, end > start, end <= display.length else { return nil }
            let range = NSRange(location: start, length: end - start)
            spans.append(WordSpan(start: w.start, end: w.end, range: range,
                                  pivotOffset: pivotOffset(in: display, range: range)))
            cursor = found.location + found.length
        }
        return Context(text: prepared.original, spans: spans)
    }

    /// The pivot to pin on the focal point for a highlighted range: the single
    /// character for a separator (`/`, `.`), else the word's ORP pivot.
    private static func pivotOffset(in display: NSString, range: NSRange) -> Int {
        if range.length <= 1 { return range.location }
        return range.location + pivotUTF16Offset(in: display.substring(with: range))
    }

    /// Fallback: join the tokens with single spaces (no original punctuation).
    private static func joinedContext(_ words: [WordTiming]) -> Context {
        var text = ""
        var spans: [WordSpan] = []
        for (i, w) in words.enumerated() {
            if i > 0 { text += " " }
            let wordStart = text.utf16.count
            spans.append(WordSpan(start: w.start, end: w.end,
                                  range: NSRange(location: wordStart, length: w.word.utf16.count),
                                  pivotOffset: wordStart + pivotUTF16Offset(in: w.word)))
            text += w.word
        }
        return Context(text: text, spans: spans)
    }

    /// UTF-16 offset, within `word`, of its ORP pivot letter.
    private static func pivotUTF16Offset(in word: String) -> Int {
        let pivot = ORP.pivotIndex(forLength: word.count)
        let charIndex = word.index(word.startIndex, offsetBy: pivot)
        return word.utf16.distance(from: word.utf16.startIndex,
                                   to: charIndex.samePosition(in: word.utf16) ?? word.utf16.startIndex)
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
        guard let anchor, let context else { return }
        let elapsed = Date().timeIntervalSince(anchor)

        // Hold the latest word whose start has passed (so it stays lit through
        // the pause after punctuation) until the next word begins.
        var index: Int?
        for (i, s) in context.spans.enumerated() where s.start <= elapsed { index = i }

        if let last = context.spans.last, elapsed > last.end + tailSeconds {
            endSentence()   // sentence spoken; clear the line but keep the overlay up
            return
        }
        if index != shownIndex {
            shownIndex = index
            // Render the whole sentence, highlighting the current word bright and
            // pinning its pivot to the focal point; nil before the first word.
            view?.line = index.map { i in
                let s = context.spans[i]
                return OverlayLine(text: context.text, pivotUTF16Offset: s.pivotOffset, highlightRange: s.range)
            }
        }
    }

    /// One sentence finished; stop its clock and clear its line, but leave the
    /// crosshair on screen so the overlay persists through the gap before the
    /// next sentence.
    private func endSentence() {
        timer?.invalidate(); timer = nil
        anchor = nil
        context = nil
        shownIndex = nil
        view?.line = nil
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
