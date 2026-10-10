import XCTest
@testable import VoiceOperator

final class ClaudeSummarizerTests: XCTestCase {
    func testAsksHaikuThroughTheDaemonOnTheShellPATH() async throws {
        let runner = DaemonRunner(reply: #"{"result":"A retry fix.\n","is_error":false,"subtype":"success"}"#)
        let summary = await ClaudeSummarizer.summarizeText("clipboard words", runner: runner)
        XCTAssertEqual(summary, "A retry fix.")

        let calls = runner.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].command.first, "/bin/zsh")
        let ask = calls[1]
        XCTAssertEqual(Array(ask.command.prefix(8)),
                       ["/usr/bin/env", "claude-print-daemon", "ask", "--tag", "voiceop-summarize",
                        "-m", "haiku", "--no-thinking"])
        XCTAssertEqual(ask.environment["PATH"], "/devkit/bin:/usr/bin")
        XCTAssertTrue(ask.prompt?.contains("<clipboard>\nclipboard words\n</clipboard>") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ask.command.last!), "prompt file left behind")
    }

    func testErrorReplyIsNil() async {
        let runner = DaemonRunner(reply: #"{"result":"rate limited","is_error":true,"subtype":"error"}"#)
        let summary = await ClaudeSummarizer.summarizeText("x", runner: runner)
        XCTAssertNil(summary)
    }

    func testDaemonMissingIsNil() async {
        let runner = DaemonRunner(reply: "env: claude-print-daemon: No such file or directory", status: 127)
        let summary = await ClaudeSummarizer.summarizeText("x", runner: runner)
        XCTAssertNil(summary)
    }
}

/// Answers the PATH probe like a shell whose startup files print noise, then the
/// `ask` with `reply`, reading the prompt file while it still exists.
private final class DaemonRunner: CommandRunner, @unchecked Sendable {
    struct Call { var command: [String]; var environment: [String: String]; var prompt: String? }
    private let lock = NSLock()
    private var _calls: [Call] = []
    let reply: String
    let status: Int32

    init(reply: String, status: Int32 = 0) { self.reply = reply; self.status = status }
    var calls: [Call] { lock.withLock { _calls } }

    func run(_ executable: String, _ arguments: [String], environment: [String: String],
             logTo: URL?) async throws -> CommandResult {
        let command = [executable] + arguments
        let prompt = executable == "/usr/bin/env" ? try? String(contentsOfFile: arguments.last!, encoding: .utf8) : nil
        lock.withLock { _calls.append(Call(command: command, environment: environment, prompt: prompt)) }
        if executable == "/bin/zsh" {
            return CommandResult(status: 0, output: "welcome!\n__VOICEOP_PATH__/devkit/bin:/usr/bin\n")
        }
        return CommandResult(status: status, output: reply)
    }
}
