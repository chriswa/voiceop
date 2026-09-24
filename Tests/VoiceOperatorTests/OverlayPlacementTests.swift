import XCTest
@testable import VoiceOperator

final class OverlayPlacementTests: XCTestCase {
    func testCycleVisitsBottomMiddleTopHiddenThenWraps() {
        var placement = OverlayPlacement.bottom
        var seen: [OverlayPlacement] = []
        for _ in 0..<5 { seen.append(placement); placement = placement.next }
        XCTAssertEqual(seen, [.bottom, .middle, .top, .hidden, .bottom])
    }
}
