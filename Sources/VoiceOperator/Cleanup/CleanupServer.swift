import CryptoKit
import Foundation

/// Runs the local llama.cpp server that `DictationCleaner` talks to, as a
/// per-user launchd agent serving Fluid-1 Mini on a loopback port. See DESIGN.md,
/// "Dictation clean-up".
///
/// Both downloads are pinned and checked against their SHA-256 before use: a
/// llama.cpp release build (`llama-server` and its dylibs) and the model file
/// from Hugging Face. They live in `Application Support/VoiceOperator/cleanup`;
/// anything else found there (an older pinned build or model) is deleted when
/// the server is set up, so an upgrade never leaves the previous download behind.
///
/// The agent only exists while "Clean Up Transcripts" is on. Turning it off
/// unloads it, which frees the model's memory (about 2 GB) but keeps the files;
/// "Delete Clean-Up Model" removes those too.
///
/// Stopping the server mid-dictation would only cost that dictation its
/// clean-up (the raw text is pasted), but every step that stops it still waits
/// until nothing is being dictated or spoken, like `KokoroService`.
@MainActor
final class CleanupServer {
    nonisolated static let label = "com.chriswa.voiceoperator.cleanup"
    nonisolated static let port = 56842

    struct Download: Sendable {
        let url: URL
        let sha256: String
        let bytes: Int64
    }

    /// llama.cpp b11669 (the v0.7.0 release), Apple Silicon build.
    nonisolated static let llamaBuild = "llama-b11669"
    nonisolated static let llama = Download(
        url: URL(string: "https://github.com/ggml-org/llama.cpp/releases/download/b11669/llama-b11669-bin-macos-arm64.tar.gz")!,
        sha256: "dbed55493d72bc1ba2babc8770d669c2289b5bc4ee9fb2a4dfc158d45b7d13fd",
        bytes: 12_191_582)
    /// Fluid-1 Mini, Q6_K, at a fixed revision of `altic-dev/fluid-1-mini`.
    /// Licensed for personal, non-commercial use only.
    nonisolated static let modelFile = "fluid-1-mini-q6_k.gguf"
    nonisolated static let model = Download(
        url: URL(string: "https://huggingface.co/altic-dev/fluid-1-mini/resolve/af4b6e10a3631c346f77ca8c1018b59743433aa5/fluid-1-mini-q6_k.gguf")!,
        sha256: "1c83ac7acaed9efbdd278a0cc56f15ffb59f85cf7684da817e8357cdcc915147",
        bytes: 1_606_323_744)

    struct Paths: Sendable {
        /// `~/Library/Application Support/VoiceOperator/cleanup`
        var installDir: URL
        /// `~/Library/LaunchAgents`
        var launchAgents: URL
        /// `~/Library/Logs/VoiceOperator-cleanup.log`
        var log: URL

        var llamaDir: URL { installDir.appendingPathComponent(CleanupServer.llamaBuild, isDirectory: true) }
        var server: URL { llamaDir.appendingPathComponent("llama-server") }
        var model: URL { installDir.appendingPathComponent(CleanupServer.modelFile) }
        var plist: URL { launchAgents.appendingPathComponent("\(CleanupServer.label).plist") }

        static var standard: Paths {
            let fm = FileManager.default
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VoiceOperator", isDirectory: true)
            let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            return Paths(installDir: support.appendingPathComponent("cleanup", isDirectory: true),
                         launchAgents: library.appendingPathComponent("LaunchAgents", isDirectory: true),
                         log: library.appendingPathComponent("Logs/VoiceOperator-cleanup.log"))
        }
    }

    /// What the server is doing, for the Transcription submenu's status line.
    enum Phase: Equatable, Sendable {
        case idle
        /// A step is running; the text names it ("downloading the model, 40%").
        case working(String)
        /// The last action failed; the text says why. Cleared by the next action.
        case failed(String)
    }

    enum Failure: LocalizedError, Equatable {
        case download(String, String)
        case portInUse(String)
        case command(String, String)
        case didNotStart

