import AppKit
import CoreText

/// What the overlay renders: a line of text with one character pinned to the
/// focal point. The pinned character is the ORP pivot of the word currently
/// being spoken; the surrounding words of the sentence render as context and
/// overflow off the screen edges (no wrapping).
struct OverlayLine: Equatable {
    let text: String
    /// UTF-16 offset, within `text`, of the character to pin on the focal point.
    let pivotUTF16Offset: Int
    /// UTF-16 range of the word currently being spoken. It renders bright; the
    /// surrounding context words render dim.
    let highlightRange: NSRange
}

/// Draws the reading overlay: a full-width black band along the screen bottom with
/// a dim vertical guide inside it, and a line of the sentence's text with the
/// current word's ORP pivot letter (see `ORP`) pinned to that guide, so the
/// reader's eye stays parked on one spot as words flip past. The line runs off
/// both screen edges (no wrapping, clipped by the window).
///
/// The view is full-screen and mostly transparent; only the word band, the
/// vertical guide, and the text are painted.
final class WordOverlayView: NSView {
    /// The line currently shown. `nil` paints the band and crosshair with no text.
    var line: OverlayLine? { didSet { if line != oldValue { needsDisplay = true } } }

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
    /// The word currently being spoken: bright white.
    private let wordColor = NSColor.white
    /// The surrounding context words: dimmer, so the current word stands out.
    private let contextColor = NSColor.white.withAlphaComponent(0.45)
    /// Dim guide: 30% white over black reads as a muted grey, not a bright bar.
    private let guideColor = NSColor.white.withAlphaComponent(0.3)

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let focalX = bounds.midX

        // The word band: a full-width black rectangle flush with the bottom of
        // the screen. Leave room for the lower border strip so the complete
        // black-and-white band, rather than just its black interior, is aligned
        // to the screen edge.
        let band = NSRect(x: bounds.minX, y: bounds.minY + borderHeight, width: bounds.width, height: bandHeight)
        ctx.setFillColor(black.cgColor)
        ctx.fill(band)

        // White border strips hugging the band's top and bottom edges, to
        // delineate the black rectangle against the desktop behind it.
        ctx.setFillColor(wordColor.cgColor)
        ctx.fill(NSRect(x: bounds.minX, y: band.maxY, width: bounds.width, height: borderHeight))
        ctx.fill(NSRect(x: bounds.minX, y: band.minY - borderHeight, width: bounds.width, height: borderHeight))

        // Dim vertical guide, spanning only the band's height, marking the focal
        // point the eye should fixate on — the current word's ORP pivot, pinned
        // here (see `drawLine`).
        ctx.setFillColor(guideColor.cgColor)
        ctx.fill(NSRect(x: focalX - lineWidth / 2, y: band.minY, width: lineWidth, height: band.height))

        guard let line, !line.text.isEmpty else { return }
        drawLine(line, focalX: focalX, in: ctx)
    }

    /// Draw the line in white, positioned so the pinned character sits on
    /// `focalX` (the crosshair marks it; nothing is tinted). No glyph stroke —
    /// the solid black band already gives full contrast, and a stroke leaves join
    /// artifacts in the letters' bowls.
    private func drawLine(_ overlayLine: OverlayLine, focalX: CGFloat, in ctx: CGContext) {
        // Whole line dim (context), the current word bright.
        let attributed = NSMutableAttributedString(string: overlayLine.text, attributes: [
            .font: font,
            .foregroundColor: contextColor,
        ])
        attributed.addAttribute(.foregroundColor, value: wordColor, range: overlayLine.highlightRange)
        let ctLine = CTLineCreateWithAttributedString(attributed)

        // Horizontal: pin the pinned character's centre to the focal point.
        let pivot = overlayLine.pivotUTF16Offset
        let pivotLeft = CTLineGetOffsetForStringIndex(ctLine, pivot, nil)
        let pivotRight = CTLineGetOffsetForStringIndex(ctLine, pivot + 1, nil)
        let originX = focalX - (pivotLeft + pivotRight) / 2

        // Vertical: land the x-height midline at the band centre, so the
        // horizontal guide crosses through the vertical centre of the lowercase
        // letter body — where the eye fixates in reading — rather than the
        // em-box centre (which sits high, skewed by ascender space). The pivot
        // is almost always a lowercase interior letter, so its centre is here.
        let baselineY = bandCenterY - font.xHeight / 2

        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: originX, y: baselineY)
        CTLineDraw(ctLine, ctx)
    }

    /// The focal line is vertically centred within the bottom-aligned word band.
    private var bandCenterY: CGFloat { bounds.minY + borderHeight + bandHeight / 2 }
}
