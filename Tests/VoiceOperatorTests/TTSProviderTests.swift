import XCTest
@testable import VoiceOperator

final class TTSProviderTests: XCTestCase {
    private var tempFile: URL?

    override func tearDown() {
        Config.override = nil
        Config.fileURLOverride = nil
        Config.resetCache()
        if let tempFile { try? FileManager.default.removeItem(at: tempFile.deletingLastPathComponent()) }
        super.tearDown()
    }

    func testResolveDefaultsToLocalKokoro() {
        XCTAssertEqual(TTSProvider.resolve(nil), .kokoroLocal)
        XCTAssertEqual(TTSProvider.resolve(.init()), .kokoroLocal)
    }

    /// Files from before the menu: a `url` alone still means "use this server".
    func testLegacyURLWithoutProviderIsACustomServer() {
        XCTAssertEqual(TTSProvider.resolve(.init(url: "https://tts.example.com")),
                       .custom(url: "https://tts.example.com"))
    }

    func testExplicitKokoroIgnoresAStoredURL() {
        XCTAssertEqual(TTSProvider.resolve(.init(url: "https://tts.example.com", provider: "kokoro")), .kokoroLocal)
    }

    func testCustomWithoutURLFallsBackToLocal() {
        XCTAssertEqual(TTSProvider.resolve(.init(provider: "custom")), .kokoroLocal)
    }

    func testCacheNamespaceKeepsExistingLocalEntriesAndSeparatesServers() {
        XCTAssertEqual(TTSProvider.kokoroLocal.cacheNamespace, "kokoro-82m")
        XCTAssertNotEqual(TTSProvider.custom(url: "https://a.example").cacheNamespace,
                          TTSProvider.custom(url: "https://b.example").cacheNamespace)
    }

    func testAudioCacheKeyFollowsTheProvider() {
        let local = AudioCache(namespace: { TTSProvider.kokoroLocal.cacheNamespace })
        let custom = AudioCache(namespace: { TTSProvider.custom(url: "https://tts.example.com").cacheNamespace })
        XCTAssertNotEqual(local.key(text: "Hello.", voiceID: "af_heart"),
                          custom.key(text: "Hello.", voiceID: "af_heart"))
    }

    func testNormalizedCustomURL() {
        XCTAssertEqual(TTSProvider.normalizedCustomURL("  https://tts.example.com/ "), "https://tts.example.com")
        XCTAssertEqual(TTSProvider.normalizedCustomURL("http://192.168.1.5:56841"), "http://192.168.1.5:56841")
        XCTAssertNil(TTSProvider.normalizedCustomURL("tts.example.com"))
        XCTAssertNil(TTSProvider.normalizedCustomURL("ftp://tts.example.com"))
        XCTAssertNil(TTSProvider.normalizedCustomURL(""))
    }

    func testBaseURLComesFromTheProvider() {
        guard ProcessInfo.processInfo.environment["VOICEOP_KOKORO_URL"] == nil else { return }
        Config.override = .init(tts: .init(url: "https://tts.example.com", provider: "kokoro"))
        XCTAssertEqual(Config.ttsBaseURL, Config.defaultTTSBaseURL)
        Config.override = .init(tts: .init(url: "https://tts.example.com", provider: "custom"))
        XCTAssertEqual(Config.ttsBaseURL, "https://tts.example.com")
    }

    /// Saving the menu's choice must keep every other key — including secrets
    /// this build doesn't model — and keep the file owner-only.
    func testSetProviderPreservesOtherKeys() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("config.json")
        tempFile = file
        Config.fileURLOverride = file
        try Data("""
            {"tts": {"url": "https://old.example", "headers": {"CF-Access-Client-Secret": "s"}},
             "future_setting": {"keep": true}}
            """.utf8).write(to: file)