        var errorDescription: String? {
            switch self {
            case .download(let what, let why): return "couldn't download \(what): \(why)"
            case .portInUse(let who): return "port \(CleanupServer.port) is in use by \(who)"
            case .command(let step, let detail): return "\(step) failed: \(detail)"
            case .didNotStart: return "the server did not come up"
            }
        }
    }

    private(set) var phase: Phase = .idle { didSet { if phase != oldValue { onChange?() } } }
    /// Whether `/health` answered "ok" the last time it was asked.
    private(set) var healthy = false { didSet { if healthy != oldValue { onChange?() } } }
    var onChange: (() -> Void)?

    let paths: Paths
    private let runner: CommandRunner
    private let isBusy: () -> Bool
    private let probe: @Sendable () async -> Bool
    private let fetch: @Sendable (Download, URL, @escaping @Sendable (Double) -> Void) async throws -> Void
    private let pollInterval: Duration
    /// How long the model may take to load once the agent starts.
    private let startTimeout: Duration
    private var job: Task<Void, Never>?

    init(paths: Paths = .standard,
         runner: CommandRunner = ProcessRunner(),
         isBusy: @escaping () -> Bool,
         probe: @escaping @Sendable () async -> Bool = { await CleanupServer.probeHealth() },
         fetch: (@Sendable (Download, URL, @escaping @Sendable (Double) -> Void) async throws -> Void)? = nil,
         pollInterval: Duration = .seconds(1),
         startTimeout: Duration = .seconds(120)) {
        self.paths = paths
        self.runner = runner
        self.isBusy = isBusy
        self.probe = probe
        self.fetch = fetch ?? { download, destination, progress in
            try await FileDownloader.fetch(download.url, to: destination, sha256: download.sha256, progress: progress)
        }
        self.pollInterval = pollInterval
        self.startTimeout = startTimeout
    }

    // MARK: - State

