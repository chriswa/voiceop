import Foundation

/// Reads (and refreshes) the Wispr Flow Supabase access token — approach "A"
/// from DESIGN.md. We lift the token Wispr already stored rather than
/// reimplementing its login.
///
/// Supabase auth is a standard protocol, so refresh works headlessly using the
/// public anon key embedded in Wispr's bundle.
///
/// Supabase **rotates** refresh tokens: every successful refresh spends the
/// token it was given and issues a new one, and re-POSTing a spent token comes
/// back `400 refresh_token_already_used`. So the rotated session must outlive
/// the process. It used to be held in memory only, which made dictation a
/// one-restart fuse: the first refresh spent the token in Wispr's
/// `session.json`, nothing ever rewrote that file (the Wispr Flow app is
/// retired here), and the live tip of the chain died with the process — so the
/// *next* launch POSTed the long-spent file token and 400'd forever. We now
/// persist each rotation to our own store so a restart resumes the chain.
actor WisprToken {
    static let shared = WisprToken()

    // Wispr's Supabase project. The anon key is a *public* client key (role:
    // anon) that only gates the refresh endpoint — safe to embed.
    private static let supabaseURL = "https://dodjkfqhwrzqjwkfnthl.supabase.co"
    private static let anonKey = """
    eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRvZGprZn\
    Fod3J6cWp3a2ZudGhsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3MTk4ODQzMDcsImV4cCI6MjAzNTQ2M\
    DMwN30.h6EeQ_6kqFeznH25icVUX0Szn9__kc8HoSXAsxxBWG8
    """

    private static var sessionPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/Wispr Flow/session.json")
    }
    private static let tokenKey = "sb-dodjkfqhwrzqjwkfnthl-auth-token"

    /// Whether there is any Wispr sign-in to work from: Wispr Flow's own session
    /// or our rotated copy of it. A Mac that never had Wispr Flow has neither.
    /// File checks only — no Keychain, no network, nothing logged.
    static var hasSession: Bool {
        FileManager.default.fileExists(atPath: sessionPath)
            || FileManager.default.fileExists(atPath: storePath.path)
    }

    /// Our own copy of the rotated session. Deliberately *not* Wispr's file: we
    /// never write to another app's storage, and Wispr rewrites that file
    /// wholesale whenever it runs.
    static var storePath: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceOperator/wispr-session.json")
    }

    private struct Session: Codable {
        let access_token: String
        let refresh_token: String
        let expires_at: Double
    }

    /// The most recently obtained session. Also mirrored to `storePath`; this
    /// just saves a file read on the dictation critical path.
    private var cached: Session?

    /// A currently-valid access token, refreshing via Supabase if within 60s of
    /// expiry. Throws if Wispr has never been signed in on this machine.
    func accessToken() async throws -> String {
        if let cached, !Self.isExpiring(cached) { return cached.access_token }

        // Three places a session can come from, newest-issued first. Our store
        // normally holds the tip of the chain; Wispr's file wins only when the
        // Wispr Flow app has run since (a fresh sign-in), which is exactly how a
        // spent chain recovers without any manual step.
        let candidates = Self.rank([cached, loadStored(), try? loadWisprSession()])
        guard !candidates.isEmpty else { throw TranscriberError.notSignedIn }

        // An access token that is still good beats any refresh: no round trip on
        // the critical path, and no rotation to keep in sync.
        if let live = candidates.first(where: { !Self.isExpiring($0) }) {
            adopt(live)
            return live.access_token
        }

        // Otherwise spend a refresh token. If the newest one is already spent —
        // another process rotated it, or a stale store survived a sign-in — fall
        // through to the next distinct one rather than failing the dictation.
        var lastError: Error = TranscriberError.notSignedIn
        for candidate in candidates {
            do {
                let session = try await coalescedRefresh(candidate.refresh_token)
                adopt(session)
                return session.access_token
            } catch {
                lastError = error
                // Only a rejected *token* is worth retrying with another one; a
                // network failure would fail identically for every candidate.
                guard Self.isRejected(error) else { throw error }
            }
        }
        Log.log("token: every refresh token is spent — open Wispr Flow and sign in to restore dictation")
        if Self.isRejected(lastError) { throw TranscriberError.signInExpired }
        throw lastError
    }

    /// Newest-issued first, without repeating a refresh token we would only have
    /// re-POSTed to the same answer.
    private static func rank(_ sessions: [Session?]) -> [Session] {
        var seen = Set<String>()
        return sessions.compactMap { $0 }
            .sorted { $0.expires_at > $1.expires_at }
            .filter { seen.insert($0.refresh_token).inserted }
    }

    /// Hold the session in memory *and* on disk, so the next launch resumes this
    /// chain instead of replaying a spent token.
    private func adopt(_ session: Session) {
        cached = session
        store(session)
    }

    /// One refresh at a time. This method suspends, and an actor is reentrant
    /// across suspension, so two callers arriving together (launch prewarm plus a
    /// dictation, or two dictations just after the hourly expiry) would otherwise
    /// both POST the *same* refresh token. Supabase rotates refresh tokens, so the
    /// second POST is a replay and comes back 400 — costing that dictation the
    /// formatted path for no reason.
    private var refreshInFlight: Task<Session, Error>?

    private func coalescedRefresh(_ refreshToken: String) async throws -> Session {
        if let refreshInFlight { return try await refreshInFlight.value }
        let task = Task { try await refresh(refreshToken) }
        refreshInFlight = task
        defer { refreshInFlight = nil }
        let session = try await task.value
        Log.log("token: refreshed via Supabase")
        return session
    }

    /// Fetch (and cache) a token ahead of time so it is never on the dictation
    /// critical path. Failures are logged and ignored — the real call will retry.
    func prewarm() async {
        do { _ = try await accessToken() }
        catch { Log.log("token: prewarm failed (\(TranscriberError.userMessage(for: error)))") }
    }

    private static func isExpiring(_ session: Session) -> Bool {
        Date().timeIntervalSince1970 > session.expires_at - 60
    }

    /// True when Supabase refused the *token* (spent, revoked, malformed) rather
    /// than failing to answer. Those are the cases where another candidate has a
    /// real chance of working.
    private static func isRejected(_ error: Error) -> Bool {
        switch error {
        case TranscriberError.http(let status, _):
            return (400...403).contains(status)
        default:
            return false
        }
    }

    // MARK: - Storage

    private func loadStored() -> Session? {
        guard let data = try? Data(contentsOf: Self.storePath) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    /// Best-effort: a failed write costs us the chain across the next restart,
    /// which is bad, but failing the dictation in hand over it would be worse.
    private func store(_ session: Session) {
        do {
            let url = Self.storePath
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(session).write(to: url, options: .atomic)
            // It is a live credential; keep it off other accounts on the machine.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.log("token: could not persist session (\(error.localizedDescription))")
        }
    }

    private func loadWisprSession() throws -> Session {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.sessionPath))
        guard let outer = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blob = outer[Self.tokenKey] as? String,
              let inner = blob.data(using: .utf8) else {
            throw TranscriberError.notSignedIn
        }
        return try JSONDecoder().decode(Session.self, from: inner)
    }

    private func refresh(_ refreshToken: String) async throws -> Session {
        try Incognito.check(.network("Wispr Flow"))
        var req = URLRequest(url: URL(string: "\(Self.supabaseURL)/auth/v1/token?grant_type=refresh_token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(Self.anonKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        // Bound the refresh itself rather than relying on the caller to cancel it.
        // Coalesced callers wait on a shared unstructured Task, and `await
        // task.value` does not carry their cancellation into it — so on a captive
        // portal this request, not the caller's deadline, is what decides how long
        // a dictation stalls before falling back. URLSession's 60 s default is far
        // too long for something on the dictation critical path.
        req.timeoutInterval = 10
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw TranscriberError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(Session.self, from: data)
    }
}