        try Config.setTTSProvider(.kokoroLocal)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var tts = try XCTUnwrap(object["tts"] as? [String: Any])
        XCTAssertEqual(tts["provider"] as? String, "kokoro")
        XCTAssertEqual(tts["url"] as? String, "https://old.example", "kept for switching back")
        XCTAssertEqual((tts["headers"] as? [String: String])?["CF-Access-Client-Secret"], "s")
        XCTAssertEqual((object["future_setting"] as? [String: Bool])?["keep"], true)

        try Config.setTTSProvider(.custom(url: "https://new.example"))
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        tts = try XCTUnwrap(object["tts"] as? [String: Any])
        XCTAssertEqual(tts["provider"] as? String, "custom")
        XCTAssertEqual(tts["url"] as? String, "https://new.example")

        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testSetProviderCreatesAMissingFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-tests-\(UUID().uuidString)", isDirectory: true)
        let file = dir.appendingPathComponent("config.json")
        tempFile = file
        Config.fileURLOverride = file
        try Config.setTTSProvider(.custom(url: "https://tts.example.com"))
        Config.resetCache()
        XCTAssertEqual(Config.load().tts?.provider, "custom")
    }
}

final class TTSMenuStateTests: XCTestCase {
    private func make(provider: TTSProvider = .kokoroLocal, phase: KokoroService.Phase = .idle,
                      installed: Bool = true, legacy: Bool = false, update: Bool = false,
                      canCancel: Bool = false, health: KokoroService.Health? = .init(memoryMB: 1843, pid: 1)) -> TTSMenuState {
        TTSMenuState.make(provider: provider, phase: phase, installed: installed, legacyInstalled: legacy,
                          updateAvailable: update, canCancel: canCancel, health: health)
    }

    func testRunningShowsStatusAndMemory() {
        let state = make()
        XCTAssertEqual(state.status, "Kokoro: running")
        XCTAssertEqual(state.memory, "Memory: 1.8 GB")
        XCTAssertFalse(state.isWarning)
        XCTAssertEqual(state.install, .hidden)
        XCTAssertTrue(state.showRestart)
        XCTAssertTrue(state.showUninstall)
        XCTAssertFalse(state.showUpdate)
    }

    func testNotInstalledAndSilentIsAWarning() {
        let state = make(installed: false, health: nil)
        XCTAssertTrue(state.isWarning)
        XCTAssertEqual(state.install, .install)
        XCTAssertFalse(state.showRestart)
        XCTAssertNil(state.memory)
    }

    func testLegacyServerIsRunningButOffersInstall() {
        let state = make(installed: false, legacy: true, health: .init(memoryMB: nil, pid: nil))
        XCTAssertFalse(state.isWarning)
        XCTAssertTrue(state.status.contains("~/tts"))
        XCTAssertEqual(state.install, .install)
        XCTAssertNil(state.memory, "the old server doesn't report memory")
    }

    func testInstalledButNotAnsweringIsAWarning() {
        XCTAssertEqual(make(health: nil).status, "⚠︎ Kokoro: not responding")
    }

    func testWorkingDisablesActionsAndOffersCancel() {
        let state = make(phase: .working("installing packages"), installed: false, canCancel: true, health: nil)
        XCTAssertEqual(state.status, "Kokoro: installing packages…")
        XCTAssertFalse(state.actionsEnabled)
        XCTAssertEqual(state.install, .cancel)
    }

    func testCustomServerHidesMemoryAndNamesHost() {
        let state = make(provider: .custom(url: "https://tts.example.com"))
        XCTAssertFalse(state.localSelected)
        XCTAssertNil(state.memory)
        XCTAssertEqual(state.customTitle, "Custom Server (tts.example.com)…")
        XCTAssertTrue(state.status.contains("tts.example.com"))
    }

    func testUpdateShownOnlyWhenInstalled() {
        XCTAssertTrue(make(update: true).showUpdate)
        XCTAssertFalse(make(installed: false, update: true).showUpdate)
    }

    func testMemoryFormatting() {
        XCTAssertEqual(TTSMenuState.formatMemory(512), "512 MB")
        XCTAssertEqual(TTSMenuState.formatMemory(19_456), "19.0 GB")
    }
}
