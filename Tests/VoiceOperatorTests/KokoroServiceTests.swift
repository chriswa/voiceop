import XCTest
@testable import VoiceOperator

/// `KokoroService` against a temporary directory tree and a scripted command
/// runner: nothing here runs `uv` or `launchctl`, downloads anything, or touches
/// the real LaunchAgents, Application Support, defaults or port.
@MainActor
final class KokoroServiceTests: XCTestCase {
    private var root: URL!
    private var paths: KokoroService.Paths!
    private var runner: FakeRunner!
    private var health: HealthBox!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var busy = false
    private var uvFetches: Counter!
    private var fetchedUV: Int { uvFetches.value }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kokoro-service-tests-\(UUID().uuidString)", isDirectory: true)
        let bundled = root.appendingPathComponent("bundle/kokoro", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try "server v1".write(to: bundled.appendingPathComponent("kokoro_server.py"), atomically: true, encoding: .utf8)
        try "torch==2.14.0".write(to: bundled.appendingPathComponent("requirements.txt"), atomically: true, encoding: .utf8)
        try "[\"am_santa\"]".write(to: bundled.appendingPathComponent("blocked_voices.json"), atomically: true, encoding: .utf8)
        paths = KokoroService.Paths(
            installDir: root.appendingPathComponent("support/kokoro", isDirectory: true),
            launchAgents: root.appendingPathComponent("LaunchAgents", isDirectory: true),
            log: root.appendingPathComponent("Logs/VoiceOperator-kokoro.log"),
            bundled: bundled)
        health = HealthBox()
        runner = FakeRunner(python: paths.python, health: health)
        defaultsSuite = "KokoroServiceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        busy = false
        uvFetches = Counter()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: defaultsSuite)
    }

    /// `espeakLimit` is lifted by default: the test temp directory is itself
    /// deeper than espeak-ng allows. `testOverlongInstallPathIsRefused` checks it.
    private func makeService(systemUV: String? = "/fake/uv", espeakLimit: Int = 10_000) -> KokoroService {
        let health = self.health!, uvFetches = self.uvFetches!
        let fetch: @Sendable (URL) async throws -> Void = { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let uv = directory.appendingPathComponent("uv")
            FileManager.default.createFile(atPath: uv.path, contents: Data("#!/bin/sh\n".utf8),
                                           attributes: [.posixPermissions: 0o755])
            uvFetches.increment()
        }
        return KokoroService(paths: paths, runner: runner, isBusy: { [unowned self] in self.busy },
                             probe: { health.value }, systemUV: { systemUV }, fetchUV: fetch,
                             defaults: defaults, pollInterval: .milliseconds(5),
                             startTimeout: .milliseconds(200), espeakLimit: espeakLimit)
    }

    private var fm: FileManager { .default }
    private var commandLines: [String] { runner.commands.map { $0.joined(separator: " ") } }

    // MARK: - Install

    func testInstallBuildsVenvAndStartsTheAgent() async throws {
        let service = makeService()
        XCTAssertFalse(service.isInstalled)

        service.install()
        await service.waitForJob()

        XCTAssertEqual(service.phase, .idle)
        XCTAssertEqual(service.progress, 1)
        XCTAssertTrue(service.isInstalled)
        XCTAssertEqual(service.health, .init(memoryMB: 1800, pid: 1234))
        XCTAssertEqual(try String(contentsOf: paths.server, encoding: .utf8), "server v1")
        XCTAssertTrue(fm.fileExists(atPath: paths.installDir.appendingPathComponent("blocked_voices.json").path))

        let venv = try XCTUnwrap(commandLines.firstIndex { $0.hasPrefix("/fake/uv venv") })
        let pip = try XCTUnwrap(commandLines.firstIndex { $0.hasPrefix("/fake/uv pip install") })
        let bootstrap = try XCTUnwrap(commandLines.firstIndex { $0.contains("bootstrap") && $0.contains(KokoroService.label) })
        XCTAssertLessThan(venv, pip)
        XCTAssertLessThan(pip, bootstrap)
        // Python lives inside the install, so Uninstall takes it and nothing else upgrades it.
        XCTAssertTrue(commandLines[venv].contains("--managed-python"))
        XCTAssertEqual(runner.environments[venv]["UV_PYTHON_INSTALL_DIR"], paths.pythonInstalls.path)
        XCTAssertEqual(fetchedUV, 0, "the Mac's own uv is used when it has one")
    }

    func testDownloadsUVWhenTheMacHasNone() async throws {
        let service = makeService(systemUV: nil)
        service.install()
        await service.waitForJob()
        XCTAssertEqual(service.phase, .idle)
        XCTAssertEqual(fetchedUV, 1)
        XCTAssertTrue(commandLines.contains { $0.hasPrefix("\(paths.privateUV.path) venv") })
        XCTAssertTrue(commandLines.contains { $0.hasPrefix("\(paths.privateUV.path) pip install") })

        // A later update that needs uv reuses the downloaded one.
        try "torch==2.15.0".write(to: paths.bundled!.appendingPathComponent("requirements.txt"), atomically: true, encoding: .utf8)
        service.update()
        await service.waitForJob()
        XCTAssertEqual(service.phase, .idle)
        XCTAssertEqual(fetchedUV, 1)
    }

    func testUninstallTakesTheDownloadedUVAndPython() async throws {
        let service = makeService(systemUV: nil)
        service.install()
        await service.waitForJob()
        XCTAssertTrue(fm.fileExists(atPath: paths.privateUV.path))
        service.uninstall()
        await service.waitForJob()
        XCTAssertFalse(fm.fileExists(atPath: paths.installDir.path))
        XCTAssertFalse(fm.fileExists(atPath: paths.plist.path))
    }

    func testForeignProcessOnThePortBlocksInstall() async throws {
        runner.portHolder = "p4242\ncnode\n"
        let service = makeService()
        service.install()
        await service.waitForJob()
        XCTAssertEqual(service.phase, .failed(KokoroService.Failure.portInUse("node (pid 4242)").localizedDescription))
        XCTAssertFalse(runner.commands.contains { $0.first == "/fake/uv" })
        XCTAssertFalse(commandLines.contains { $0.contains("bootout") }, "never stops someone else's server")
    }

    func testOverlongInstallPathIsRefused() async throws {
        let service = makeService(espeakLimit: KokoroService.espeakPathLimit)
        XCTAssertGreaterThanOrEqual(paths.espeakData.path.utf8.count, KokoroService.espeakPathLimit)
        service.install()
        await service.waitForJob()
        guard case .failed(let reason) = service.phase else { return XCTFail("expected failure") }
        XCTAssertTrue(reason.contains("espeak"), reason)
    }

    func testServerThatNeverAnswersFails() async throws {
        runner.healthAfterBootstrap = false
        let service = makeService()
        service.install()
        await service.waitForJob()
        XCTAssertEqual(service.phase, .failed(KokoroService.Failure.didNotStart.localizedDescription))
    }

    func testCancelDuringPackageInstallStartsNothing() async throws {
        runner.pipDelay = .seconds(5)
        let service = makeService()
        service.install()
        for _ in 0..<400 where !(service.canCancel && runner.commands.contains { $0.contains("pip") }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(service.canCancel)
        service.cancel()
        await service.waitForJob()
        XCTAssertEqual(service.phase, .failed("install cancelled"))
        XCTAssertFalse(commandLines.contains { $0.contains("bootstrap") })
    }

    func testReinstallWaitsForSpeechAndKeepsTheRuntimeBlocklist() async throws {
        let service = makeService()
        service.install()
        await service.waitForJob()
        let blocklist = paths.installDir.appendingPathComponent("blocked_voices.json")
        try "[\"af_nicole\"]".write(to: blocklist, atomically: true, encoding: .utf8)
        try fm.removeItem(at: paths.python)   // a broken venv: Install is offered again
        runner.commands.removeAll()
        busy = true
        service.install()
        for _ in 0..<200 where service.phase != .working("waiting for speech to finish") {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(commandLines.contains { $0.contains("bootout") }, "our running server isn't stopped mid-speech")
        busy = false
        await service.waitForJob()
        XCTAssertEqual(service.phase, .idle)
        XCTAssertTrue(commandLines.contains { $0.contains("bootout") && $0.contains(KokoroService.label) })
        XCTAssertEqual(try String(contentsOf: blocklist, encoding: .utf8), "[\"af_nicole\"]")
    }

    // MARK: - Automatic

    func testAutoStartInstallsWhenNothingIsInstalled() async throws {
        let service = makeService()
        service.autoStart(provider: .kokoroLocal)
        await service.waitForJob()
        XCTAssertTrue(service.isInstalled)
        XCTAssertEqual(service.action, .install)
    }

    func testAutoStartLeavesACustomServerAlone() async throws {
        let service = makeService()
        service.autoStart(provider: .custom(url: "https://tts.example.com"))
        await service.waitForJob()
        XCTAssertFalse(service.isInstalled)
        XCTAssertTrue(runner.commands.isEmpty)
    }

    func testAutoStartRespectsAnUninstall() async throws {
        let service = makeService()
        service.install()
        await service.waitForJob()
        service.uninstall()
        await service.waitForJob()
        runner.commands.removeAll()
        service.autoStart(provider: .kokoroLocal)
        await service.waitForJob()
        XCTAssertTrue(runner.commands.isEmpty, "an uninstall isn't undone at the next launch")

        service.install()   // choosing Install again clears that
        await service.waitForJob()
        XCTAssertFalse(defaults.bool(forKey: KokoroService.declinedKey))
    }

    func testAutoStartAppliesANewerBundledServer() async throws {
        let service = makeService()
        service.install()
        await service.waitForJob()
        try "server v2".write(to: paths.bundled!.appendingPathComponent("kokoro_server.py"), atomically: true, encoding: .utf8)
        runner.commands.removeAll()
        service.autoStart(provider: .kokoroLocal)
        await service.waitForJob()
        XCTAssertEqual(service.action, .update)
        XCTAssertEqual(try String(contentsOf: paths.server, encoding: .utf8), "server v2")
        XCTAssertTrue(commandLines.contains { $0.contains("kickstart") })
        XCTAssertFalse(commandLines.contains { $0.contains("pip") }, "requirements unchanged: no reinstall")
    }

    // MARK: - Update / restart / uninstall

    func testUpdateAvailableFollowsTheBundledFiles() async throws {
        let service = makeService()
        service.install()
        await service.waitForJob()
        XCTAssertFalse(service.updateAvailable)
        try "server v2".write(to: paths.bundled!.appendingPathComponent("kokoro_server.py"), atomically: true, encoding: .utf8)
        XCTAssertTrue(service.updateAvailable)
        service.update()
        await service.waitForJob()
        XCTAssertFalse(service.updateAvailable)
    }

    func testRestartWaitsForSpeech() async throws {
        let service = makeService()
        service.install()
        await service.waitForJob()
        runner.commands.removeAll()
        busy = true
        service.restart()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(commandLines.contains { $0.contains("kickstart") })
        busy = false
        await service.waitForJob()
        XCTAssertTrue(commandLines.contains { $0.contains("kickstart") })
        XCTAssertEqual(service.phase, .idle)
    }

    func testPlistRunsTheVenvPythonAndKeepsAlive() throws {
        let data = try KokoroService.plistData(paths: paths)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, KokoroService.label)
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [paths.python.path, "-W", "ignore", paths.server.path])
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["StandardOutPath"] as? String, paths.log.path)
        XCTAssertNil(plist["StartCalendarInterval"], "no scheduled restart")
    }

    func testLastLogLineSkipsBlankLines() throws {
        try fm.createDirectory(at: paths.log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Resolved 94 packages\r\nDownloading torch (70.1MiB)\n\n".write(to: paths.log, atomically: true, encoding: .utf8)
        XCTAssertEqual(makeService().lastLogLine(), "Downloading torch (70.1MiB)")
    }

    func testPinnedUVIsTheAppleSiliconBuildWithAChecksum() {
        XCTAssertEqual(KokoroService.uvSHA256.count, 64)
        XCTAssertTrue(KokoroService.uvURL.absoluteString.hasSuffix("uv-aarch64-apple-darwin.tar.gz"))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// The `/health` answer the fake server gives, flipped by the fake runner.
private final class HealthBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: KokoroService.Health?
    var value: KokoroService.Health? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Records every command and plays the part of `uv`, `launchctl` and `lsof`.
private final class FakeRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [[String]] = []
    private var _environments: [[String: String]] = []
    let python: URL
    let health: HealthBox
    var healthAfterBootstrap = true
    var portHolder: String?
    var pipDelay: Duration = .zero

    init(python: URL, health: HealthBox) {
        self.python = python
        self.health = health
    }

    var commands: [[String]] {
        get { lock.withLock { _commands } }
        set { lock.withLock { _commands = newValue; _environments = newValue.map { _ in [:] } } }
    }
    var environments: [[String: String]] { lock.withLock { _environments } }

    func run(_ executable: String, _ arguments: [String], environment: [String: String],
             logTo: URL?) async throws -> CommandResult {
        lock.withLock {
            _commands.append([executable] + arguments)
            _environments.append(environment)
        }
        let isUV = executable.hasSuffix("/uv")
        switch (isUV, executable, arguments.first) {
        case (true, _, "venv"):
            try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: python.path, contents: Data())
            return .init(status: 0, output: "")
        case (true, _, "pip"):
            if pipDelay != .zero { try await Task.sleep(for: pipDelay) }
            return .init(status: 0, output: "Installed 94 packages")
        case (_, "/bin/launchctl", "bootstrap"):
            if healthAfterBootstrap { health.value = .init(memoryMB: 1800, pid: 1234) }
            return .init(status: 0, output: "")
        case (_, "/bin/launchctl", "bootout"):
            health.value = nil
            return .init(status: 0, output: "")
        case (_, "/bin/launchctl", "kickstart"):
            health.value = .init(memoryMB: 1700, pid: 1235)
            return .init(status: 0, output: "")
        case (_, "/usr/sbin/lsof", _):
            if let holder = portHolder { return .init(status: 0, output: holder) }
            return .init(status: 1, output: "")
        default:
            return .init(status: 0, output: "")
        }
    }
}

/// The real `Process` runner, on harmless shell commands.
final class ProcessRunnerTests: XCTestCase {
    func testCapturesOutputStatusAndLog() async throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("runner-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let result = try await ProcessRunner().run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"], logTo: log)
        XCTAssertEqual(result.status, 3)
        XCTAssertTrue(result.output.contains("out") && result.output.contains("err"), result.output)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), result.output)
    }

    func testPassesExtraEnvironment() async throws {
        let result = try await ProcessRunner().run("/bin/sh", ["-c", "echo \"$KOKORO_TEST_VAR\""],
                                                   environment: ["KOKORO_TEST_VAR": "hello"], logTo: nil)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testCancellingTerminatesTheProcess() async throws {
        let started = ContinuousClock.now
        let task = Task { try await ProcessRunner().run("/bin/sleep", ["30"]) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = try await task.value
        XCTAssertNotEqual(result.status, 0)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))
    }
}
