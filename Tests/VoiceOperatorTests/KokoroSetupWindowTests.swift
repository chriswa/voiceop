import AppKit
import XCTest
@testable import VoiceOperator

@MainActor
final class KokoroSetupWindowTests: XCTestCase {
    /// The log line changes twice a second while packages install; a long one
    /// once pushed the window wider. It must truncate instead.
    func testLongTextDoesNotWidenTheWindow() {
        let window = KokoroSetupWindow()
        window.detailProvider = { "Downloading " + String(repeating: "torch-2.14.0-cp313-none-macosx_11_0_arm64.whl ", count: 8) }
        window.show(.working(step: "installing packages (about 900 MB)", progress: 0.3, cancellable: true))
        let width = window.currentWidth
        window.show(.failed(String(repeating: "a very long failure reason ", count: 10)))
        XCTAssertEqual(window.currentWidth, width)
        window.close()
        XCTAssertNotNil(width)
        XCTAssertEqual(width ?? 0, 440, accuracy: 1)
    }
}
