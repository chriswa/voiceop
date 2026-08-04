import Foundation

/// Reads (and refreshes) the Wispr Flow Supabase access token — approach "A"
/// from DESIGN.md. We lift the token Wispr already stored rather than
/// reimplementing its login. The token is read from Wispr's own session.json at
/// runtime and held only in memory; it is never written to our own storage.
///
/// Supabase auth is a standard protocol, so refresh works headlessly using the
/// public anon key embedded in Wispr's bundle.
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

    private struct Session: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_at: Double
    }

    /// The most recently obtained session, held in memory only. Without this the
    /// refreshed token was thrown away after every call: `session.json` on disk is
    /// only rewritten by the Wispr Flow app, and that app has been retired here,
    /// so the file is permanently stale and *every* dictation paid a full Supabase
    /// round trip on the critical path before any audio could be sent.
    private var cached: Session?

    /// A currently-valid access token, refreshing via Supabase if within 60s of
    /// expiry. Throws if Wispr has never been signed in on this machine.
    func accessToken() async throws -> String {
        if let cached, !Self.isExpiring(cached) { return cached.access_token }

        // If Wispr Flow is running it keeps `session.json` fresh; use its token
        // rather than rotating a second refresh chain against the same account.
        let onDisk = try? loadSession()
        if let onDisk, !Self.isExpiring(onDisk) {
            cached = onDisk
            return onDisk.access_token
        }

        // Otherwise refresh ourselves, preferring the token we were last issued
        // over the one on disk: Supabase rotates refresh tokens, so once we have
        // refreshed, the copy in the file is spent. Falling back to `cached` also
        // keeps dictation alive when the file is gone entirely — Wispr Flow has
        // been retired here, so that is the expected steady state, and throwing
        // would break dictation permanently an hour after launch.
        guard let basis = cached ?? onDisk else { throw TranscriberError.notSignedIn }
        let session = try await coalescedRefresh(basis.refresh_token)
        cached = session
        return session.access_token
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

    private func loadSession() throws -> Session {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.sessionPath))
        guard let outer = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blob = outer[Self.tokenKey] as? String,
              let inner = blob.data(using: .utf8) else {
            throw TranscriberError.notSignedIn
        }
        return try JSONDecoder().decode(Session.self, from: inner)
    }

    private func refresh(_ refreshToken: String) async throws -> Session {
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