    /// Both downloads are in place.
    var isDownloaded: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: paths.server.path) && fm.fileExists(atPath: paths.model.path)
    }

    /// Our agent is set up to run (it may still be loading the model).
    var isEnabled: Bool { FileManager.default.fileExists(atPath: paths.plist.path) }

    var isWorking: Bool { if case .working = phase { return true }; return false }

    func refreshHealth() async { healthy = await probe() }

    /// Wait for the current action, if any (tests).
    func waitForJob() async { await job?.value }

    // MARK: - Actions

    /// Download what is missing, load the agent unless it is already running
    /// this build's pinned server and model, and wait for the model. Cheap when
    /// everything is in place, so it is also what launch calls.
    func enable() { start("enable") { try await self.performEnable() } }

    /// Unload the agent and free the model's memory. The files stay.
    func disable() { start("disable") { try await self.performDisable() } }

    /// Unload the agent and delete everything it downloaded.
    func delete() {
        start("delete") {
            try await self.performDisable()
            if FileManager.default.fileExists(atPath: self.paths.installDir.path) {
                try FileManager.default.removeItem(at: self.paths.installDir)
            }
            Log.log("cleanup server: deleted \(self.paths.installDir.path)")
        }
    }

    private func start(_ name: String, _ work: @escaping @MainActor () async throws -> Void) {
        let previous = job
        job = Task { @MainActor in
            await previous?.value
            do {
                try await work()
                self.phase = .idle
            } catch {
                Log.log("cleanup server: \(name) failed — \(error.localizedDescription)")
                self.phase = .failed(error.localizedDescription)
            }
            await self.refreshHealth()
        }
    }

    private func performEnable() async throws {
        phase = .working("checking")
        try FileManager.default.createDirectory(at: paths.installDir, withIntermediateDirectories: true)
        try removeOtherDownloads()
        if !FileManager.default.isExecutableFile(atPath: paths.server.path) {
            phase = .working("downloading llama.cpp")
            try await downloadLlama()
        }
        if !FileManager.default.fileExists(atPath: paths.model.path) {
            try await downloadModel()
        }
        let current = (try? Data(contentsOf: paths.plist)) == (try? Self.plistData(paths: paths))
        let running = current ? await isLoaded() : false
        if !running {
            try await waitUntilIdle()
            try await unload()
            if let holder = try await portHolder() { throw Failure.portInUse(holder) }
            phase = .working("starting")
            try writePlist()
            try await step("starting the launchd agent", "/bin/launchctl", ["bootstrap", Self.domain, paths.plist.path])
        }
        phase = .working("loading the model")
        try await waitForHealth(timeout: startTimeout)
        Log.log("cleanup server: running on port \(Self.port)")
    }

    private func performDisable() async throws {
        try await waitUntilIdle()
        phase = .working("stopping")
        try await unload()
        if FileManager.default.fileExists(atPath: paths.plist.path) { try FileManager.default.removeItem(at: paths.plist) }
        Log.log("cleanup server: stopped")
    }

    // MARK: - Downloads

    private func downloadLlama() async throws {
        let archive = paths.installDir.appendingPathComponent("\(Self.llamaBuild).tar.gz.partial")
        defer { try? FileManager.default.removeItem(at: archive) }
        do { try await fetch(Self.llama, archive) { _ in } }
        catch { throw Failure.download("llama.cpp", error.localizedDescription) }
        try await step("unpacking llama.cpp", "/usr/bin/tar", ["-xzf", archive.path, "-C", paths.installDir.path])
        guard FileManager.default.isExecutableFile(atPath: paths.server.path) else {
            throw Failure.download("llama.cpp", "no llama-server in the archive")
        }
    }

    private func downloadModel() async throws {
        let partial = paths.model.appendingPathExtension("partial")
        defer { try? FileManager.default.removeItem(at: partial) }
        let size = ByteCountFormatter.string(fromByteCount: Self.model.bytes, countStyle: .file)
        phase = .working("downloading the model (\(size))")
        Log.log("cleanup server: downloading \(Self.model.url.absoluteString)")
        do {
            try await fetch(Self.model, partial) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, self.isWorking else { return }
                    self.phase = .working("downloading the model, \(Int(fraction * 100))% of \(size)")
                }
            }
        } catch { throw Failure.download("the model", error.localizedDescription) }
        try FileManager.default.moveItem(at: partial, to: paths.model)
    }

    /// Delete any other build or model in the install directory: the leftovers
    /// of a previous pin, or a download that was interrupted.
    private func removeOtherDownloads() throws {
        let fm = FileManager.default
        let keep: Set = [paths.llamaDir.lastPathComponent, paths.model.lastPathComponent]
        for name in try fm.contentsOfDirectory(atPath: paths.installDir.path) where !keep.contains(name) {
            try fm.removeItem(at: paths.installDir.appendingPathComponent(name))
            Log.log("cleanup server: removed \(name), which this build no longer uses")
        }
    }

    // MARK: - Steps

    private static var domain: String { "gui/\(getuid())" }

    private func launchctl(_ arguments: [String]) async throws -> CommandResult {
        try await runner.run("/bin/launchctl", arguments)
    }

    private func step(_ name: String, _ executable: String, _ arguments: [String]) async throws {
        Log.log("cleanup server: \(name) — \(executable) \(arguments.joined(separator: " "))")
        let result = try await runner.run(executable, arguments)
        guard result.succeeded else {
            let tail = result.output.split(separator: "\n").suffix(3).joined(separator: " / ")
            throw Failure.command(name, tail.isEmpty ? "exit \(result.status)" : tail)
        }
    }

    private func isLoaded() async -> Bool {
        (try? await launchctl(["print", "\(Self.domain)/\(Self.label)"]))?.succeeded ?? false
    }

    /// Unload the agent and wait until launchd has really let go of it and its
    /// port: `bootout` returns before the old job is gone, and a `bootstrap`
    /// issued in that window fails with an I/O error.
    private func unload() async throws {
        guard await isLoaded() else { return }
        _ = try? await launchctl(["bootout", "\(Self.domain)/\(Self.label)"])
        for _ in 0..<50 {
            if !(await isLoaded()), try await portHolder() == nil { return }
            try await Task.sleep(for: pollInterval)
        }
        throw Failure.command("stopping the old server", "launchd still has it")
    }

    private func waitUntilIdle() async throws {
        guard isBusy() else { return }
        phase = .working("waiting for dictation and speech to finish")
        while isBusy() { try await Task.sleep(for: pollInterval) }
    }

    private func waitForHealth(timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await probe() { healthy = true; return }
            try await Task.sleep(for: pollInterval)
        }
        throw Failure.didNotStart
    }

    /// Who is listening on the port, or nil when nobody is.
    private func portHolder() async throws -> String? {
        let result = try await runner.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(Self.port)", "-sTCP:LISTEN", "-Fpc"])
        guard result.succeeded else { return nil }   // lsof exits 1 when nothing matches
        let lines = result.output.split(separator: "\n")
        let pid = lines.first { $0.hasPrefix("p") }.map { String($0.dropFirst()) } ?? "?"
        let command = lines.first { $0.hasPrefix("c") }.map { String($0.dropFirst()) } ?? "a process"
        return "\(command) (pid \(pid))"
    }

    private func writePlist() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.launchAgents, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.plistData(paths: paths).write(to: paths.plist, options: .atomic)
    }

    /// The launchd agent: one slot (dictations are one at a time), the whole
    /// model on the GPU, and no host-memory prompt cache beyond the slot's own.
    /// llama-server's log has timings only, never the text.
    static func plistData(paths: Paths) throws -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [
                paths.server.path,
                "--model", paths.model.path,
                "--host", "127.0.0.1",
                "--port", String(port),
                "--ctx-size", String(DictationCleaner.contextTokens),
                "--parallel", "1",
                "--n-gpu-layers", "99",
                "--cache-ram", "0",
                "--no-webui",
            ],
            "WorkingDirectory": paths.installDir.path,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "ThrottleInterval": 10,
            "StandardOutPath": paths.log.path,
            "StandardErrorPath": paths.log.path,
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// One quick `/health` round trip. llama-server answers 503 while the model
    /// is still loading.
    nonisolated static func probeHealth() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        request.timeoutInterval = 2
        guard let (data, response) = try? await DictationCleaner.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["status"] as? String == "ok"
    }
}

