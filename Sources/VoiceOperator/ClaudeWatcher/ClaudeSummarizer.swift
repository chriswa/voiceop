import Foundation

/// Compresses text into a short summary with Haiku through `claude-print-daemon`
/// (chriswa-devkit's `tools/claude-print-daemon`), which keeps unmodified Claude
/// Code `claude -p` processes signed in and waiting. Voice Operator never touches
/// Claude credentials itself: Claude Code's own sign-in is the only one used.
///
/// The daemon is found on the PATH of the user's interactive shell, where
/// chriswa-devkit puts its `bin/` — an app launched from Finder doesn't get that
/// PATH. The daemon `ask` starts (when none is running) inherits it too, which is
/// how it finds `claude`.
struct ClaudeSummarizer {
    private static let timeout: Duration = .seconds(30)

    private static let clipboardInstruction = """
    You are summarizing a piece of text the user has on their clipboard, given \
    below between <clipboard> tags. In one or two short sentences of plain \
    English, capture what it says or is about. Do NOT add preamble, commentary, \
    or a lead-in like "This text is about"; just give the summary. No markdown, \
    no lists, no code fences, no quotation marks. Output ONLY the summary.
    """

    /// Summarize arbitrary clipboard text into one or two sentences. Returns nil on
    /// any failure so the caller can leave the clipboard untouched rather than
    /// overwrite it with a fallback.
    static func summarizeText(_ text: String, runner: CommandRunner = ProcessRunner()) async -> String? {
        await askHaiku(clipboardInstruction + "\n\n<clipboard>\n" + text + "\n</clipboard>", runner: runner)
    }

    /// One fresh Haiku turn, no thinking and no system prompt: the profile the
    /// daemon always keeps a spare process for, so the reply doesn't wait on
    /// Claude Code's startup. The instruction rides in the prompt for that reason.
    /// Returns the trimmed reply, or nil on failure.
    private static func askHaiku(_ prompt: String, runner: CommandRunner) async -> String? {
        guard let path = await userShellPATH(runner: runner) else { return nil }

        // `ask` reads the prompt from a file or stdin; the runner gives no stdin.
        // $TMPDIR is per-user, and the file is gone as soon as the call returns.
        let promptFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceop-summary-\(UUID().uuidString).txt")
        do { try Data(prompt.utf8).write(to: promptFile, options: .atomic) }
        catch {
            Log.log("haiku: could not write the prompt file: \(error.localizedDescription)")
            return nil
        }
        defer { try? FileManager.default.removeItem(at: promptFile) }

        let result: CommandResult?
        do {
            result = try await withThrowingTaskGroup(of: CommandResult?.self) { group in
                group.addTask {
                    try await runner.run("/usr/bin/env",
                                         ["claude-print-daemon", "ask", "--tag", "voiceop-summarize",
                                          "-m", "haiku", "--no-thinking", promptFile.path],
                                         environment: ["PATH": path], logTo: nil)
                }
                group.addTask { try await Task.sleep(for: timeout); return nil }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }
        } catch {
            Log.log("haiku: could not run claude-print-daemon: \(error.localizedDescription)")
            return nil
        }
        guard let result else {
            Log.log("haiku: claude-print-daemon gave no reply within \(timeout)")
            return nil
        }
        // Exit 127 is env's "not found": chriswa-devkit's bin/ isn't on the shell's PATH.
        guard result.succeeded else {
            Log.log("haiku: claude-print-daemon exit \(result.status) — \(result.output.prefix(300))")
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
              let reply = json["result"] as? String else {
            Log.log("haiku: unexpected claude-print-daemon output (\(result.output.utf8.count) bytes)")
            return nil
        }
        if json["is_error"] as? Bool == true {
            Log.log("haiku: Claude Code reported an error (\(json["subtype"] as? String ?? "?")) — \(reply.prefix(300))")
            return nil
        }
        let text = reply.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
        return text.isEmpty ? nil : text
    }

    /// The PATH an interactive login zsh ends up with — read fresh each call (about
    /// 50 ms) so a tool moved between directories is found without a restart. The
    /// marker separates it from anything the shell's startup files print.
    private static func userShellPATH(runner: CommandRunner) async -> String? {
        let marker = "__VOICEOP_PATH__"
        let result: CommandResult
        do { result = try await runner.run("/bin/zsh", ["-ilc", "print -r -- \(marker)$PATH"]) }
        catch {
            Log.log("haiku: could not run zsh to read PATH: \(error.localizedDescription)")
            return nil
        }
        guard let line = result.output.split(separator: "\n").last(where: { $0.hasPrefix(marker) }) else {
            Log.log("haiku: zsh printed no PATH (exit \(result.status))")
            return nil
        }
        return String(line.dropFirst(marker.count))
    }
}
