import Foundation

/// Supplies the custom words that fill a flow request's `context.dictionary_context`
/// (see `WisprTranscriber`). Kept behind a protocol so the transcriber can be
/// unit-tested with a fixed word list.
protocol DictionaryContextProviding: Sendable {
    /// The current custom words to bias transcription toward. Must return
    /// promptly — callers invoke this on the dictation hot path — so it serves a
    /// cached snapshot rather than blocking on the network.
    func contextWords() async -> [String]
}

/// The user's live Wispr Flow dictionary, fetched from Wispr's API and cached on
/// disk. These are the same custom words Wispr Flow biases toward, so proper
/// nouns like "Claude" transcribe correctly here too.
///
/// Fetching is **stale-while-revalidate** with a 24 h *soft* expiry: reads always
/// return the cached words immediately (even when stale), and a stale read kicks
/// off a single background refresh that replaces the cache for next time.
/// Dictation never blocks on the network — a cold start (no cache yet) simply
/// returns no words for the first dictation and fills in once the fetch lands.
actor WisprDictionary: DictionaryContextProviding {
    static let shared = WisprDictionary()

    /// Wispr's cap on how many words ride along in `dictionary_context` (`_.D`).
    static let maxWords = 60
    /// Soft expiry: past this age we still serve the cache but refresh behind it.
    static let softTTL: TimeInterval = 24 * 60 * 60

    private let host: String
    private let session: URLSession
    private let tokenProvider: @Sendable () async throws -> String

    init(host: String = "https://api.wisprflow.ai",
         session: URLSession = .shared,
         tokenProvider: @escaping @Sendable () async throws -> String = { try await WisprToken.shared.accessToken() }) {
        self.host = host
        self.session = session
        self.tokenProvider = tokenProvider
    }

    // MARK: - Cache

    private struct Cache: Codable {
        var words: [String]
        var fetchedAt: Date
    }

    private var cache: Cache?
    private var loadedFromDisk = false
    private var refreshing = false

    private static let fileURL: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("VoiceOperator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dictionary.json")
    }()

    func contextWords() async -> [String] {
        if !loadedFromDisk {
            cache = Self.loadFromDisk()
            loadedFromDisk = true
        }
        let age = cache.map { Date().timeIntervalSince($0.fetchedAt) }
        if age == nil || age! > Self.softTTL { startRefresh() }
        return cache?.words ?? []
    }

    private static func loadFromDisk() -> Cache? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }

    private func startRefresh() {
        guard !refreshing else { return }   // coalesce concurrent stale reads into one fetch
        refreshing = true
        Task { await self.refresh() }
    }

    private func refresh() async {
        defer { refreshing = false }
        do {
            let words = try await fetchWords()
            let cache = Cache(words: words, fetchedAt: Date())
            self.cache = cache
            if let data = try? JSONEncoder().encode(cache) {
                try? data.write(to: Self.fileURL, options: .atomic)
            }
            Log.log("dictionary: refreshed \(words.count) custom words")
        } catch {
            // Keep serving the existing cache; try again on the next stale read.
            Log.log("dictionary: refresh failed (\(TranscriberError.userMessage(for: error)))")
        }
    }

    // MARK: - Fetch

    /// One raw entry from `GET /api/v1/dictionary/{personal,team}`. The server
    /// uses snake_case keys (distinct from Wispr's local camelCase columns).
    struct Entry: Decodable {
        let word: String?
        let replacement: String?
        let is_deleted: Bool?
        let frequency_used: Double?
        let last_used: String?
        let modified_at: String?
    }

    private func fetchWords() async throws -> [String] {
        let token = try await tokenProvider()
        async let personalTask = fetchEntries(path: "/api/v1/dictionary/personal", token: token)
        async let teamTask = fetchEntries(path: "/api/v1/dictionary/team", token: token)
        let personal = try await personalTask                 // personal is required
        let team = (try? await teamTask) ?? []                // team is best-effort (user may have none)
        return Self.contextWords(personal: personal, team: team)
    }

    private func fetchEntries(path: String, token: String) async throws -> [Entry] {
        try Incognito.check(.network("Wispr Flow"))
        var req = URLRequest(url: URL(string: host + path)!)
        req.httpMethod = "GET"
        req.setValue(token, forHTTPHeaderField: "Authorization")   // raw JWT, not "Bearer"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw TranscriberError.badResponse }
        guard http.statusCode == 200 else {
            throw TranscriberError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode([Entry].self, from: data)
    }

    /// Select the words to send: recognition-only entries (no `replacement`, not
    /// deleted), ranked by usage, personal before team, deduped, capped at
    /// `maxWords`. Pure so it can be unit-tested. (Wispr also floats *starred*
    /// words first, but starring is local-only client state the API never
    /// returns, so it can't be reproduced from a fetch — see the decode notes.)
    static func contextWords(personal: [Entry], team: [Entry], limit: Int = maxWords) -> [String] {
        let ranked = rank(personal) + rank(team)
        var seen = Set<String>()
        var out: [String] = []
        for word in ranked where seen.insert(word.lowercased()).inserted {
            out.append(word)
            if out.count >= limit { break }
        }
        return out
    }

    private static func rank(_ entries: [Entry]) -> [String] {
        entries
            .filter { $0.is_deleted != true && $0.replacement == nil }
            .compactMap { e -> (word: String, freq: Double, recency: String)? in
                guard let w = e.word?.trimmingCharacters(in: .whitespacesAndNewlines), !w.isEmpty
                else { return nil }
                return (w, e.frequency_used ?? 0, e.last_used ?? e.modified_at ?? "")
            }
            // Most-used first; ISO-8601 timestamps sort lexically by recency to break ties.
            .sorted { $0.freq != $1.freq ? $0.freq > $1.freq : $0.recency > $1.recency }
            .map(\.word)
    }
}
