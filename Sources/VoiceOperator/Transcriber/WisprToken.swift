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

    /// A currently-valid access token, refreshing via Supabase if within 60s of
    /// expiry. Throws if Wispr has never been signed in on this machine.
    func accessToken() async throws -> String {
        var session = try loadSession()
        if Date().timeIntervalSince1970 > session.expires_at - 60 {
            session = try await refresh(session.refresh_token)
        }
        return session.access_token
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
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw TranscriberError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(Session.self, from: data)
    }
}
