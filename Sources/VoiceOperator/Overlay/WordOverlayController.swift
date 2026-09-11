import AppKit
import CoreGraphics

/// The visual reader follows source-audio position across the retained job.
/// Context stays available during the two-second completion grace, so rewind
/// restores the original sentence and word without fetching timings again.
@MainActor
final class WordOverlayController {
    var playbackRate: Float = 1 { didSet { view?.playbackRate = playbackRate } }
    var isEnabled = true {
        didSet {
            if !isEnabled { panel?.orderOut(nil) }
            else if active { show(); refresh() }
        }
    }
    private var panel: NSPanel?
    private var view: WordOverlayView?
    private var timer: Timer?
    private var active = false
    private struct WordSpan { let start: Double; let end: Double; let range: NSRange; let pivotOffset: Int }
    private struct Context { let text: String; let spans: [WordSpan] }
    private struct Sentence {
        let start: Double
        var context: Context?
    }
    private var sentences: [Sentence] = []
    private var session = UUID()
    private var position: (() -> Double)?
    private let tailSeconds = 0.3
    private static let warmLine = OverlayLine(text: "\u{00A0}", pivotUTF16Offset: 0, highlightRange: NSRange(location: 0, length: 0))

    func beginSession(position: @escaping () -> Double) {
        stop()
        self.position = position
    }

    @discardableResult
    func appendSentence(start: Double, prepared: TTSPrepared,
                        timings: @escaping @Sendable () async -> [WordTiming]) -> Task<Void, Never> {
        let token = session
        let index = sentences.count
        sentences.append(Sentence(start: start))
        return Task { [weak self] in
            let resolved = await timings()
            guard let self, self.session == token else { return }
            self.sentences[index].context = Self.buildContext(prepared: prepared, words: resolved)
            self.refresh()
        }
    }

    func activate() {
        guard !active else { return }
        active = true
        if isEnabled { show() }
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
        session = UUID() // discard late timing responses from the old session
        sentences.removeAll()
        position = nil
    }

    func refresh() {
        guard active, isEnabled, let position else { return }
        view?.line = line(at: position())
    }

    /// Pure display lookup, also used by silent tests without creating a panel.
    func line(at seconds: Double) -> OverlayLine? {
        guard let sentenceIndex = sentences.lastIndex(where: { $0.start <= seconds }),
              let context = sentences[sentenceIndex].context else { return nil }
        let elapsed = seconds - sentences[sentenceIndex].start
        let index = context.spans.lastIndex(where: { $0.start <= elapsed })
        if let last = context.spans.last, elapsed > last.end + tailSeconds {
            // Do not destroy contexts here: the next key can rewind into them.
            return nil
        }
        return index.map {
            let span = context.spans[$0]
            return OverlayLine(text: context.text, pivotUTF16Offset: span.pivotOffset, highlightRange: span.range)
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
        panel.contentView = view
        self.panel = panel
        self.view = view
        return panel
    }

    /// Cover the primary display. The view paints only the crosshair, the word
    /// band and the word; the rest stays transparent and click-through.
    /// Re-run on every `activate` so it follows a display reconnection.
    private func layout(_ panel: NSPanel) {
        guard let screen = Self.primaryScreen else { return }
        panel.setFrame(screen.frame, display: true)
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
