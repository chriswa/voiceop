import XCTest
@testable import VoiceOperator

/// Every gate incognito mode relies on, each asked directly at the level it
/// guards. None of these may reach the network or write a file — each test is
/// built so that a broken gate fails without doing either (no real socket, no
/// real history file, fake command runners).
final class IncognitoTests: XCTestCase {
    private var wasOn = false

    override func setUp() {
        wasOn = Incognito.isOn
        Incognito.isOn = true
    }

    override func tearDown() {
        Incognito.isOn = wasOn
    }

    private func assertBlocked(_ error: Error?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(error is Incognito.Blocked, "expected an incognito refusal, got \(String(describing: error))",
                      file: file, line: line)
    }

    // MARK: - Policy

    func testOffAllowsEverything() {
        Incognito.isOn = false
        XCTAssertTrue(Incognito.allows(.network("x")))
        XCTAssertTrue(Incognito.allows(.persist("x")))
        XCTAssertTrue(Incognito.allows(.spaceterm("x")))
        XCTAssertNoThrow(try Incognito.check(.network("x")))
    }

    func testOnBlocksNetworkDiskAndSpaceterm() {
        XCTAssertFalse(Incognito.allows(.network("x")))
        XCTAssertFalse(Incognito.allows(.persist("x")))
        XCTAssertEqual(Incognito.allows(.spaceterm("x")), !Incognito.blocksSpaceterm)
        XCTAssertThrowsError(try Incognito.check(.persist("x"))) { assertBlocked($0) }
    }

    func testTheRefusalIsWhatTheUserSees() {
        let message = TranscriberError.userMessage(for: Incognito.Blocked(activity: WisprFlowProvider.incognitoActivity))
        XCTAssertEqual(message, "incognito mode blocks Wispr Flow")
        XCTAssertEqual(message, WisprFlowProvider.incognitoMessage)
        let warning = StreamHealth.degraded(reason: message, provider: .wisprFlow).menuWarning
        XCTAssertEqual(warning?.hasPrefix("⚠︎ Dictation is off"), true)
    }

    // MARK: - Network

    func testWisprProviderRefusesEveryEntryPoint() async {
        let provider = WisprFlowProvider()
        do { _ = try await provider.openSession(target: DictationTarget(), trace: nil); XCTFail("opened") }
        catch { assertBlocked(error) }
        let clip = WAVFile(sampleRate: 16_000, samples: Data(count: 3_200)).data
        do { _ = try await provider.transcribe(wavData: clip); XCTFail("transcribed") }
        catch { assertBlocked(error) }
        do { _ = try await provider.transcribeAfterLiveFailure(wavData: clip); XCTFail("transcribed") }
        catch { assertBlocked(error) }
        let reason = await provider.prewarm()
        XCTAssertEqual(reason, WisprFlowProvider.incognitoMessage)
    }

    func testTheGRPCChannelWillNotDial() {
        XCTAssertThrowsError(try FlowChannel.shared.client()) { assertBlocked($0) }
    }

    func testClipboardSummaryNeverRunsTheDaemon() async {
        let runner = RecordingRunner()
        let summary = await ClaudeSummarizer.summarizeText("secret words", runner: runner)
        XCTAssertNil(summary)
        XCTAssertTrue(runner.commands.isEmpty, "ran \(runner.commands)")
    }

    // MARK: - Disk

    func testSpeechAudioIsNotCached() {
        XCTAssertThrowsError(try AudioCache().store(Data([1, 2, 3]), text: "secret words", voiceID: "af_heart")) {
            assertBlocked($0)
        }
    }

