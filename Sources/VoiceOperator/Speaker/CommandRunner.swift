import Foundation

/// What a finished command reported.
struct CommandResult: Sendable, Equatable {
    var status: Int32
    var output: String
    var succeeded: Bool { status == 0 }
}

/// Runs an external program. A protocol so `KokoroService`'s install and
/// launchd steps can be tested without running `uv` or `launchctl`.
protocol CommandRunner: Sendable {
    /// Run `executable` with `arguments` and wait for it to exit, returning its
    /// combined stdout/stderr. When `logTo` is given, output is also appended
    /// there as it arrives, so a minutes-long `uv pip install` can be followed
    /// live. Cancelling the calling task terminates the process.
    func run(_ executable: String, _ arguments: [String], logTo: URL?) async throws -> CommandResult
}

extension CommandRunner {
    func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        try await run(executable, arguments, logTo: nil)
    }
}

/// The real thing, over `Process`.
struct ProcessRunner: CommandRunner {
    func run(_ executable: String, _ arguments: [String], logTo: URL?) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let sink = OutputSink(logTo: logTo)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { sink.append(data) }
        }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
                process.terminationHandler = { finished in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    // Whatever arrived after the last readability callback.
                    if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty { sink.append(rest) }
                    sink.close()
                    continuation.resume(returning: CommandResult(status: finished.terminationStatus, output: sink.text))
                }
                do { try process.run() } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    sink.close()
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

/// Collects a command's output, and tees it to a log file when asked.
private final class OutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let log: FileHandle?

    init(logTo url: URL?) {
        if let url {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            log = try? FileHandle(forWritingTo: url)
            _ = try? log?.seekToEnd()
        } else {
            log = nil
        }
    }

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            try? log?.write(contentsOf: chunk)
        }
    }

    func close() { lock.withLock { try? log?.close() } }

    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
