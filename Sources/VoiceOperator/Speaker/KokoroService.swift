import CryptoKit
import Foundation

/// Installs, updates, restarts and uninstalls the local Kokoro server — the
/// default TTS backend — as a per-user launchd agent. The Text to Speech menu
/// drives it; see `kokoro/CLAUDE.md` for the server itself.
///
/// The server's source ships inside the app (`Contents/Resources/kokoro`, copied
/// there by `make-app.sh` / `make-release.sh` from the repo's `kokoro/`). Install
/// copies it to Application Support, builds a Python 3.13 venv there with `uv`
/// from the pinned `requirements.txt`, and points one launchd agent
/// (`RunAtLoad` + `KeepAlive`) at it. There is no scheduled restart: the server
/// reports its memory instead (`/health` `memory_mb`, shown in the menu).
///
/// **Nothing here may cut off speech.** Every step that stops the running server
/// — the switch-over at the end of Install, Restart, Update, Uninstall — first
/// waits until `isBusy` (dictating or speaking) is false, the same rule as
/// `RestartCoordinator`.
///
/// Install also retires the hand-made setup this replaces (the `~/tts` checkout's
/// `com.chriswa.kokoro-tts` agent and its 02:00 restart agent): only after the new
/// venv is built, so a failed install leaves the old server running, and with a
/// rollback to it if the new one never comes up.
@MainActor
final class KokoroService {
    nonisolated static let label = "com.chriswa.voiceoperator.kokoro"
    /// The agents a hand-made `~/tts` setup used. Install boots them out and
    /// moves their plists aside (never deleting them, never touching `~/tts`).
    static let legacyLabels = ["com.chriswa.kokoro-tts", "com.chriswa.kokoro-tts-restart"]
    nonisolated static let port = 56841
    /// The files that make up an install, as shipped in the bundle.
    static let serverFiles = ["kokoro_server.py", "requirements.txt"]
    static let blocklistFile = "blocked_voices.json"
    /// espeak-ng (Kokoro's fallback G2P) silently falls back to a compiled-in
    /// data path — and the server dies at load — when its data path is this
    /// long or longer. Found on a deep scratch venv; checked before installing.
    nonisolated static let espeakPathLimit = 160
    /// Above this the log is truncated before the next install/update/restart,
    /// so the per-request `mem=` lines can't grow it forever.
    static let logLimitBytes = 5 * 1024 * 1024

    struct Paths: Sendable {
        /// `~/Library/Application Support/VoiceOperator/kokoro`
        var installDir: URL
        /// `~/Library/LaunchAgents`
        var launchAgents: URL
        /// `~/Library/Logs/VoiceOperator-kokoro.log`
        var log: URL
        /// Where the legacy plists are moved to. Outside `installDir`, so an
        /// Uninstall never deletes them.
        var legacyBackup: URL
        /// The server files inside the running app, nil when the build has none.
        var bundled: URL?

        var venv: URL { installDir.appendingPathComponent("venv", isDirectory: true) }
        var python: URL { venv.appendingPathComponent("bin/python") }
        var server: URL { installDir.appendingPathComponent("kokoro_server.py") }
        var plist: URL { launchAgents.appendingPathComponent("\(KokoroService.label).plist") }
        var espeakData: URL {
            venv.appendingPathComponent("lib/python3.13/site-packages/espeakng_loader/espeak-ng-data")
        }
        func legacyPlist(_ label: String) -> URL { launchAgents.appendingPathComponent("\(label).plist") }

        static var standard: Paths {
            let fm = FileManager.default
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VoiceOperator", isDirectory: true)
            let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            let bundled = Bundle.main.resourceURL?.appendingPathComponent("kokoro", isDirectory: true)
            return Paths(installDir: support.appendingPathComponent("kokoro", isDirectory: true),
                         launchAgents: library.appendingPathComponent("LaunchAgents", isDirectory: true),
                         log: library.appendingPathComponent("Logs/VoiceOperator-kokoro.log"),
                         legacyBackup: support.appendingPathComponent("legacy-kokoro-launchagents", isDirectory: true),
                         bundled: bundled.flatMap {
                             fm.fileExists(atPath: $0.appendingPathComponent("kokoro_server.py").path) ? $0 : nil
                         })
        }
    }

