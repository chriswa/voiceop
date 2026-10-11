import XCTest
@testable import VoiceOperator

final class TranscriptionPreferencesTests: XCTestCase {
    private var saved: (TranscriptionProviderID, TranscriptionProviderID?)!

    override func setUp() { saved = (TranscriptionPreferences.primary, TranscriptionPreferences.shadow) }
    override func tearDown() {
        TranscriptionPreferences.primary = saved.0
        TranscriptionPreferences.shadow = saved.1
    }

    func testAShadowThatBecomesThePrimaryIsNoLongerAShadow() {
        let other = TranscriptionProviderID.allCases.first { $0 != .wisprFlow } ?? .wisprFlow
        TranscriptionPreferences.primary = .wisprFlow
        TranscriptionPreferences.shadow = other
        XCTAssertEqual(TranscriptionPreferences.shadow, other == .wisprFlow ? nil : other)
        TranscriptionPreferences.primary = other
        XCTAssertNil(TranscriptionPreferences.shadow)
    }

    func testTheRegistryFollowsThePreference() {
        for id in TranscriptionProviderID.allCases {
            TranscriptionPreferences.primary = id
            XCTAssertEqual(TranscriptionProviders.primary.id, id)
        }
    }
}
