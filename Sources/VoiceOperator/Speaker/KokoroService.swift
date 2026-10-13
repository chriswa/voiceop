import CryptoKit
import Foundation

/// Installs, updates, restarts and uninstalls the local Kokoro server — the
/// default TTS backend — as a per-user launchd agent. See `kokoro/CLAUDE.md`
/// for the server itself.
///
/// Everything it needs ships with or is fetched by the app; nothing outside it
/// is assumed. The server's source is inside the bundle
/// (`Contents/Resources/kokoro`, copied there by `make-app.sh` /
/// `make-release.sh`). Install copies it to Application Support, uses `uv` (the
/// Mac's own if it has one, otherwise a pinned copy downloaded into the install
/// directory) to fetch a private Python 3.13 and build a venv from the pinned
/// `requirements.txt`, and points one launchd agent (`RunAtLoad` + `KeepAlive`)
/// at it. There is no scheduled restart: the server reports its memory instead
/// (`/health` `memory_mb`, shown in the menu).
///
/// It runs on its own: `autoStart` installs at launch when speech is set to the
/// local Kokoro and nothing is installed (unless the user uninstalled it), and
/// applies an update when the app ships a different server. The menu's items do
/// the same on demand.
///
/// **Nothing here may cut off speech.** Every step that stops a running server —
/// Restart, Update, Uninstall, a reinstall — first waits until `isBusy`
/// (dictating or speaking) is false, the same rule as `RestartCoordinator`.
@MainActor
final class KokoroService {
    nonisolated static let label = "com.chriswa.voiceoperator.kokoro"
    nonisolated static let port = 56841
    /// The files that make up an install, as shipped in the bundle.
    static let serverFiles = ["kokoro_server.py", "requirements.txt"]
    static let blocklistFile = "blocked_voices.json"
    /// espeak-ng (Kokoro's fallback G2P) silently falls back to a compiled-in
    /// data path — and the server dies at load — when its data path is this
    /// long or longer. Checked before installing.
    nonisolated static let espeakPathLimit = 160
    /// Above this the log is truncated before the next install/update/restart,
    /// so the per-request `mem=` lines can't grow it forever.
    static let logLimitBytes = 5 * 1024 * 1024
    /// The `uv` fetched when the Mac has none: a pinned release, checked
    /// against its published SHA-256 before it is unpacked.
    nonisolated static let uvURL = URL(string:
        "https://github.com/astral-sh/uv/releases/download/0.12.9/uv-aarch64-apple-darwin.tar.gz")!
    nonisolated static let uvSHA256 = "301f72afaf54060f92da7016cb0115bd077f43a9c8e39c1d8170a0bac80fd398"
    /// Set when the user uninstalls, so the next launch doesn't put it back.
    static let declinedKey = "KokoroAutoInstallDeclined"

    struct Paths: Sendable {
        /// `~/Library/Application Support/VoiceOperator/kokoro`
        var installDir: URL
        /// `~/Library/LaunchAgents`
        var launchAgents: URL
        /// `~/Library/Logs/VoiceOperator-kokoro.log`
        var log: URL
        /// The server files inside the running app, nil when the build has none.
        var bundled: URL?

        var venv: URL { installDir.appendingPathComponent("venv", isDirectory: true) }
        var python: URL { venv.appendingPathComponent("bin/python") }
        /// uv-managed CPython the venv is built on. Inside the install, so an
        /// Uninstall takes it too and nothing else can upgrade it away.
        var pythonInstalls: URL { installDir.appendingPathComponent("python", isDirectory: true) }
        /// Where a downloaded `uv` lives (only when the Mac has none of its own).
        var privateUV: URL { installDir.appendingPathComponent("uv/uv") }
        var server: URL { installDir.appendingPathComponent("kokoro_server.py") }
        var plist: URL { launchAgents.appendingPathComponent("\(KokoroService.label).plist") }
        var espeakData: URL {
            venv.appendingPathComponent("lib/python3.13/site-packages/espeakng_loader/espeak-ng-data")
        }

