import AppKit
import XCTest
@testable import VoiceOperator

@MainActor
final class MenuBarIconTests: XCTestCase {
    func testIdleIsTheMonochromeTemplate() {
        XCTAssertTrue(MenuBarController.icon(status: .idle, muted: false).isTemplate)
    }

    func testHandsFreeColoursTheIdleIcon() {
        for look in [HandsFreeLook.waiting, .conversation, .hearing, .sending] {
            XCTAssertFalse(MenuBarController.icon(status: .idle, muted: false, handsFree: look).isTemplate, "\(look)")
        }
        XCTAssertEqual(HandsFreeLook.hearing.tint, OperatorStatus.listening.tint)
        XCTAssertEqual(HandsFreeLook.sending.tint, OperatorStatus.transcribing.tint)
        XCTAssertNil(HandsFreeLook.waiting.tint, "a rainbow")
    }

    /// Speech and a Fn dictation keep their own colours over hands-free: drawn
    /// the same with it as without.
    func testTheStatusWinsOverHandsFree() throws {
        for status in [OperatorStatus.speaking, .listening, .requestingTTS] {
            let plain = try pixels(MenuBarController.icon(status: status, muted: false))
            let over = try pixels(MenuBarController.icon(status: status, muted: false, handsFree: .conversation))
            XCTAssertEqual(plain, over, "\(status)")
        }
    }

    private func pixels(_ image: NSImage) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.cgContext.clear(CGRect(x: 0, y: 0, width: 36, height: 36))
        image.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36))
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.tiffRepresentation)
    }
}