    /// What the service is doing, for the menu's status line.
    enum Phase: Equatable, Sendable {
        case idle
        /// A step is running; the text names it ("installing packages…").
        case working(String)
        /// The last action failed; the text says why. Cleared by the next action.
        case failed(String)
    }

    /// What `/health` said, or nil when nothing answered.
    struct Health: Equatable, Sendable {
        var memoryMB: Int?
        var pid: Int?
    }

    enum Failure: LocalizedError, Equatable {
        case noBundledServer
        case uvMissing
        case pathTooLong(Int)
        case portInUse(String)
        case command(String, String)
        case didNotStart

        var errorDescription: String? {
            switch self {
            case .noBundledServer: return "this build doesn't include the Kokoro server files"
            case .uvMissing: return "uv is not installed"
            case .pathTooLong(let n): return "install path too long for espeak-ng (\(n) characters; it needs under \(KokoroService.espeakPathLimit))"
            case .portInUse(let who): return "port \(KokoroService.port) is in use by \(who)"
            case .command(let step, let detail): return "\(step) failed: \(detail)"
            case .didNotStart: return "the server did not come up"
            }
        }
    }

    private(set) var phase: Phase = .idle { didSet { onChange?() } }
    /// The last `/health` answer from port 56841; nil when it didn't answer.
    private(set) var health: Health? { didSet { if health != oldValue { onChange?() } } }
    /// The menu re-reads its state whenever this fires.
    var onChange: (() -> Void)?

    let paths: Paths
    private let runner: CommandRunner
    private let isBusy: () -> Bool
    private let probe: @Sendable () async -> Health?
    private let locateUV: () -> String?
    private let pollInterval: Duration
    /// How long a fresh install may take to answer `/health`: the first start
    /// downloads the model.
    private let startTimeout: Duration
    private let espeakLimit: Int
    private var job: Task<Void, Never>?
    private var cancellable = false

    init(paths: Paths = .standard,
         runner: CommandRunner = ProcessRunner(),
         isBusy: @escaping () -> Bool,
         probe: @escaping @Sendable () async -> Health? = { await KokoroService.probeHealth() },
         locateUV: @escaping () -> String? = { KokoroService.findUV() },
         pollInterval: Duration = .seconds(1),
         startTimeout: Duration = .seconds(600),
         espeakLimit: Int = KokoroService.espeakPathLimit) {
        self.paths = paths
        self.runner = runner
        self.isBusy = isBusy
        self.probe = probe
        self.locateUV = locateUV
        self.pollInterval = pollInterval
        self.startTimeout = startTimeout
        self.espeakLimit = espeakLimit
    }

    // MARK: - State

