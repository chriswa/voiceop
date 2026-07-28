import XCTest
@testable import VoiceOperator

final class SpeechJobManagerTests: XCTestCase {
    func testQueueRejectsMutedRequests() async {
        let manager = SpeechJobManager()
        await manager.setMuted(true)
        let result = await manager.enqueue(text: "Hello.", voice: "af_heart")
        XCTAssertEqual(result?.error, "speech_muted")
    }
}
