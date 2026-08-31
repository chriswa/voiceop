import AppKit
import CoreText

/// Draws the reading overlay: a full-width black band across screen centre with
/// a dim crosshair inside it, and the current word centred on the focal point
/// ORP-style — the pivot letter (see `ORP`) pinned to the vertical guide, so the
/// reader's eye stays parked on one spot as words flip past. A word wider than
/// the screen simply runs off both edges (no wrapping, clipped by the window).
///
/// The view is full-screen and mostly transparent; only the word band, the
/// crosshair (both guides confined to the band), and the word are painted.
final class WordOverlayView: NSView {
    /// The word currently shown. `nil` (or empty) paints the guide with no word.
    var word: String? { didSet { if word != oldValue { needsDisplay = true } } }

    /// The word's font. Large by design — this is a glanceable overlay.
    private let font = NSFont.systemFont(ofSize: 64, weight: .semibold)
    /// Black space above the tallest ascender / below the lowest descender of
    /// the word band. (Was ~37pt; halved.)
    private let verticalMargin: CGFloat = 19
    /// Height of the horizontal word band: the glyphs' full height plus the
    /// margin on each side.
    private var bandHeight: CGFloat { (font.ascender - font.descender) + 2 * verticalMargin }
    /// Width of the white vertical guide line.
    private let lineWidth: CGFloat = 2
    /// Height of the white border strips hugging the band's top and bottom edges.
    private let borderHeight: CGFloat = 10

    private let black = NSColor.black
    private let wordColor = NSColor.white
    /// Dim guide: 30% white over black reads as a muted grey, not a bright bar.
    private let guideColor = NSColor.white.withAlphaComponent(0.3)

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let focalX = bounds.midX

        // The word band: a full-width black rectangle centred vertically.
        let band = NSRect(x: bounds.minX, y: bounds.midY - bandHeight / 2, width: bounds.width, height: bandHeight)
        ctx.setFillColor(black.cgColor)
        ctx.fill(band)

        // White border strips hugging the band's top and bottom edges, to
        // delineate the black rectangle against the desktop behind it.
        ctx.setFillColor(wordColor.cgColor)
        ctx.fill(NSRect(x: bounds.minX, y: band.maxY, width: bounds.width, height: borderHeight))
        ctx.fill(NSRect(x: bounds.minX, y: band.minY - borderHeight, width: bounds.width, height: borderHeight))

        // Dim crosshair, confined to the band: a full-width horizontal guide and
        // a vertical guide spanning only the band's height (not the whole
        // screen), crossing at the point the eye should fixate — the pivot
        // letter's x-height centre, which the word is positioned to land on the
        // screen's vertical centre (see `drawWord`).
        ctx.setFillColor(guideColor.cgColor)
        ctx.fill(NSRect(x: focalX - lineWidth / 2, y: band.minY, width: lineWidth, height: band.height))
        ctx.fill(NSRect(x: bounds.minX, y: bounds.midY - lineWidth / 2, width: bounds.width, height: lineWidth))

        guard let word, !word.isEmpty else { return }
        drawWord(word, focalX: focalX, in: ctx)
    }

    /// Draw `word` in white, centred so its ORP pivot glyph sits on `focalX`
    /// (the crosshair marks the pivot; the glyph itself isn't tinted). No glyph
    /// stroke — the solid black band already gives full contrast, and a stroke
    /// leaves join artifacts in the letters' bowls.
    private func drawWord(_ word: String, focalX: CGFloat, in ctx: CGContext) {
        let attributed = NSMutableAttributedString(string: word, attributes: [
            .font: font,
            .foregroundColor: wordColor,
        ])

        // Pin the pivot glyph to the focal point. `pivot` indexes composed
        // characters; map it to a UTF-16 offset for Core Text's layout.
        let pivot = ORP.pivotIndex(forLength: word.count)
        let charIndex = word.index(word.startIndex, offsetBy: pivot)
        let utf16Start = word.utf16.distance(from: word.utf16.startIndex,
                                             to: charIndex.samePosition(in: word.utf16) ?? word.utf16.startIndex)

        let line = CTLineCreateWithAttributedString(attributed)

        // Horizontal: pin the pivot glyph's centre to the focal point.
        let pivotLeft = CTLineGetOffsetForStringIndex(line, utf16Start, nil)
        let pivotRight = CTLineGetOffsetForStringIndex(line, utf16Start + 1, nil)
        let originX = focalX - (pivotLeft + pivotRight) / 2

        // Vertical: land the x-height midline on the screen centre, so the
        // horizontal guide crosses through the vertical centre of the lowercase
        // letter body — where the eye fixates in reading — rather than the
        // em-box centre (which sits high, skewed by ascender space). The pivot
        // is almost always a lowercase interior letter, so its centre is here.
        let baselineY = bounds.midY - font.xHeight / 2

        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: originX, y: baselineY)
        CTLineDraw(line, ctx)
    }
}