        static var standard: Paths {
            let fm = FileManager.default
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VoiceOperator", isDirectory: true)
            let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            let bundled = Bundle.main.resourceURL?.appendingPathComponent("kokoro", isDirectory: true)
            return Paths(installDir: support.appendingPathComponent("kokoro", isDirectory: true),
                         launchAgents: library.appendingPathComponent("LaunchAgents", isDirectory: true),
                         log: library.appendingPathComponent("Logs/VoiceOperator-kokoro.log"),
                         bundled: bundled.flatMap {
                             fm.fileExists(atPath: $0.appendingPathComponent("kokoro_server.py").path) ? $0 : nil
                         })
        }
    }

    enum Action: Equatable, Sendable { case install, update, restart, uninstall }

    /// What the service is doing, for the menu's status line.
    enum Phase: Equatable, Sendable {
        case idle
        /// A step is running; the text names it ("installing packages").
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
        case uvDownload(String)
        case pathTooLong(Int)
        case portInUse(String)
        case command(String, String)
        case didNotStart

        var errorDescription: String? {
            switch self {
            case .noBundledServer: return "this build doesn't include the Kokoro server files"
            case .uvDownload(let why): return "couldn't download uv: \(why)"
            case .pathTooLong(let n): return "install path too long for espeak-ng (\(n) characters; it needs under \(KokoroService.espeakPathLimit))"
            case .portInUse(let who): return "port \(KokoroService.port) is in use by \(who)"
            case .command(let step, let detail): return "\(step) failed: \(detail)"
            case .didNotStart: return "the server did not come up"
            }
        }
    }

    private(set) var phase: Phase = .idle { didSet { onChange?() } }
    /// The action running now, or the last one to finish.
    private(set) var action: Action?
    /// Install's progress, 0…1, for the setup window. nil outside an install.
    private(set) var progress: Double?
    /// The last `/health` answer from port 56841; nil when it didn't answer.
    private(set) var health: Health? { didSet { if health != oldValue { onChange?() } } }
    /// The menu and the setup window re-read their state whenever this fires.
    var onChange: (() -> Void)?

