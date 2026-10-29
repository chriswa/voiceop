import Foundation

/// The words that pass between Claude Code and the user in voice mode
/// (`VoiceMode`): an agent's reply made fit to be heard, and what the user said
/// made into a message for the agent. Pure, for the tests.
enum VoiceModeText {
    /// An agent's final message as it should sound. Agents are asked to write
    /// these to be heard, but markdown still turns up: code blocks are not read
    /// out, tables lose their rules, links keep their words, and the marks
    /// themselves go. Each line becomes a sentence, so a list is read as a
    /// list rather than run together. `TTSPreprocess` does the rest.
    static func spoken(_ markdown: String) -> String {
        var sentences: [String] = []
        var inFence = false
        var fenceAnnounced = false
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                if inFence, !fenceAnnounced {
                    sentences.append("(Code in the terminal.)")
                    fenceAnnounced = true
                }
                continue
            }
            if inFence { continue }
            fenceAnnounced = false
            var text = line
            // A table's rule row says nothing; its cells read as a list.
            if text.hasPrefix("|") {
                if text.allSatisfy({ "|-: ".contains($0) }) { continue }
                text = text.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }.joined(separator: ", ")
            }
            text = text.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"^>\s?"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"^([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?"#, with: "", options: .regularExpression)
            if text.allSatisfy({ "-*_ ".contains($0) }) { continue }   // a horizontal rule, or nothing
            text = text.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            text = text.replacingOccurrences(of: #"https?://\S+"#, with: "a link", options: .regularExpression)
            text = text.replacingOccurrences(of: "`", with: "")
            text = text.replacingOccurrences(of: #"(\*\*|__)(.+?)\1"#, with: "$2", options: .regularExpression)
            text = text.replacingOccurrences(of: #"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, with: "$1", options: .regularExpression)
            text = text.replacingOccurrences(of: #"~~(.+?)~~"#, with: "$1", options: .regularExpression)
            text = text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if let last = text.last, !".!?:;…".contains(last) { text += "." }
            sentences.append(text)
        }
        return sentences.joined(separator: " ")
    }

    /// The dictation without its leading trigger word ("Claude, make it jump
    /// higher" → "make it jump higher"), the first letter raised again.
    static func withoutTrigger(_ text: String, trigger: String?) -> String {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trigger, !trigger.isEmpty {
            let pattern = "^" + NSRegularExpression.escapedPattern(for: trigger) + #"\b[\s,.!?:;-]*"#
            rest = rest.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        guard let first = rest.first else { return "" }
        return first.uppercased() + rest.dropFirst()
    }

    /// The last `words` words of `text`: what a listener cut in on, for the agent.
    static func tail(_ text: String, words: Int = 12) -> String {
        let all = text.split(whereSeparator: \.isWhitespace)
        let kept = all.suffix(words).joined(separator: " ")
        return all.count > words ? "…" + kept : kept
    }

    /// What the agent is handed for something the user said. `whileWorking`:
    /// it arrives mid-turn (`PostToolUse`), not as the next turn. `heard`: they
    /// cut the agent's spoken reply off, having heard it up to these words.
    static func message(said: String, whileWorking: Bool, interrupted: Bool, heard: String?) -> String {
        var out = whileWorking
            ? "[Voice mode] While you were working, the user said (by voice, transcribed on device): \"\(said)\""
            : "[Voice mode] The user said (by voice, transcribed on device): \"\(said)\""
        if interrupted {
            if let heard, !heard.isEmpty {
                out += "\nThey talked over your spoken reply, which they heard up to: \"\(heard)\"."
            } else {
                out += "\nThey talked over your spoken reply."
            }
        }
        return out
    }

    /// The user cut the reply off, but no words were caught.
    static func interruptedWithoutWords(heard: String?) -> String {
        var out = "[Voice mode] The user talked over your spoken reply, but no words were caught."
        if let heard, !heard.isEmpty { out += " They heard it up to: \"\(heard)\"." }
        return out + " Ask them, briefly, what they said."
    }
}

/// The parts of a Claude Code hook's input voice mode reads. Unknown and
/// missing fields are fine: each event fills in its own.
struct VoiceModeHookInput {
    var sessionID: String?
    var lastAssistantMessage: String?
    var transcriptPath: String?
    /// SessionStart: `startup`, `resume`, `clear`, `compact`.
    var source: String?
    /// SessionEnd: `clear`, `logout`, `prompt_input_exit`, …
    var reason: String?
    var toolName: String?
    var command: String?
    /// Notification: its words and kind (`permission_prompt`, `idle_prompt`, …).
    var message: String?
    var notificationType: String?
    /// The `claude` process the hook ran under, when the hook script found it.
    var claudePID: Int32?

    init(sessionID: String? = nil) { self.sessionID = sessionID }

    init?(json data: Data) {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        sessionID = o["session_id"] as? String
        lastAssistantMessage = o["last_assistant_message"] as? String
        transcriptPath = o["transcript_path"] as? String
        source = o["source"] as? String
        reason = o["reason"] as? String
        toolName = o["tool_name"] as? String
        command = (o["tool_input"] as? [String: Any])?["command"] as? String
        message = o["message"] as? String
        notificationType = o["notification_type"] as? String
    }

    /// The last thing the assistant wrote, from the session's transcript
    /// (JSONL), for a Claude Code that does not send `last_assistant_message`.
    static func lastAssistantText(transcript: String) -> String? {
        for line in transcript.split(separator: "\n").reversed() {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  o["type"] as? String == "assistant",
                  let message = o["message"] as? [String: Any] else { continue }
            if let text = message["content"] as? String { return text }
            let texts = (message["content"] as? [[String: Any]] ?? [])
                .filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        return nil
    }
}

/// Which Bash commands voice mode lets the agent run without asking, while it
/// is attached: its own controls, so "turn voice chat off" works with nobody at
/// the keyboard. Only these exact shapes: anything a shell could expand or
/// chain is asked about as usual.
enum VoiceModeCommandGuard {
    static func isVoiceControl(_ command: String) -> Bool {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.range(of: #"^voice-mode( (stop|status|help))?$"#, options: .regularExpression) != nil { return true }
        // `say` with one single-quoted argument: nothing inside single quotes is expanded.
        if c.range(of: #"^voice-mode say '[^']*'$"#, options: .regularExpression) != nil { return true }
        // …or a quoted heredoc, whose body is not expanded either, ending at its first `EOF` line.
        let lines = c.components(separatedBy: "\n")
        if lines.count >= 3, lines[0] == "voice-mode say <<'EOF'", lines.last == "EOF",
           !lines.dropFirst().dropLast().contains("EOF") {
            return true
        }
        return false
    }
}
