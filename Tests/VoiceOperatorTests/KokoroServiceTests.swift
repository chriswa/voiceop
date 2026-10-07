import XCTest
@testable import VoiceOperator

/// `KokoroService` against a temporary directory tree and a scripted command
/// runner: nothing here runs `uv` or `launchctl`, or touches the real
/// LaunchAgents, Application Support or port.
@MainActor
final class KokoroServiceTests: XCTestCase {
    private var root: URL!
    private var paths: KokoroService.Paths!
    private var runner: FakeRunner!
    private var health: HealthBox!
    private var busy = false

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
            legacyBackup: root.appendingPathComponent("support/legacy", isDirectory: true),
            bundled: bundled)
        try FileManager.default.createDirectory(at: paths.launchAgents, withIntermediateDirectories: true)
        health = HealthBox()
        runner = FakeRunner(python: paths.python, health: health)
        busy = false
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// `espeakLimit` is lifted by default: the test temp directory is itself
    /// deeper than espeak-ng allows. `testOverlongInstallPathIsRefused` checks it.
    private func makeService(uv: String? = "/fake/uv", espeakLimit: Int = 10_000) -> KokoroService {
        let health = self.health!
        return KokoroService(paths: paths, runner: runner, isBusy: { [unowned self] in self.busy },
                             probe: { health.value }, locateUV: { uv }, pollInterval: .milliseconds(5),
                             startTimeout: .milliseconds(200), espeakLimit: espeakLimit)
    }

    private func writeLegacyPlists() throws {
        for label in KokoroService.legacyLabels {
            try "legacy".write(to: paths.legacyPlist(label), atomically: true, encoding: .utf8)
        }
    }

    private var fm: FileManager { .default }

    // MARK: - Install

    func testInstallBuildsVenvWritesAgentAndRetiresLegacy() async throws {
        try writeLegacyPlists()
        let service = makeService()
        XCTAssertFalse(service.isInstalled)
        XCTAssertTrue(service.legacyInstalled)

        service.install()
        await service.waitForJob()

        XCTAssertEqual(service.phase, .idle)
        XCTAssertTrue(service.isInstalled)
        XCTAssertFalse(service.legacyInstalled)
        for label in KokoroService.legacyLabels {
            XCTAssertTrue(fm.fileExists(atPath: paths.legacyBackup.appendingPathComponent("\(label).plist").path))
        }
        XCTAssertEqual(try String(contentsOf: paths.server, encoding: .utf8), "server v1")
        XCTAssertTrue(fm.fileExists(atPath: paths.installDir.appendingPathComponent("blocked_voices.json").path))

        let commands = runner.commands.map { $0.joined(separator: " ") }
        let venv = try XCTUnwrap(commands.firstIndex { $0.hasPrefix("/fake/uv venv") })
        let pip = try XCTUnwrap(commands.firstIndex { $0.hasPrefix("/fake/uv pip install") })
        let legacyOut = try XCTUnwrap(commands.firstIndex { $0.contains("bootout") && $0.contains("com.chriswa.kokoro-tts") })
        let bootstrap = try XCTUnwrap(commands.firstIndex { $0.contains("bootstrap") && $0.contains(KokoroService.label) })
        // The old server keeps serving until the new venv is fully built.
        XCTAssertLessThan(venv, pip)
        XCTAssertLessThan(pip, legacyOut)
        XCTAssertLessThan(legacyOut, bootstrap)
    }

    func testInstallWaitsForSpeechBeforeSwitchingOver() async throws {
        try writeLegacyPlists()
        busy = true
        let service = makeService()
        service.install()
        // Long enough for every preparation step, with the switch-over held.
        for _ in 0..<200 where service.phase != .working("waiting for speech to finish") {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(service.phase, .working("waiting for speech to finish"))
        XCTAssertFalse(runner.commands.contains { $0.contains("bootout") }, "nothing may stop the old server while speaking")
        XCTAssertTrue(service.legacyInstalled)
        busy = false
        await service.waitForJob()
        XCTAssertEqual(service.phase, .idle)
        XCTAssertTrue(service.isInstalled)
    }

    func testFailedSwitchOverRestoresLegacyAgents() async throws {
        try writeLegacyPlists()
        runner.failBootstrapOf = KokoroService.label
        let service = makeService()
        service.install()
        await service.waitForJob()

        guard case .failed = service.phase else { return XCTFail("expected failure, got \(service.phase)") }
        XCTAssertTrue(service.legacyInstalled, "the legacy plists are moved back")
        XCTAssertFalse(fm.fileExists(atPath: paths.plist.path))
        let rebootstrapped = runner.commands.filter { $0.contains("bootstrap") && $0.contains { $0.hasSuffix("com.chriswa.kokoro-tts.plist") } }
        XCTAssertEqual(rebootstrapped.count, 1)
    }

    func testServerThatNeverAnswersRollsBack() async throws {
        try writeLegacyPlists()
        runner.healthAfterBootstrap = false
        let service = makeService()
        service.install()
        await service.waitForJob()
        XCTAssertEqual(service.phase, .failed(KokoroService.Failure.didNotStart.localizedDescription))
        XCTAssertTrue(service.legacyInstalled, "the old server is put back")
        XCTAssertFalse(fm.fileExists(atPath: paths.plist.path))
    }

    func testUVMissingFailsWithoutTouchingAnything() async throws {
        try writeLegacyPlists()
        let service = makeService(uv: nil)
        service.install()
        await service.waitForJob()
        XCTAssertEqual(service.phase, .failed(KokoroService.Failure.uvMissing.localizedDescription))
        XCTAssertTrue(runner.commands.isEmpty)
        XCTAssertTrue(service.legacyInstalled)
    }

    func testForeignProcessOnThePortBlocksInstall() async throws {
        runner.portHolder = "p4242\ncnode\n"
        let service = makeService()
        service.install()
        await service.waitForJob()
        XCTAssertEqual(service.phase, .failed(KokoroService.Failure.portInUse("node (pid 4242)").localizedDescription))
        XCTAssertFalse(runner.commands.contains { $0.first == "/fake/uv" })
    }

    func testOverlongInstallPathIsRefused() async throws {
        let service = makeService(espeakLimit: KokoroService.espeakPathLimit)
        XCTAssertGreaterThanOrEqual(paths.espeakData.path.utf8.count, KokoroService.espeakPathLimit)
        service.install()
        await service.waitForJob()
        guard case .failed(let reason) = service.phase else { return XCTFail("expected failure") }
        XCTAssertTrue(reason.contains("espeak"), reason)
    }

    func testCancelDuringPackageInstallLeavesLegacyRunning() async throws {
        try writeLegacyPlists()
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
        XCTAssertTrue(service.legacyInstalled)
        XCTAssertFalse(runner.commands.contains { $0.contains("bootout") })
    }

    func testReinstallKeepsTheRuntimeBlocklist() async throws {
        let service = makeService()
        service.install()
        await service.waitForJob()
        let blocklist = paths.installDir.appendingPathComponent("blocked_voices.json")
        try "[\"af_nicole\"]".write(to: blocklist, atomically: true, encoding: .utf8)
        try fm.removeItem(at: paths.python)   // force Install to be offered again
        service.install()
        await service.waitForJob()
        XCTAssertEqual(try String(contentsOf: blocklist, encoding: .utf8), "[\"af_nicole\"]")
    }

    // MARK: - Update / restart / uninstall

    func testUpdateAvailableFollowsTheBundledFiles() async throws {
        let service = makeService()
        service.install()
        await service.waitForJob()
        XCTAssertFalse(service.updateAvailable)
        try "server v2".write(to: paths.bundled!.appendingPathComponent("kokoro_server.py"), atomically: true, encoding: .utf8)
        XCTAssertTrue(service.updateAvailable)

        runner.commands.removeAll()
        service.update()
        await service.waitForJob()
        XCTAssertFalse(service.updateAvailable)
        XCTAssertEqual(try String(contentsOf: paths.server, encoding: .utf8), "server v2")
        XCTAssertFalse(runner.commands.contains { $0.contains("pip") }, "requirements unchanged: no reinstall")
        XCTAssertTrue(runner.commands.contains { $0.contains("kickstart") })
    }

    func testRestartWaitsForSpeech() async throws {
        let service = makeService()
        service.install()
        await service.waitForJob()
        runner.commands.removeAll()
        busy = true
        service.restart()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(runner.commands.contains { $0.contains("kickstart") })
        busy = false
        await service.waitForJob()
        XCTAssertTrue(runner.commands.contains { $0.contains("kickstart") })
        XCTAssertEqual(service.phase, .idle)
    }

    func testUninstallRemovesAgentAndInstallButNotLegacyBackup() async throws {
        try writeLegacyPlists()
        let service = makeService()
        service.install()
        await service.waitForJob()
        service.uninstall()
        await service.waitForJob()
        XCTAssertFalse(service.isInstalled)
        XCTAssertFalse(fm.fileExists(atPath: paths.installDir.path))
        XCTAssertFalse(fm.fileExists(atPath: paths.plist.path))
        XCTAssertTrue(fm.fileExists(atPath: paths.legacyBackup.path))
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
    let python: URL
    let health: HealthBox
    var failBootstrapOf: String?
    var healthAfterBootstrap = true
    var portHolder: String?
    var pipDelay: Duration = .zero

    init(python: URL, health: HealthBox) {
        self.python = python
        self.health = health
    }

    var commands: [[String]] {
        get { lock.withLock { _commands } }
        set { lock.withLock { _commands = newValue } }
    }

    func run(_ executable: String, _ arguments: [String], logTo: URL?) async throws -> CommandResult {
        lock.withLock { _commands.append([executable] + arguments) }
        switch (executable, arguments.first) {
        case ("/fake/uv", "venv"):
            try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: python.path, contents: Data())
            return .init(status: 0, output: "")
        case ("/fake/uv", "pip"):
            if pipDelay != .zero { try await Task.sleep(for: pipDelay) }
            return .init(status: 0, output: "Installed 94 packages")
        case ("/bin/launchctl", "bootstrap"):
            if let failing = failBootstrapOf, arguments.last?.contains(failing) == true {
                return .init(status: 5, output: "Bootstrap failed: 5: Input/output error")
            }
            if healthAfterBootstrap { health.value = .init(memoryMB: 1800, pid: 1234) }
            return .init(status: 0, output: "")
        case ("/bin/launchctl", "bootout"):
            health.value = nil
            return .init(status: 0, output: "")
        case ("/bin/launchctl", "kickstart"):
            health.value = .init(memoryMB: 1700, pid: 1235)
            return .init(status: 0, output: "")
        case ("/usr/sbin/lsof", _):
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
