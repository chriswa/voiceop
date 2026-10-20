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
        func transcribe(wavData: Data) async throws -> String { text }
        func transcribeAfterLiveFailure(wavData: Data) async throws -> String { text }
        func prewarm() async -> String? { nil }

        struct Session: TranscriptionSession {
            let text: String
            func send(pcm: Data) async {}
            func commit(pcm: Data) async throws -> String { text }
            func cancel() async {}
        }
    }

    /// Nothing listens on port 9 of loopback.
    private func unreachable(_ text: String) -> CleanedUpProvider {
        CleanedUpProvider(base: Fixed(text: text)) {
            var cleaner = DictationCleaner(systemPrompt: "Clean it.")
            cleaner.endpoint = URL(string: "http://127.0.0.1:9/completion")!
            return cleaner
        }
    }

    func testAFailedCleanUpPastesTheRawTranscript() async throws {
        let provider = unreachable("um send it Wednesday")
        let viaClip = try await provider.transcribe(wavData: Data())
        XCTAssertEqual(viaClip, "um send it Wednesday")
        let session = try await provider.openSession(target: DictationTarget(), trace: nil)
        let viaSession = try await session.commit(pcm: Data())
        XCTAssertEqual(viaSession, "um send it Wednesday")
    }

    func testAMissingPromptPastesTheRawTranscript() async throws {
        let provider = CleanedUpProvider(base: Fixed(text: "um hi")) { throw DictationCleaner.Failure.noPrompt }
        let text = try await provider.transcribe(wavData: Data())
        XCTAssertEqual(text, "um hi")
    }

    func testItKeepsTheBaseProvidersIdentity() {
        XCTAssertEqual(unreachable("x").id, .parakeet)
    }
}

final class CleanupMenuStateTests: XCTestCase {
    func testOffAndIdleShowsNoStatus() {
        let state = CleanupMenuState.make(enabled: false, phase: .idle, downloaded: false, healthy: false)
        XCTAssertNil(state.status)
        XCTAssertFalse(state.showDelete)
        XCTAssertTrue(state.actionsEnabled)
    }

    func testOffWithTheModelDownloadedOffersToDeleteIt() {
        XCTAssertTrue(CleanupMenuState.make(enabled: false, phase: .idle, downloaded: true, healthy: false).showDelete)
    }

    func testOnAndHealthyIsReady() {
        XCTAssertEqual(CleanupMenuState.make(enabled: true, phase: .idle, downloaded: true, healthy: true).status,
                       "Clean-up: ready")
    }

    func testOnButNotAnsweringWarns() {
        let status = CleanupMenuState.make(enabled: true, phase: .idle, downloaded: true, healthy: false).status
        XCTAssertTrue(status?.hasPrefix("⚠︎") ?? false)
    }

    func testWorkingDisablesTheCheckboxAndHidesDelete() {
        let state = CleanupMenuState.make(enabled: false, phase: .working("stopping"), downloaded: true, healthy: false)
        XCTAssertEqual(state.status, "Clean-up: stopping…")
        XCTAssertFalse(state.actionsEnabled)
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
                             pollInterval: .milliseconds(5), startTimeout: .milliseconds(50))
    }

    func testEnableDownloadsBothFilesAndStartsTheAgent() async throws {
        let server = makeServer()
        server.enable()
        await server.waitForJob()

        XCTAssertEqual(server.phase, .idle)
        XCTAssertTrue(server.healthy)
        XCTAssertTrue(server.isDownloaded)
        XCTAssertTrue(server.isEnabled)
        XCTAssertEqual(fetched.names, ["llama-b11669-bin-macos-arm64.tar.gz", CleanupServer.modelFile])
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

    func testEnableDeletesOtherDownloads() async throws {
        let stale = paths.installDir.appendingPathComponent("llama-b10000", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        let oldModel = paths.installDir.appendingPathComponent("fluid-1-mini-q4_k.gguf")
        FileManager.default.createFile(atPath: oldModel.path, contents: Data())

        let server = makeServer()
        server.enable()
        await server.waitForJob()

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldModel.path))
        XCTAssertTrue(server.isDownloaded)
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
