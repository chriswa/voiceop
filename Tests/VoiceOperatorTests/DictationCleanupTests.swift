import XCTest
@testable import VoiceOperator

final class DictationCleanerTests: XCTestCase {
    func testPromptIsChatMLWithTheThinkBlockAlreadyClosed() {
        let prompt = DictationCleaner.prompt(system: "  Clean it.\n", transcript: "um hello there")
        XCTAssertEqual(prompt, """
            <|im_start|>system
            Clean it.<|im_end|>
            <|im_start|>user
            um hello there<|im_end|>
            <|im_start|>assistant
            <think>

            </think>


            """)
    }

    func testShortTranscriptsGetTheMinimumBudget() throws {
        XCTAssertEqual(try DictationCleaner.outputBudget(for: "send it Wednesday"), 256)
    }

    func testLongTranscriptsGetMoreThanTheirOwnLength() throws {
        let words = Array(repeating: "word", count: 600).joined(separator: " ")
        // 600 words → about 800 tokens; the budget leaves room to say it all again.
        XCTAssertEqual(try DictationCleaner.outputBudget(for: words), 984)
    }

    func testTranscriptsThatCannotFitAreRefused() {
        let words = Array(repeating: "word", count: 1_500).joined(separator: " ")
        XCTAssertThrowsError(try DictationCleaner.outputBudget(for: words)) {
            XCTAssertEqual($0 as? DictationCleaner.Failure, .tooLong)
        }
    }

    func testThinkBlocksAreStripped() {
        XCTAssertEqual(DictationCleaner.strippingThinking("<think>\n\n</think>\n\nSend it."), "Send it.")
        XCTAssertEqual(DictationCleaner.strippingThinking("<think>\nSend it."), "Send it.")
        XCTAssertEqual(DictationCleaner.strippingThinking("  Send it.\n"), "Send it.")
    }

    func testAnAnsweredQuestionIsPutBackAsTheQuestion() {
        XCTAssertEqual(DictationCleaner.finish(output: "It's 3 PM in Tokyo.", transcript: "what time is it in Tokyo"),
                       "What time is it in Tokyo?")
        XCTAssertEqual(DictationCleaner.finish(output: "I am a dictation cleaner.", transcript: "who are you."),
                       "Who are you?")
    }

    func testACleanedQuestionIsLeftAlone() {
        XCTAssertEqual(DictationCleaner.finish(output: "What time is it in Tokyo?", transcript: "what time is it in Tokyo"),
                       "What time is it in Tokyo?")
    }

    func testAStatementStartingWithNoIsNotMistakenForAnAnswer() {
        XCTAssertEqual(DictationCleaner.finish(output: "No, the second one is fine.", transcript: "no the second one is fine"),
                       "No, the second one is fine.")
    }

    /// The shipped prompt is the one `make-app.sh` copies into the bundle.
    func testTheShippedPromptExists() throws {
        let prompt = try String(contentsOf: Self.repoRoot.appendingPathComponent("Resources/dictation-cleanup.md"),
                                encoding: .utf8)
        XCTAssertTrue(prompt.hasPrefix("You are"))
        XCTAssertTrue(prompt.contains("RULES:"))
    }

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}

final class CleanedUpProviderTests: XCTestCase {
    private struct Fixed: TranscriptionProvider {
        let text: String
        var id: TranscriptionProviderID { .parakeet }
        var fallbackLabel: String { "fixed" }
        func openSession(target: DictationTarget, trace: DictationTrace?) async throws -> any TranscriptionSession {
            Session(text: text)
        }
        func transcribe(wavData: Data) async throws -> Transcript { Transcript(text: text) }
        func transcribeAfterLiveFailure(wavData: Data) async throws -> Transcript { Transcript(text: text) }
        func prewarm() async -> String? { nil }

        struct Session: TranscriptionSession {
            let text: String
            func send(pcm: Data) async {}
            func commit(pcm: Data) async throws -> Transcript { Transcript(text: text) }
            func cancel() async {}
        }
    }

    /// Nothing listens on port 9 of loopback.
    private func unreachable(_ text: String) -> CleanedUpProvider {
        CleanedUpProvider(base: Fixed(text: text)) {
            var cleaner = DictationCleaner(systemPrompt: "Clean it.")
            cleaner.endpoint = URL(string: "http://127.0.0.1:9/completion")!
            return try await cleaner.clean($0)
        }
    }

    func testACleanedTranscriptKeepsTheRawTextBesideIt() async throws {
        let provider = CleanedUpProvider(base: Fixed(text: "um send it Wednesday")) { _ in "Send it Wednesday." }
        let expected = Transcript(text: "Send it Wednesday.", raw: "um send it Wednesday")
        let viaClip = try await provider.transcribe(wavData: Data())
        XCTAssertEqual(viaClip, expected)
        let session = try await provider.openSession(target: DictationTarget(), trace: nil)
        let viaSession = try await session.commit(pcm: Data())
        XCTAssertEqual(viaSession, expected)
    }