    let paths: Paths
    private let runner: CommandRunner
    private let isBusy: () -> Bool
    private let probe: @Sendable () async -> Health?
    private let systemUV: () -> String?
    private let fetchUV: @Sendable (URL) async throws -> Void
    private let defaults: UserDefaults
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
         systemUV: @escaping () -> String? = { KokoroService.findUV() },
         fetchUV: (@Sendable (URL) async throws -> Void)? = nil,
         defaults: UserDefaults = .standard,
         pollInterval: Duration = .seconds(1),
         startTimeout: Duration = .seconds(600),
         espeakLimit: Int = KokoroService.espeakPathLimit) {
        self.paths = paths
        self.runner = runner
        self.isBusy = isBusy
        self.probe = probe
        self.systemUV = systemUV
        self.fetchUV = fetchUV ?? { [runner] destination in
            try await KokoroService.downloadUV(to: destination, runner: runner)
        }
        self.defaults = defaults
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

    /// At launch: install when none is installed (unless the user uninstalled
    /// it), or apply a newer bundled server. No prompt — the setup window shows
    /// what is happening.
    func autoStart() {
        guard paths.bundled != nil, !isWorking else { return }
        if !isInstalled {
            guard !defaults.bool(forKey: Self.declinedKey) else {
                Log.log("kokoro service: not installed, and the user uninstalled it — not reinstalling")
                return
            }
            Log.log("kokoro service: not installed — installing automatically")
            install()
        } else if updateAvailable {
            Log.log("kokoro service: the app ships a different server — updating automatically")
            update()
        }
    }

    func install() {
        defaults.removeObject(forKey: Self.declinedKey)
        start(.install) { try await self.performInstall() }
    }
    func update() { start(.update) { try await self.performUpdate() } }
    func restart() { start(.restart) { try await self.performRestart() } }
    func uninstall() {
        defaults.set(true, forKey: Self.declinedKey)
        start(.uninstall) { try await self.performUninstall() }
    }

    /// Stop an install that is still preparing. Nothing running is touched.
    func cancel() {
        guard canCancel else { return }
        Log.log("kokoro service: cancel requested")
        job?.cancel()
    }

    /// Wait for the current action, if any (tests).
    func waitForJob() async { await job?.value }

    private func start(_ action: Action, _ work: @escaping @MainActor () async throws -> Void) {
        guard !isWorking else { return }
        cancellable = false
        self.action = action
        progress = action == .install ? 0 : nil
        job = Task { @MainActor in
            do {
                try await work()
                if self.progress != nil { self.progress = 1 }
                self.phase = .idle
            } catch is CancellationError {
                Log.log("kokoro service: cancelled")
                self.phase = .failed("install cancelled")
            } catch {
                Log.log("kokoro service: \(action) failed — \(error.localizedDescription)")
                self.phase = .failed(error.localizedDescription)
            }
            self.cancellable = false
            await self.refreshHealth()
        }
    }

    private func report(_ step: String, progress value: Double? = nil) {
        if let value { progress = value }
        phase = .working(step)
    }

    // MARK: - Install

    private func performInstall() async throws {
        cancellable = true
        report("checking", progress: 0.02)
        guard let bundled = paths.bundled else { throw Failure.noBundledServer }
        let espeakLength = paths.espeakData.path.utf8.count
        guard espeakLength < espeakLimit else { throw Failure.pathTooLong(espeakLength) }
        // Our plist alone (even with no venv) means our agent may be loaded and
        // holding the port; anyone else on it is a conflict to report, not kill.
        let ours = FileManager.default.fileExists(atPath: paths.plist.path)
        if !ours, let holder = try await portHolder() { throw Failure.portInUse(holder) }
        trimLog()
        try appendToLog("=== install \(Date()) ===\n")

        let uv = try await locateUV()
        Log.log("kokoro service: install — uv at \(uv)")

        report("copying server files", progress: 0.1)
        try copyServerFiles(from: bundled)

        try Task.checkCancellation()
        if !FileManager.default.fileExists(atPath: paths.python.path) {
            report("downloading Python and creating its environment", progress: 0.15)
            try await step("creating the Python environment", uv,
                           ["venv", "--clear", "--managed-python", "--python", "3.13", paths.venv.path],
                           environment: ["UV_PYTHON_INSTALL_DIR": paths.pythonInstalls.path])
        }
        try Task.checkCancellation()
        report("installing packages (about 900 MB)", progress: 0.25)
        try await installPackages(uv: uv)
        try Task.checkCancellation()

        // From here on a running server may be replaced, so no more cancelling.
        cancellable = false
        if ours {
            try await waitUntilIdle()
            _ = try? await launchctl(["bootout", "\(Self.domain)/\(Self.label)"])
        }
        report("starting the server", progress: 0.85)
        try await waitForPortFree()
        try writePlist()
        try await step("starting the launchd agent", "/bin/launchctl",
                       ["bootstrap", Self.domain, paths.plist.path])
        report("starting (the first start downloads the voice model)", progress: 0.9)
        try await waitForHealth(timeout: startTimeout)
        Log.log("kokoro service: installed and running")
    }

    /// The Mac's own `uv`, else the one a previous install downloaded, else
    /// download the pinned release now.
    private func locateUV() async throws -> String {
        if let uv = systemUV() { return uv }
        if FileManager.default.isExecutableFile(atPath: paths.privateUV.path) { return paths.privateUV.path }
        report("downloading uv", progress: 0.05)
        Log.log("kokoro service: no uv on this Mac — downloading \(Self.uvURL.absoluteString)")
        try await fetchUV(paths.privateUV.deletingLastPathComponent())
        guard FileManager.default.isExecutableFile(atPath: paths.privateUV.path) else {
            throw Failure.uvDownload("no uv binary in the download")
        }
        return paths.privateUV.path
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

    // MARK: - Update / restart / uninstall

    private func performUpdate() async throws {
        guard let bundled = paths.bundled else { throw Failure.noBundledServer }
        let requirementsChanged = Self.digest(bundled.appendingPathComponent("requirements.txt"))
            != Self.digest(paths.installDir.appendingPathComponent("requirements.txt"))
        trimLog()
        try appendToLog("=== update \(Date()) ===\n")
        report("copying server files")
        try copyServerFiles(from: bundled)
        if requirementsChanged {
            let uv = try await locateUV()
            report("installing packages")
            try await installPackages(uv: uv)
        }
        try await performRestart()
    }

    private func performRestart() async throws {
        try await waitUntilIdle()
        await refreshHealth()
        Log.log("kokoro service: restarting — memory before restart: \(health?.memoryMB.map { "\($0) MB" } ?? "unknown")")
        trimLog()
        report("restarting")
        try await step("restarting the server", "/bin/launchctl", ["kickstart", "-k", "\(Self.domain)/\(Self.label)"])
        try await waitForHealth(timeout: .seconds(120))
    }

    private func performUninstall() async throws {
        try await waitUntilIdle()
        report("uninstalling")
        _ = try? await launchctl(["bootout", "\(Self.domain)/\(Self.label)"])
        let fm = FileManager.default
        if fm.fileExists(atPath: paths.plist.path) { try fm.removeItem(at: paths.plist) }
        if fm.fileExists(atPath: paths.installDir.path) { try fm.removeItem(at: paths.installDir) }
        Log.log("kokoro service: uninstalled (model cache in ~/.cache/huggingface left in place)")
    }

    // MARK: - Steps

    private static var domain: String { "gui/\(getuid())" }

    private func launchctl(_ arguments: [String]) async throws -> CommandResult {
        try await runner.run("/bin/launchctl", arguments)
    }

    /// Run one command, teeing its output to the Kokoro log; a non-zero exit
    /// becomes `Failure.command` carrying the tail of its output.
    private func step(_ name: String, _ executable: String, _ arguments: [String],
                      environment: [String: String] = [:]) async throws {
        Log.log("kokoro service: \(name) — \(executable) \(arguments.joined(separator: " "))")
        let result = try await runner.run(executable, arguments, environment: environment, logTo: paths.log)
        try Task.checkCancellation()
        guard result.succeeded else {
            let tail = result.output.split(separator: "\n").suffix(3).joined(separator: " / ")
            throw Failure.command(name, tail.isEmpty ? "exit \(result.status)" : tail)
        }
    }

    private func waitUntilIdle() async throws {
        guard isBusy() else { return }
        report("waiting for speech to finish")
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
        let result = try await runner.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(Self.port)", "-sTCP:LISTEN", "-Fpc"])
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

    /// The last non-empty line of the log, for the setup window's detail line.
    func lastLogLine() -> String? {
        guard let handle = try? FileHandle(forReadingFrom: paths.log) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 4096 ? size - 4096 : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)   // "\r\n" is one Character
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Helpers

    /// The Mac's own `uv`, looked for where its installers put it. A GUI app's
    /// PATH holds none of these, so they are checked directly.
    static func findUV(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let candidates = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv",
                          home.appendingPathComponent(".local/bin/uv").path,
                          home.appendingPathComponent(".cargo/bin/uv").path]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Download the pinned `uv` release, check its SHA-256, and unpack `uv` into
    /// `directory`. Touches nothing outside it: no shell profile, no PATH.
    nonisolated static func downloadUV(to directory: URL, runner: CommandRunner) async throws {
        let (archive, response) = try await URLSession.shared.download(from: uvURL)
        defer { try? FileManager.default.removeItem(at: archive) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure.uvDownload("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard digest(archive) == uvSHA256 else { throw Failure.uvDownload("checksum mismatch") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try await runner.run("/usr/bin/tar",
                                          ["-xzf", archive.path, "-C", directory.path, "--strip-components", "1"])
        guard result.succeeded else { throw Failure.uvDownload("couldn't unpack it: \(result.output)") }
    }

    nonisolated static func digest(_ url: URL) -> String? {
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
