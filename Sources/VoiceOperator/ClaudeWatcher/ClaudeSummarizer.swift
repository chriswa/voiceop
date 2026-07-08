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

    // A pending block is NOT a completed turn: the agent has paused and is
    // waiting on the user. The summary must relay the ask itself — including the
    // real multiple-choice options (the model may summarize them) — but it must
    // NOT answer the question or fabricate options that weren't offered.
    private static let questionInstruction = """
    A coding agent has PAUSED and is waiting for the user to answer a question. \
    You are given what the agent did leading up to it, ending with the question \
    it is asking and its multiple-choice options. In one or two short sentences \
    of plain spoken English, say what the agent has been doing and what it is now \
    asking. State the question, and briefly convey the options when that helps the \
    user decide. Do NOT answer the question yourself, do NOT guess or state the \
    user's answer, and do NOT invent options that weren't listed. No markdown, no \
    lists, no code, no preamble, no quotation marks. Output ONLY the spoken update.
    """

    private static let planInstruction = """
    A coding agent has finished planning and is presenting a plan for the user's \
    approval. You are given what the agent did leading up to it, ending with the \
    proposed plan. In one or two short sentences of plain spoken English, say what \
    the agent has been doing and what its plan proposes to do, at a high level. Do \
    NOT invent specifics that aren't in the plan. No markdown, no lists, no code, \
    no preamble, no quotation marks. Output ONLY the spoken update.
    """

    enum PendingKind { case question, plan }

    /// Summarize a pending block (an unanswered question or a plan awaiting
    /// approval). Unlike `summarize`, this instructs the model to relay the ask
    /// without answering it or fabricating answer options. On failure it falls
    /// back to a safe short line (never the multi-KB raw plan).
    static func summarizePending(context: [Turn], kind: PendingKind) async -> String {
        let instruction = kind == .plan ? planInstruction : questionInstruction
        let fallback = kind == .plan
            ? "The agent has a plan ready for your review."
            : (context.last?.text ?? "The agent is asking you a question.")
        return await callHaiku(instruction: instruction,
                               userContent: userContent(context: context, spoken: [])) ?? fallback
    }

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
