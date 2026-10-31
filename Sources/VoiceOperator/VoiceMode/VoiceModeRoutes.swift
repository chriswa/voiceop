import Foundation

/// `/v1/voice-mode/…`: what the Claude Code plugin's hooks and `voice-mode`
/// command ask of `VoiceMode` (DESIGN.md "Claude Code voice mode"). The
/// command's requests are form-encoded (`curl --data-urlencode`); a hook's body
/// is the hook's own input JSON, passed through untouched, so the plugin's
/// scripts never have to take JSON apart.
@MainActor
enum VoiceModeRoutes {
    struct Answer: @unchecked Sendable {
        let status: Int
        var object: [String: Any]? = nil
        var text: String? = nil
    }

    static func handle(method: String, path: String, query: [String: String], body: Data) async -> Answer {
        let rest = path.dropFirst("/v1/voice-mode".count)
        switch (method, String(rest)) {
        case ("GET", ""), ("GET", "/"):
            return Answer(status: 200, object: VoiceMode.shared.status)
        case ("GET", "/watch"):
            let since = Int(query["since"] ?? "") ?? -1
            let wait = min(30, max(0, Int(query["wait"] ?? "0") ?? 0))
            return Answer(status: 200, object: await VoiceMode.shared.watch(since: since, wait: .seconds(wait)))
        case ("POST", "/attach"):
            let form = Self.form(body)
            guard let session = form["session_id"], !session.isEmpty else {
                return Answer(status: 400, object: ["error": "session_id_required",
                                                    "detail": "run voice-mode from inside a Claude Code session"])
            }
            let pid = Int32(form["claude_pid"] ?? "") ?? 0
            let cwd = form["cwd"] ?? ""
            do {
                let before = VoiceMode.shared.attachment
                do {
                    let a = try VoiceMode.shared.attach(sessionID: session, claudePID: pid, cwd: cwd,
                                                        trigger: form["trigger"].flatMap { $0.isEmpty ? nil : $0 },
                                                        voice: form["voice"].flatMap { $0.isEmpty ? nil : $0 })
                    var o = VoiceMode.shared.status
                    if let before, before.sessionID != a.sessionID { o["replaced"] = before.project }
                    if before?.sessionID == a.sessionID { o["already"] = true }
                    return Answer(status: 200, object: o)
                } catch VoiceMode.AttachError.incognito(let detail) {
                    return Answer(status: 403, object: ["error": "incognito", "detail": detail])
                } catch VoiceMode.AttachError.refused(let refusal) {
                    return Answer(status: 409, object: ["error": refusal.error, "detail": refusal.detail])
                } catch {
                    return Answer(status: 500, object: ["error": "attach_failed", "detail": "\(error)"])
                }
            }
        case ("POST", "/detach"):
            let session = Self.form(body)["session_id"].flatMap { $0.isEmpty ? nil : $0 }
            do {
                guard let current = VoiceMode.shared.attachment else { return Answer(status: 200, object: ["detached": false]) }
                if let session, session != current.sessionID {
                    return Answer(status: 409, object: ["error": "other_session", "project": current.project,
                                                        "detail": "voice mode is attached to another session (\(current.project))"])
                }
                VoiceMode.shared.detach(.asked)
                return Answer(status: 200, object: ["detached": true, "project": current.project])
            }
        case ("POST", "/say"):
            let form = Self.form(body)
            guard let text = form["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return Answer(status: 400, object: ["error": "text_required"])
            }
            let ok = await VoiceMode.shared.say(sessionID: form["session_id"] ?? "", text: text)
            return ok ? Answer(status: 202, object: ["spoken": true])
                : Answer(status: 409, object: ["error": "not_attached", "detail": "voice mode is not attached to this session"])
        case ("POST", "/stop-listening"):
            let ok = VoiceMode.shared.stopListening(sessionID: Self.form(body)["session_id"] ?? "")
            return ok ? Answer(status: 202, object: ["stopped": true])
                : Answer(status: 409, object: ["error": "not_attached", "detail": "voice mode is not attached to this session"])
        case ("POST", "/working"):
            let form = Self.form(body)
            let ok = VoiceMode.shared.setWorking(sessionID: form["session_id"] ?? "", form["on"] == "1" || form["on"] == "true")
            return ok ? Answer(status: 204) : Answer(status: 409, object: ["error": "not_attached"])
        case ("POST", "/simulate"):
            let form = Self.form(body)
            let text = form["text"] ?? ""
            let ok = VoiceMode.shared.simulate(sessionID: form["session_id"] ?? "", text)
            return ok ? Answer(status: 202, object: ["heard": text])
                : Answer(status: 409, object: ["error": "not_attached", "detail": "voice mode is not attached to that session"])
        case ("GET", "/next"):
            guard let session = query["session"], let generation = Int(query["generation"] ?? "") else {
                return Answer(status: 400, object: ["error": "session_and_generation_required"])
            }
            let wait = min(30, max(0, Int(query["wait"] ?? "0") ?? 0))
            switch await VoiceMode.shared.next(sessionID: session, generation: generation, wait: .seconds(wait)) {
            case .message(let text): return Answer(status: 200, text: text)
            case .nothingYet: return Answer(status: 204)
            case .gone(let why): return Answer(status: 410, text: why)
            }
        case ("POST", let hook) where hook.hasPrefix("/hooks/"):
            guard var input = VoiceModeHookInput(json: body) else { return Answer(status: 400, object: ["error": "hook_input_required"]) }
            input.claudePID = Int32(query["claude_pid"] ?? "")
            return await Self.hook(String(hook.dropFirst("/hooks/".count)), input)
        default:
            return Answer(status: 404, object: ["error": "not_found"])
        }
    }

    private static func hook(_ name: String, _ input: VoiceModeHookInput) async -> Answer {
        let mode = VoiceMode.shared
        switch name {
        case "stop":
            guard let generation = await mode.turnEnded(input) else { return Answer(status: 204) }
            return Answer(status: 200, text: String(generation))
        case "post-tool-use":
            return mode.midTurn(input).map { Answer(status: 200, object: $0) } ?? Answer(status: 204)
        case "user-prompt-submit":
            return mode.promptSubmitted(input).map { Answer(status: 200, text: $0) } ?? Answer(status: 204)
        case "session-start":
            guard let a = mode.sessionStarted(input) else { return Answer(status: 204) }
            return Answer(status: 200, text: "Voice mode is attached to this session: say “\(a.trigger)” to start talking.")
        case "session-end":
            mode.sessionEnded(input)
            return Answer(status: 204)
        case "notification":
            await mode.notified(input)
            return Answer(status: 204)
        default:
            return Answer(status: 404, object: ["error": "unknown_hook"])
        }
    }

    /// `voice_mode` in `/v1/status`.
    static func status() -> Answer { Answer(status: 200, object: VoiceMode.shared.status) }

    /// A form-encoded body (`a=1&b=two%20words`).
    nonisolated static func form(_ body: Data) -> [String: String] {
        guard let string = String(data: body, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for pair in string.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first?.removingPercentEncoding else { continue }
            out[key] = parts.count > 1 ? String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "" : ""
        }
        return out
    }
}
