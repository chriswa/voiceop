import Foundation

/// Compresses a Claude Code turn into a short spoken update via the Anthropic
/// Messages API (Haiku), authenticated with the Claude Code OAuth token from the
/// macOS Keychain — a port of transcript-reader.py's `summarize`. Falls back to
/// the raw latest message if auth/the request fails, so narration never stalls.
struct ClaudeSummarizer {
    private static let model = "claude-haiku-4-5-20251001"
    private static let url = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let keychainService = "Claude Code-credentials"

    private static let instruction = """
    You are turning a coding agent's just-completed turn into a very short SPOKEN \
    audio update for the user. You are given the agent's most recent turn — the \
    user's latest message and everything the agent said in response, ending with \
    its concluding message — plus a list of updates already spoken aloud to the \
    user. In one or two short sentences of plain spoken English, say what the \
    agent communicated or accomplished in this turn — focus on the genuinely NEW \
    information and don't restate what was already spoken. No markdown, no lists, \
    no code, no preamble, no quotation marks. Output ONLY the spoken update.
    """

    private static let elaborateInstruction = """
    You are elaborating on a coding agent's turn that has ALREADY been summarized \
    aloud for the user. You are given the full conversation turn plus a list of \
    everything already spoken aloud about it. In one or two short sentences of \
    plain spoken English, provide ADDITIONAL detail that has NOT already been \
    spoken — go deeper: specifics, caveats, reasoning, or next steps not yet \
    mentioned. Do NOT repeat or rephrase anything in the already-spoken list. If \
    there is genuinely no further meaningful detail to add beyond what was already \
    said, respond with EXACTLY: No more information to summarize. No markdown, no \
    lists, no code, no preamble, no quotation marks. Output ONLY the spoken \
    elaboration (or the exact no-more-information sentence).
    """

    /// The escape-hatch sentence the model returns when a depth chain is exhausted.
    static let noMoreInfoPhrase = "No more information to summarize."
    static func isNoMoreInfo(_ text: String) -> Bool {
        text.lowercased().contains("no more information")
    }

    /// `context` is the turns since the previous end-of-turn; `spoken` are recent
    /// summaries already read aloud (so Haiku doesn't repeat itself).
    static func summarize(context: [Turn], spoken: [String]) async -> String {
        let latest = context.last?.text ?? ""
        return await callHaiku(instruction: instruction,
                               userContent: userContent(context: context, spoken: spoken)) ?? latest
    }

    /// Re-run the summarizer on the same context to add NEW detail beyond what was
    /// already spoken. On failure, returns the no-more-information sentence so a
    /// dead end never fabricates content or extends the chain.
    static func elaborate(context: [Turn], alreadySpoken: [String]) async -> String {
        await callHaiku(instruction: elaborateInstruction,
                        userContent: userContent(context: context, spoken: alreadySpoken)) ?? noMoreInfoPhrase
    }

    private static func userContent(context: [Turn], spoken: [String]) -> String {
        let transcript = context.map { "\($0.role.uppercased()): \($0.text)" }.joined(separator: "\n\n")
        let already = spoken.isEmpty ? "(nothing yet)" : spoken.map { "- \($0)" }.joined(separator: "\n")
        return "ALREADY SPOKEN ALOUD (do not repeat these):\n\(already)\n\n--- CONVERSATION ---\n\n\(transcript)"
    }

    /// Shared Haiku call. Returns trimmed text, or nil on auth/HTTP/parse failure.
    private static func callHaiku(instruction: String, userContent: String) async -> String? {
        guard let token = readOAuthToken() else { return nil }
        let body: [String: Any] = [
            "model": model, "max_tokens": 250,
            "system": [
                ["type": "text", "text": "You are Claude Code, Anthropic's official CLI for Claude."],
                ["type": "text", "text": instruction],
            ],
            "messages": [["role": "user", "content": userContent]],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("claude-code/2.1.47", forHTTPHeaderField: "User-Agent")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            return nil
        }
        let text = content.compactMap { $0["text"] as? String }.joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
        return text.isEmpty ? nil : text
    }

    /// Read the Claude Code OAuth access token from the Keychain (fresh each call
    /// so we pick up rotations). Shells `security`, mirroring the Python PoC.
    private static func readOAuthToken() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", keychainService,
                       "-a", NSUserName(), "-w"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: out) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any] else { return nil }
        return oauth["accessToken"] as? String
    }
}