/// Downloads one file to disk with progress, and checks its SHA-256 before
/// handing it over. Large enough files (the model is 1.6 GB) are never held in
/// memory: the hash is computed in chunks from the file.
enum FileDownloader {
    enum Failure: LocalizedError {
        case http(Int)
        case checksum

        var errorDescription: String? {
            switch self {
            case .http(let status): return "HTTP \(status)"
            case .checksum: return "checksum mismatch"
            }
        }
    }

    static func fetch(_ url: URL, to destination: URL, sha256: String,
                      progress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = ProgressDelegate(progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let downloaded: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                delegate.destination = destination
                session.downloadTask(with: url).resume()
            }
        } onCancel: { session.invalidateAndCancel() }
        guard try digest(downloaded) == sha256 else {
            try? FileManager.default.removeItem(at: downloaded)
            throw Failure.checksum
        }
    }

    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Double) -> Void
        var continuation: CheckedContinuation<URL, Error>?
        var destination: URL?
        private var lastReported = -1

        init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let percent = Int(totalBytesWritten * 100 / totalBytesExpectedToWrite)
            guard percent != lastReported else { return }
            lastReported = percent
            progress(Double(percent) / 100)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard let destination else { return }
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else { finish(.failure(Failure.http(status))); return }
            // The temporary file is deleted as soon as this returns, so move it now.
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                finish(.success(destination))
            } catch { finish(.failure(error)) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { finish(.failure(error)) }
        }

        private func finish(_ result: Result<URL, Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }
}
