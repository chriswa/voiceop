import XCTest
@testable import VoiceOperator

final class OverlayPlacementTests: XCTestCase {
    func testCycleClimbsFromBottomToTopThenHidesThenWraps() {
        var placement = OverlayPlacement.bottom
        var seen: [OverlayPlacement] = []
        for _ in 0..<7 { seen.append(placement); placement = placement.next }
        XCTAssertEqual(seen, [.bottom, .lowerMiddle, .middle, .upperMiddle, .top, .hidden, .bottom])
    }
}
