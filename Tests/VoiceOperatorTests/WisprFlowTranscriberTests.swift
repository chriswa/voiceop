import XCTest
import FlowAPI
@testable import VoiceOperator

final class WisprFlowTranscriberTests: XCTestCase {
    func testInitCarriesDictionaryAndOpusEncoding() {
        let initMessage = FlowSession.makeInit(words: ["Claude", "kubectl"])
        XCTAssertEqual(initMessage.preferences.vocabulary.dictionaryPersonal, ["Claude", "kubectl"])
        XCTAssertEqual(initMessage.metadata.audioEncoding, .opus)
        XCTAssertEqual(initMessage.metadata.environment, .production)
        XCTAssertEqual(initMessage.metadata.client.platform, .macos)
        XCTAssertFalse(initMessage.metadata.sessionID.isEmpty)
        XCTAssertFalse(initMessage.metadata.requestID.isEmpty)
    }

    func testContextCarriesTheTargetApp() {
        let context = FlowSession.makeContext(
            app: FlowSession.app(bundleIdentifier: "com.apple.Safari", name: "Safari"))
        XCTAssertEqual(context.app.bundleID, "com.apple.Safari")
        XCTAssertEqual(context.app.name, "Safari")
    }

    // Commit is an explicit tri-state on the wire: intermediate audio must carry
    // COMMIT_FALSE (2), not the zero-valued COMMIT_UNSPECIFIED, and only the final
    // message may carry COMMIT_TRUE (1).
    func testCommitEnumRawValuesMatchTheProto() {
        XCTAssertEqual(FlowApi_V1_Commit.true.rawValue, 1)
        XCTAssertEqual(FlowApi_V1_Commit.false.rawValue, 2)
        XCTAssertEqual(FlowApi_V1_Commit.unspecified.rawValue, 0)
    }

    // A silent lead-in is exactly what "I lost my first words" looks like in the
    // captured audio, so the probe has to show it as leading zeros.
    func testLeadingLevelProfileExposesADeafLeadIn() {
        let samplesPerBin = AudioRecorder.asrSampleRate * 50 / 1000
        var pcm = Data(count: samplesPerBin * 2 * 2)   // two silent 50 ms bins
        for i in 0 ..< samplesPerBin * 3 {            // then three loud ones
            let value = Int16(truncatingIfNeeded: i % 2 == 0 ? 12_000 : -12_000)
            withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
        }
        let profile = AudioRecorder.leadingLevelProfile(pcm16: pcm)
        XCTAssertEqual(profile.count, 5)
        XCTAssertEqual(profile[0], 0, accuracy: 1e-6)
        XCTAssertEqual(profile[1], 0, accuracy: 1e-6)
        XCTAssertGreaterThan(profile[2], 0.3)
        XCTAssertGreaterThan(profile[4], 0.3)
    }

    // Partial trailing bins are dropped rather than reported at a misleading level.
    func testLeadingLevelProfileIgnoresAPartialTrailingBin() {
        let samplesPerBin = AudioRecorder.asrSampleRate * 50 / 1000
        let pcm = Data(count: (samplesPerBin + samplesPerBin / 2) * 2)
        XCTAssertEqual(AudioRecorder.leadingLevelProfile(pcm16: pcm).count, 1)
    }
}