    /// Our agent is set up (plist written and venv built).
    var isInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: paths.plist.path) && fm.fileExists(atPath: paths.python.path)
    }

    /// The hand-made `~/tts` agent is still in place (Install will migrate it).
    var legacyInstalled: Bool {
        Self.legacyLabels.contains { FileManager.default.fileExists(atPath: paths.legacyPlist($0).path) }
    }

    /// The bundled server differs from the installed copy (Update applies it).
    var updateAvailable: Bool {
        guard isInstalled, let bundled = paths.bundled else { return false }
        return Self.serverFiles.contains { name in
            Self.digest(bundled.appendingPathComponent(name)) != Self.digest(paths.installDir.appendingPathComponent(name))
        }
    }

    var isWorking: Bool { if case .working = phase { return true }; return false }
    /// Install's long steps can be cancelled; the switch-over cannot.
    var canCancel: Bool { isWorking && cancellable }

    /// Ask `/health` now and publish the answer.
    func refreshHealth() async {
        health = await probe()
    }

    // MARK: - Actions

    func install() { start { try await self.performInstall() } }
    func update() { start { try await self.performUpdate() } }
    func restart() { start { try await self.performRestart() } }
    func uninstall() { start { try await self.performUninstall() } }

    /// Stop an install that is still preparing. The running server is untouched.
    func cancel() {
        guard canCancel else { return }
        Log.log("kokoro service: cancel requested")
        job?.cancel()
    }

    /// Wait for the current action, if any (tests).
    func waitForJob() async { await job?.value }

    private func start(_ work: @escaping @MainActor () async throws -> Void) {
        guard !isWorking else { return }
        cancellable = false
        job = Task { @MainActor in
            do {
                try await work()
                self.phase = .idle
            } catch is CancellationError {
                Log.log("kokoro service: cancelled")
                self.phase = .failed("install cancelled")
            } catch {
                Log.log("kokoro service: failed — \(error.localizedDescription)")
                self.phase = .failed(error.localizedDescription)
            }
            self.cancellable = false
            await self.refreshHealth()
        }
    }

    // MARK: - Install

    private func performInstall() async throws {
        cancellable = true
        phase = .working("checking requirements")
        guard let bundled = paths.bundled else { throw Failure.noBundledServer }
        guard let uv = locateUV() else { throw Failure.uvMissing }
        let espeakLength = paths.espeakData.path.utf8.count
        guard espeakLength < espeakLimit else { throw Failure.pathTooLong(espeakLength) }
        // Our plist alone (even with no venv) means our agent may be loaded and
        // holding the port, so it counts as "ours" for the port check and the
        // switch-over.
        let ours = FileManager.default.fileExists(atPath: paths.plist.path), legacy = legacyInstalled
        if !ours, !legacy, let holder = try await portHolder() {
            throw Failure.portInUse(holder)
        }
        trimLog()
        Log.log("kokoro service: install — uv at \(uv), migrating legacy agents: \(legacy)")
        try appendToLog("=== install \(Date()) ===\n")

        phase = .working("copying server files")
        try copyServerFiles(from: bundled)

        try Task.checkCancellation()
        if !FileManager.default.fileExists(atPath: paths.python.path) {
            phase = .working("creating Python environment")
            try await step("creating the Python environment", uv, ["venv", "--clear", "--python", "3.13", paths.venv.path])
        }
        try Task.checkCancellation()
        phase = .working("installing packages (~900 MB, several minutes)")
        try await installPackages(uv: uv)
        try Task.checkCancellation()

        // From here on the running server is replaced, so no more cancelling.
        cancellable = false
        try await waitUntilIdle()
        phase = .working("switching over")
        let moved = legacy ? try await retireLegacyAgents() : []
        do {
            if ours { _ = try? await launchctl(["bootout", "\(Self.domain)/\(Self.label)"]) }
            try await waitForPortFree()
            try writePlist()
            try await step("starting the launchd agent", "/bin/launchctl",
                           ["bootstrap", Self.domain, paths.plist.path])
            phase = .working("starting (the first start downloads the model)")
            try await waitForHealth(timeout: startTimeout)
        } catch {
            if !moved.isEmpty { await restoreLegacyAgents(moved) }
            throw error
        }
        Log.log("kokoro service: installed and running")
    }

    private func installPackages(uv: String) async throws {
        try await step("installing packages", uv,
                       ["pip", "install", "--python", paths.python.path,
                        "-r", paths.installDir.appendingPathComponent("requirements.txt").path])
    }

    private func copyServerFiles(from bundled: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.installDir, withIntermediateDirectories: true)
        for name in Self.serverFiles {
            let target = paths.installDir.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: bundled.appendingPathComponent(name), to: target)
        }
        // The block-list is runtime state the test page edits: seed it, never
        // overwrite it.
        let blocklist = paths.installDir.appendingPathComponent(Self.blocklistFile)
        let shipped = bundled.appendingPathComponent(Self.blocklistFile)
        if !fm.fileExists(atPath: blocklist.path), fm.fileExists(atPath: shipped.path) {
            try fm.copyItem(at: shipped, to: blocklist)
        }
    }

    /// Boot out the `~/tts` agents and move their plists into `legacyBackup`.
    /// Returns the labels moved, for `restoreLegacyAgents`.
    private func retireLegacyAgents() async throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.legacyBackup, withIntermediateDirectories: true)
        var moved: [String] = []
        for label in Self.legacyLabels {
            let plist = paths.legacyPlist(label)
            guard fm.fileExists(atPath: plist.path) else { continue }
            _ = try? await launchctl(["bootout", "\(Self.domain)/\(label)"])
            let backup = paths.legacyBackup.appendingPathComponent(plist.lastPathComponent)
            if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
            try fm.moveItem(at: plist, to: backup)
            moved.append(label)
            Log.log("kokoro service: retired legacy agent \(label) (plist kept in \(paths.legacyBackup.path))")
        }
        return moved
    }

    /// Undo `retireLegacyAgents` after a failed switch-over, so the Mac is left
    /// speaking through the old server rather than through nothing.
    private func restoreLegacyAgents(_ labels: [String]) async {
        Log.log("kokoro service: switch-over failed — restoring the legacy agents")
        _ = try? await launchctl(["bootout", "\(Self.domain)/\(Self.label)"])
        try? FileManager.default.removeItem(at: paths.plist)
        for label in labels {
            let plist = paths.legacyPlist(label)
            let backup = paths.legacyBackup.appendingPathComponent(plist.lastPathComponent)
            do {
                try FileManager.default.moveItem(at: backup, to: plist)
                _ = try await launchctl(["bootstrap", Self.domain, plist.path])
            } catch {
                Log.log("kokoro service: could not restore \(label): \(error)")
            }
        }
    }

    // MARK: - Update / restart / uninstall

    private func performUpdate() async throws {
        guard let bundled = paths.bundled else { throw Failure.noBundledServer }
        let requirementsChanged = Self.digest(bundled.appendingPathComponent("requirements.txt"))
            != Self.digest(paths.installDir.appendingPathComponent("requirements.txt"))
        trimLog()
        try appendToLog("=== update \(Date()) ===\n")
        phase = .working("copying server files")
        try copyServerFiles(from: bundled)
        if requirementsChanged {
            guard let uv = locateUV() else { throw Failure.uvMissing }
            phase = .working("installing packages")
            try await installPackages(uv: uv)
        }
        try await performRestart()
    }

    private func performRestart() async throws {
        try await waitUntilIdle()
        await refreshHealth()
        Log.log("kokoro service: restarting — memory before restart: \(health?.memoryMB.map { "\($0) MB" } ?? "unknown")")
        trimLog()
        phase = .working("restarting")
        try await step("restarting the server", "/bin/launchctl", ["kickstart", "-k", "\(Self.domain)/\(Self.label)"])
        try await waitForHealth(timeout: .seconds(120))
    }

    private func performUninstall() async throws {
        try await waitUntilIdle()
        phase = .working("uninstalling")
        _ = try? await launchctl(["bootout", "\(Self.domain)/\(Self.label)"])
        let fm = FileManager.default
        if fm.fileExists(atPath: paths.plist.path) { try fm.removeItem(at: paths.plist) }
        if fm.fileExists(atPath: paths.installDir.path) { try fm.removeItem(at: paths.installDir) }
        Log.log("kokoro service: uninstalled (model cache in ~/.cache/huggingface left in place)")
    }

    // MARK: - Steps

    private static var domain: String { "gui/\(getuid())" }

    private func launchctl(_ arguments: [String]) async throws -> CommandResult {
        try await runner.run("/bin/launchctl", arguments, logTo: nil)
    }

    /// Run one command, teeing its output to the Kokoro log; a non-zero exit
    /// becomes `Failure.command` carrying the tail of its output.
    private func step(_ name: String, _ executable: String, _ arguments: [String]) async throws {
        Log.log("kokoro service: \(name) — \(executable) \(arguments.joined(separator: " "))")
        let result = try await runner.run(executable, arguments, logTo: paths.log)
        try Task.checkCancellation()
        guard result.succeeded else {
            let tail = result.output.split(separator: "\n").suffix(3).joined(separator: " / ")
            throw Failure.command(name, tail.isEmpty ? "exit \(result.status)" : tail)
        }
    }

    private func waitUntilIdle() async throws {
        guard isBusy() else { return }
        phase = .working("waiting for speech to finish")
        Log.log("kokoro service: waiting until nothing is being dictated or spoken")
        while isBusy() { try await Task.sleep(for: pollInterval) }
    }

    private func waitForHealth(timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let answer = await probe() { health = answer; return }
            try await Task.sleep(for: pollInterval)
        }
        throw Failure.didNotStart
    }

    /// Who is listening on the Kokoro port, or nil when nobody is.
    private func portHolder() async throws -> String? {
        let result = try await runner.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(Self.port)", "-sTCP:LISTEN", "-Fpc"], logTo: nil)
        guard result.succeeded else { return nil }   // lsof exits 1 when nothing matches
        let lines = result.output.split(separator: "\n")
        let pid = lines.first { $0.hasPrefix("p") }.map { String($0.dropFirst()) } ?? "?"
        let command = lines.first { $0.hasPrefix("c") }.map { String($0.dropFirst()) } ?? "a process"
        return "\(command) (pid \(pid))"
    }

    private func waitForPortFree() async throws {
        for _ in 0..<20 {
            guard let holder = try await portHolder() else { return }
            Log.log("kokoro service: waiting for port \(Self.port) (held by \(holder))")
            try await Task.sleep(for: pollInterval)
        }
        if let holder = try await portHolder() { throw Failure.portInUse(holder) }
    }

    private func writePlist() throws {
        try FileManager.default.createDirectory(at: paths.launchAgents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.plistData(paths: paths).write(to: paths.plist, options: .atomic)
    }

    /// The launchd agent: always running, respawned within ~10 s if it dies.
    static func plistData(paths: Paths) throws -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [paths.python.path, "-W", "ignore", paths.server.path],
            "WorkingDirectory": paths.installDir.path,
            "EnvironmentVariables": ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "ThrottleInterval": 10,
            "StandardOutPath": paths.log.path,
            "StandardErrorPath": paths.log.path,
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private func appendToLog(_ text: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: paths.log.path) { fm.createFile(atPath: paths.log.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: paths.log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// Keep the log bounded without a rotation scheme: past the limit, start over.
    private func trimLog() {
        let size = (try? FileManager.default.attributesOfItem(atPath: paths.log.path)[.size] as? Int) ?? 0
        guard size > Self.logLimitBytes, let handle = try? FileHandle(forWritingTo: paths.log) else { return }
        try? handle.truncate(atOffset: 0)
        try? handle.close()
        Log.log("kokoro service: truncated \(paths.log.lastPathComponent) at \(size / 1024 / 1024) MB")
    }

    // MARK: - Helpers

    /// `uv`, looked for where its installers put it. A GUI app's PATH holds
    /// none of these, so they are checked directly.
    static func findUV(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let candidates = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv",
                          home.appendingPathComponent(".local/bin/uv").path,
                          home.appendingPathComponent(".cargo/bin/uv").path]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func digest(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// One quick `/health` round trip to the local server.
    nonisolated static func probeHealth() async -> Health? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["status"] as? String == "ok" else { return nil }
        return Health(memoryMB: object["memory_mb"] as? Int, pid: object["pid"] as? Int)
    }
}
