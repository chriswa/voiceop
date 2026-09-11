import XCTest
@testable import VoiceOperator

final class PlaybackPreferencesTests: XCTestCase {
    func testSavedRateSurvivesNewPreferencesAndPlaybackSessions() {
        let suite = "VoiceOperatorTests.PlaybackRate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlaybackPreferences(defaults: defaults)
        XCTAssertEqual(preferences.rate, 1)
        preferences.rate = 2.4
        let reopened = PlaybackPreferences(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(reopened.rate, 2.4)
        XCTAssertEqual(PlaybackControls(rate: reopened.rate).rate, 2.4)
        preferences.rate = .nan
        XCTAssertEqual(preferences.rate, 1)
        preferences.rate = 100
        XCTAssertEqual(preferences.rate, 5)
        preferences.rate = 0
        XCTAssertEqual(preferences.rate, 0.5)
    }

    func testIndicatorCountsAndDirections() {
        XCTAssertEqual(PlaybackPreferences.indicatorSteps(for: 1), 0)
        XCTAssertEqual(PlaybackPreferences.indicatorSteps(for: 0.8), -1)
        XCTAssertEqual(PlaybackPreferences.indicatorSteps(for: 0.6), -2)
        XCTAssertEqual(PlaybackPreferences.indicatorSteps(for: 0.5), -3)
        XCTAssertEqual(PlaybackPreferences.indicatorSteps(for: 1.2), 1)
        XCTAssertEqual(PlaybackPreferences.indicatorSteps(for: 2.4), 7)
        XCTAssertEqual(PlaybackPreferences.indicatorSteps(for: 5), 20)
    }
}