    func testAFailedCleanUpPastesTheRawTranscript() async throws {
        let provider = unreachable("um send it Wednesday")
        let viaClip = try await provider.transcribe(wavData: Data())
        XCTAssertEqual(viaClip, Transcript(text: "um send it Wednesday"))
        let session = try await provider.openSession(target: DictationTarget(), trace: nil)
        let viaSession = try await session.commit(pcm: Data())
        XCTAssertEqual(viaSession, Transcript(text: "um send it Wednesday"))
    }

    func testAMissingPromptPastesTheRawTranscript() async throws {
        let provider = CleanedUpProvider(base: Fixed(text: "um hi")) { _ in throw DictationCleaner.Failure.noPrompt }
        let transcript = try await provider.transcribe(wavData: Data())
        XCTAssertEqual(transcript, Transcript(text: "um hi"))
    }

    func testItKeepsTheBaseProvidersIdentity() {
        XCTAssertEqual(unreachable("x").id, .parakeet)
    }
}

final class CleanupMenuStateTests: XCTestCase {
    private func make(enabled: Bool, phase: CleanupServer.Phase = .idle, modelPresent: Bool = true,
                      downloaded: Bool = true, healthy: Bool = true) -> CleanupMenuState {
        CleanupMenuState.make(enabled: enabled, phase: phase, modelPresent: modelPresent,
                              downloaded: downloaded, healthy: healthy)
    }

    func testOffShowsJustTheCheckbox() {
        let state = make(enabled: false, downloaded: false, healthy: false)
        XCTAssertNil(state.status)
        XCTAssertFalse(state.showDelete)
        XCTAssertFalse(state.showInstructions)
    }

    func testOnAndWorkingSaysNothingExtra() {
        XCTAssertNil(make(enabled: true).status)
    }

    func testInstructionsShowOnlyWhileTheModelIsMissing() {
        XCTAssertTrue(make(enabled: false, modelPresent: false, downloaded: false).showInstructions)
        XCTAssertFalse(make(enabled: false).showInstructions)
    }

    func testOffWithTheModelDownloadedOffersToDeleteIt() {
        XCTAssertTrue(make(enabled: false, healthy: false).showDelete)
    }

    func testOnButNotAnsweringWarns() {
        XCTAssertTrue(make(enabled: true, healthy: false).status?.hasPrefix("⚠︎") ?? false)
    }

    func testWorkingSaysWhatAndHidesDelete() {
        let state = make(enabled: false, phase: .working("stopping"))
        XCTAssertEqual(state.status, "Clean-up: stopping…")
        XCTAssertFalse(state.showDelete)
    }
}

