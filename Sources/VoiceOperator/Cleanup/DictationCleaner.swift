import Foundation

/// The on-device clean-up pass: a raw transcript in, the text the speaker meant
/// to type out, from Fluid-1 Mini on the local llama.cpp server that
/// `CleanupServer` runs. See DESIGN.md, "Dictation clean-up".
///
/// The request mirrors how FluidVoice drives the same model, since it was tuned
/// on that shape: the prompt as the system turn, the bare transcript as the user
/// turn (no app context), ChatML, greedy decoding, and an output budget that
/// grows with the transcript. One deliberate difference: the assistant turn is
/// pre-filled with an empty think block, because left to itself the model
/// sometimes starts reasoning and the reasoning would be pasted.
///
/// Every failure throws; `CleanedUpProvider` pastes the raw transcript instead.
struct DictationCleaner: Sendable {
    enum Failure: LocalizedError, Equatable {
        case noPrompt
        case tooLong
        case http(Int)
        case badResponse
        case empty
        case timedOut

        var errorDescription: String? {
            switch self {
            case .noPrompt: return "this build has no clean-up prompt"
            case .tooLong: return "the transcript is too long to clean up"
            case .http(let status): return "the clean-up server answered HTTP \(status)"
            case .badResponse: return "the clean-up server's answer was unreadable"
            case .empty: return "the model returned nothing"
            case .timedOut: return "the clean-up server took too long"
            }
        }
    }

    let systemPrompt: String
    var endpoint = URL(string: "http://127.0.0.1:\(CleanupServer.port)/completion")!

    /// Loopback only, but the request carries the transcript, so nothing of it
    /// may be cached on disk (see "Incognito mode" in DESIGN.md).
    static let session = URLSession(configuration: .ephemeral)

    /// The prompt shipped in the bundle (`Contents/Resources/dictation-cleanup.md`).
    static func bundled() throws -> DictationCleaner {
        guard let url = Bundle.main.url(forResource: "dictation-cleanup", withExtension: "md"),
              let prompt = try? String(contentsOf: url, encoding: .utf8) else { throw Failure.noPrompt }
        return DictationCleaner(systemPrompt: prompt)
    }

    func clean(_ transcript: String) async throws -> String {
        let budget = try Self.outputBudget(for: transcript)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.timeout(forBudget: budget)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "prompt": Self.prompt(system: systemPrompt, transcript: transcript),
            "n_predict": budget,
            // Greedy: top-k 1 is the only sampler.
            "samplers": ["top_k"],
            "top_k": 1,
            "temperature": 0,
            // The system turn is identical every time; keep its KV cache warm.
            "cache_prompt": true,
        ])
        let data: Data, response: URLResponse
        do { (data, response) = try await Self.session.data(for: request) }
        catch let error as URLError where error.code == .timedOut { throw Failure.timedOut }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw Failure.http(status) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = object["content"] as? String else { throw Failure.badResponse }
        let cleaned = Self.finish(output: content, transcript: transcript)
        guard !cleaned.isEmpty else { throw Failure.empty }
        return cleaned
    }

    // MARK: - Request

    /// ChatML, with the assistant turn opened on an empty think block.
    static func prompt(system: String, transcript: String) -> String {
        "<|im_start|>system\n\(system.trimmingCharacters(in: .whitespacesAndNewlines))<|im_end|>\n"
            + "<|im_start|>user\n\(transcript)<|im_end|>\n"
            + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }

    /// The context the server is started with (`-c`).
    static let contextTokens = 4096
    /// Room kept for the system prompt and the chat scaffolding.
    static let promptReserveTokens = 1280

    /// How many tokens the model may write: a generous multiple of a rough
    /// token estimate of the transcript, never under 256. Throws when the
    /// transcript itself would not fit beside the prompt.
    static func outputBudget(for transcript: String) throws -> Int {
        let words = transcript.split(whereSeparator: \.isWhitespace)
        let byWords = Int((Double(words.count) / 0.75).rounded(.up))
        let byBytes = words.reduce(0) { sum, word in
            let bytes = word.utf8.count
            return sum + (bytes > 12 ? (bytes + 1) / 2 : 1)
        }
        let estimate = max(1, byWords, byBytes)
        let requested = max(256, Int((Double(estimate) * 1.15).rounded(.up)) + 64)
        let available = contextTokens - promptReserveTokens - estimate
        guard available >= requested else { throw Failure.tooLong }
        return requested
    }

    /// Generation runs at about 95 tokens/s on an M4 Pro; allow several times
    /// that, plus slack for a cold prompt cache.
    static func timeout(forBudget budget: Int) -> TimeInterval {
        3 + Double(budget) / 30
    }

    // MARK: - Output

    /// Strip any think block and surrounding whitespace, then undo the one
    /// mistake the model is known to make: answering a spoken question rather
    /// than cleaning it.
    static func finish(output: String, transcript: String) -> String {
        let text = strippingThinking(output)
        return answeredQuestion(transcript: transcript, output: text) ? asQuestion(transcript) : text
    }

    static func strippingThinking(_ output: String) -> String {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("<think>") else { return text }
        text.removeFirst("<think>".count)
        if let close = text.range(of: "</think>") { text = String(text[close.upperBound...]) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let questionOpeners = [
        "who ", "what ", "when ", "where ", "why ", "how ", "is ", "are ", "am ", "was ", "were ",
        "do ", "does ", "did ", "can ", "could ", "would ", "should ", "will ", "may ",
    ]
    private static let answerOpeners = [
        "i am ", "i'm ", "my name ", "no, ", "yes, ", "there are ", "there is ", "it is ", "it's ",
        "as an ai ",
    ]

    /// The transcript reads as a question and the output reads as a reply to it.
    static func answeredQuestion(transcript: String, output: String) -> Bool {
        let question = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let answer = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !question.isEmpty, !answer.isEmpty else { return false }
        let looksLikeQuestion = question.hasSuffix("?") || questionOpeners.contains { question.hasPrefix($0) }
        let looksLikeAnswer = answerOpeners.contains { answer.hasPrefix($0) }
            || answer.contains("large language model") || answer.contains("dictation cleaner")
        return looksLikeQuestion && looksLikeAnswer
    }

    /// The transcript, minimally tidied into a question: capitalised, ending in "?".
    static func asQuestion(_ transcript: String) -> String {
        var text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.hasSuffix("?") {
            while let last = text.last, ".! ".contains(last) { text.removeLast() }
            text += "?"
        }
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
