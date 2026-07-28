import Foundation

/// Compresses a Claude Code turn into a short spoken update via the Anthropic
/// Messages API (Haiku), authenticated with the Claude Code OAuth token from the
/// macOS Keychain — a port of transcript-reader.py's `summarize`. Falls back to
/// the raw latest message if auth/the request fails, so narration never stalls.
struct ClaudeSummarizer {
    private static let model = "claude-haiku-4-5-20251001"
    private static let url = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let keychainService = "Claude Code-credentials"


    private static let clipboardInstruction = """
    You are summarizing a piece of text the user has on their clipboard. In one \
    or two short sentences of plain English, capture what it says or is about. Do \
    NOT add preamble, commentary, or a lead-in like "This text is about"; just give \
    the summary. No markdown, no lists, no code fences, no quotation marks. Output \
    ONLY the summary.
    """


    /// Summarize arbitrary clipboard text into one or two sentences. Returns nil on
    /// auth/HTTP/parse failure so the caller can leave the clipboard untouched
    /// rather than overwrite it with a fallback.
    static func summarizeText(_ text: String) async -> String? {
        await callHaiku(instruction: clipboardInstruction, userContent: text)
    }


    /// Shared Haiku call for a single user message. Returns trimmed text, or nil
    /// on auth/HTTP/parse failure.
    private static func callHaiku(instruction: String, userContent: String) async -> String? {
        await callHaiku(instruction: instruction,
                        messages: [["role": "user", "content": userContent]])
    }

    /// Shared Haiku call for a full message array (multi-turn). Returns trimmed
    /// text, or nil on auth/HTTP/parse failure.
    private static func callHaiku(instruction: String, messages: [[String: Any]]) async -> String? {
        guard let token = readOAuthToken() else { return nil }
        let body: [String: Any] = [
            "model": model, "max_tokens": 250,
            "system": [
                ["type": "text", "text": "You are Claude Code, Anthropic's official CLI for Claude."],
                ["type": "text", "text": instruction],
            ],
            "messages": messages,
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