    func testEchoCapturesAreNotSaved() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("echo-\(UUID().uuidString)/mic.wav")
        XCTAssertThrowsError(try EchoCapture.save([1, 2, 3], to: url)) { assertBlocked($0) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testHistoryIsNotSaved() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vo-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let entry = STTHistoryEntry(id: UUID(), date: Date(), duration: 1, transcript: "secret words",
                                    error: nil, wavURL: nil, shadow: nil)
        HistoryStore(fileURL: file).save(.init(stt: [entry], commands: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        Incognito.isOn = false
        HistoryStore(fileURL: file).save(.init(stt: [entry], commands: []))
        XCTAssertEqual(HistoryStore(fileURL: file).load().stt.first?.transcript, "secret words")
    }

    /// URLSession.shared's disk cache kept TTS text, timings and audio.
    func testKokoroRequestsLeaveNoHTTPCacheOnDisk() {
        XCTAssertEqual(KokoroSynthesizer.session.configuration.urlCache?.diskCapacity ?? 0, 0)
    }

    /// The clean-up request carries the transcript; loopback, but still no disk cache.
    func testCleanupRequestsLeaveNoHTTPCacheOnDisk() {
        XCTAssertEqual(DictationCleaner.session.configuration.urlCache?.diskCapacity ?? 0, 0)
    }

    func testTheLogGetsLengthsNotWords() {
        XCTAssertEqual(Log.clip("secret words"), "[12ch]")
        Incognito.isOn = false
        XCTAssertTrue(Log.clip("secret words").contains("secret words"))
    }

    // MARK: - Spaceterm

    func testCommandsAreNotSentToSubscribers() throws {
        guard Incognito.blocksSpaceterm else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vo-incognito-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = SubscriberRegistry(file: dir.appendingPathComponent("subscribers.json"))
        try registry.register(Subscriber(name: "spaceterm", socket: "/tmp/vo-incognito-none.sock",
                                         commands: true, events: [], registered: Date()))
        let done = expectation(description: "completion")
        // Not delivered, *and* no route: the gate answered before a socket was tried.
        SubscriberSocket.voiceCommand("secret words", registry: registry) { delivered, route in
            XCTAssertFalse(delivered)
            XCTAssertNil(route)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testPhoneDictationIsRefused() async {
        guard Incognito.blocksSpaceterm else { return }
        let manager = RemoteTranscriptionManager(provider: { FakeProvider() })
        do { _ = try await manager.create(); XCTFail("created") } catch { assertBlocked(error) }
    }

    func testWakeWordClipsAreRefused() async {
        guard Incognito.blocksSpaceterm else { return }
        do { _ = try await WakeWordCheck.check(pcm: Data(count: 3_200), sampleRate: 16_000, word: "control"); XCTFail("checked") }
        catch { assertBlocked(error) }
    }

    func testSpeechForADeviceIsRefused() async {
        guard Incognito.blocksSpaceterm else { return }
        let speech = DeviceSpeech(deps: .init(synthesize: { _, _ in
            XCTFail("synthesized")
            return nil
        }, log: { _ in }))
        _ = speech.connect(client: "spaceterm", device: "phone") { _ in XCTFail("sent to the device") }
        let answer = await speech.speak(parts: [.init(text: "Hello.", voice: "af_heart")], client: "spaceterm", device: "phone")
        guard case .refused = answer else { return XCTFail("spoke: \(answer)") }
    }

    /// Turned on mid-job: the sentence made after it never leaves.
    func testSpeechForADeviceStopsAtTheSend() async {
        guard Incognito.blocksSpaceterm else { return }
        Incognito.isOn = false
        let sent = NSLock(), turnedOn = expectation(description: "made")
        nonisolated(unsafe) var sentences = 0
        let speech = DeviceSpeech(deps: .init(synthesize: { _, _ in
            Incognito.isOn = true
            turnedOn.fulfill()
            return .init(wav: WAVFile(sampleRate: 24_000, samples: Data(count: 480)), words: nil)
        }, log: { _ in }))
        _ = speech.connect(client: "spaceterm", device: "phone") { message in
            if message["type"] as? String == "sentence" { sent.withLock { sentences += 1 } }
        }
        guard case .accepted(let job) = await speech.speak(parts: [.init(text: "Hello.", voice: "af_heart")],
                                                           client: "spaceterm", device: "phone") else { return XCTFail("refused") }
        await fulfillment(of: [turnedOn], timeout: 2)
        let ended = await speech.status(id: job.id, wait: 2)
        XCTAssertEqual(ended?.state, .synthesisFailed)
        XCTAssertEqual(sent.withLock { sentences }, 0)
    }
}

private final class RecordingRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [[String]] = []
    var commands: [[String]] { lock.withLock { _commands } }

    func run(_ executable: String, _ arguments: [String], environment: [String: String],
             logTo: URL?) async throws -> CommandResult {
        lock.withLock { _commands.append([executable] + arguments) }
        return CommandResult(status: 0, output: "")
    }
}