/// `CleanupServer` against a temporary directory tree, a scripted command
/// runner and a fake downloader: nothing here downloads, runs `launchctl`, or
/// touches the real LaunchAgents or Application Support.
@MainActor
final class CleanupServerTests: XCTestCase {
    private var root: URL!
    private var paths: CleanupServer.Paths!
    private var runner: Runner!
    private var fetched: Fetched!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanup-server-tests-\(UUID().uuidString)", isDirectory: true)
        paths = CleanupServer.Paths(installDir: root.appendingPathComponent("support/cleanup", isDirectory: true),
                                    launchAgents: root.appendingPathComponent("LaunchAgents", isDirectory: true),
                                    log: root.appendingPathComponent("Logs/VoiceOperator-cleanup.log"))
        runner = Runner(server: paths.server)
        fetched = Fetched()
        try placeModel("the model")
    }

    /// What the user downloads by hand.
    private func placeModel(_ contents: String) throws {
        try FileManager.default.createDirectory(at: paths.installDir, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: paths.model)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeServer(healthy: Bool = true) -> CleanupServer {
        let fetched = self.fetched!
        return CleanupServer(paths: paths, runner: runner, isBusy: { false }, probe: { healthy },
                             fetch: { download, destination, progress in
                                 progress(0.5)
                                 FileManager.default.createFile(atPath: destination.path, contents: Data("x".utf8))
                                 fetched.add(download.url.lastPathComponent)
                             },
                             pollInterval: .milliseconds(5), startTimeout: .milliseconds(50),
                             modelSHA256: "36cc7e3d6f6200756c81e18470827e9dac1c602fcd87761cbb0b8f015611c098")
    }

    func testEnableDownloadsLlamaAndStartsTheAgent() async throws {
        let server = makeServer()
        server.enable()
        await server.waitForJob()

        XCTAssertEqual(server.phase, .idle)
        XCTAssertTrue(server.healthy)
        XCTAssertTrue(server.isDownloaded)
        XCTAssertTrue(server.isEnabled)
        XCTAssertEqual(fetched.names, ["llama-b11669-bin-macos-arm64.tar.gz"])
        XCTAssertTrue(runner.lines.contains { $0.hasPrefix("/bin/launchctl bootstrap") })
    }

    func testEnablingAgainLeavesARunningServerAlone() async throws {
        let server = makeServer()
        server.enable()
        await server.waitForJob()
        server.enable()
        await server.waitForJob()

        XCTAssertEqual(server.phase, .idle)
        XCTAssertEqual(runner.lines.filter { $0.hasPrefix("/bin/launchctl bootstrap") }.count, 1)
        XCTAssertFalse(runner.lines.contains { $0.hasPrefix("/bin/launchctl bootout") })
    }

    func testEnableDeletesOtherBuildsButNotTheUsersFiles() async throws {
        let stale = paths.installDir.appendingPathComponent("llama-b10000", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        let partial = paths.installDir.appendingPathComponent("llama-b11669.tar.gz.partial")
        FileManager.default.createFile(atPath: partial.path, contents: Data())
        let usersOwn = paths.installDir.appendingPathComponent("fluid-1-mini-q4_k.gguf")
        FileManager.default.createFile(atPath: usersOwn.path, contents: Data())

        let server = makeServer()
        server.enable()
        await server.waitForJob()

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: usersOwn.path))
        XCTAssertTrue(server.isDownloaded)
    }

    func testNoModelMeansNoServerAndSaysWhere() async throws {
        try FileManager.default.removeItem(at: paths.model)
        let server = makeServer()
        server.enable()
        await server.waitForJob()

        XCTAssertEqual(server.phase, .failed(CleanupServer.Failure.modelMissing.localizedDescription))
        XCTAssertFalse(server.isEnabled)
    }

    func testTheWrongModelFileIsRefused() async throws {
        try placeModel("something else")
        let server = makeServer()
        server.enable()
        await server.waitForJob()

        XCTAssertEqual(server.phase, .failed(CleanupServer.Failure.modelMismatch.localizedDescription))
        XCTAssertFalse(server.isEnabled)
    }

    func testAServerThatNeverAnswersFails() async throws {
        let server = makeServer(healthy: false)
        server.enable()
        await server.waitForJob()
        XCTAssertEqual(server.phase, .failed(CleanupServer.Failure.didNotStart.localizedDescription))
    }

    func testDisableUnloadsTheAgentButKeepsTheFiles() async throws {
        let server = makeServer()
        server.enable()
        await server.waitForJob()
        server.disable()
        await server.waitForJob()

        XCTAssertFalse(server.isEnabled)
        XCTAssertTrue(server.isDownloaded)
        XCTAssertTrue(runner.lines.contains { $0.hasPrefix("/bin/launchctl bootout") })
    }

    func testDeleteRemovesEverything() async throws {
        let server = makeServer()
        server.enable()
        await server.waitForJob()
        server.delete()
        await server.waitForJob()

        XCTAssertFalse(server.isEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.installDir.path))
    }

    func testTheAgentServesOnlyLoopbackWithOneSlot() throws {
        let plist = try PropertyListSerialization.propertyList(from: CleanupServer.plistData(paths: paths),
                                                               format: nil) as? [String: Any]
        let arguments = try XCTUnwrap(plist?["ProgramArguments"] as? [String])
        XCTAssertEqual(arguments.first, paths.server.path)
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--host")! + 1], "127.0.0.1")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--port")! + 1], String(CleanupServer.port))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--parallel")! + 1], "1")
    }

    func testDigestReadsInChunks() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("digest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try FileDownloader.digest(file),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

private final class Fetched: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    var names: [String] { lock.withLock { list } }
    func add(_ name: String) { lock.withLock { list.append(name) } }
}

/// Records every command and plays the part of `tar`, `launchctl` and `lsof`.
private final class Runner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []
    private var loaded = false
    private let server: URL
    var lines: [String] { lock.withLock { commands } }

    init(server: URL) { self.server = server }

    func run(_ executable: String, _ arguments: [String], environment: [String: String],
             logTo: URL?) async throws -> CommandResult {
        lock.withLock { commands.append(([executable] + arguments).joined(separator: " ")) }
        switch executable {
        case "/usr/bin/tar":
            try FileManager.default.createDirectory(at: server.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: server.path, contents: Data("#!/bin/sh\n".utf8),
                                           attributes: [.posixPermissions: 0o755])
            return CommandResult(status: 0, output: "")
        case "/usr/sbin/lsof":
            return CommandResult(status: 1, output: "")
        case "/bin/launchctl":
            return lock.withLock {
                switch arguments.first {
                case "bootstrap": loaded = true
                case "bootout": loaded = false
                case "print": return CommandResult(status: loaded ? 0 : 113, output: "")
                default: break
                }
                return CommandResult(status: 0, output: "")
            }
        default:
            return CommandResult(status: 0, output: "")
        }
    }
}
