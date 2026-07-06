import Foundation
import CryptoKit

/// Assigns a sticky (name, voice) pair to each Claude session and holds it for
/// the life of the session (DESIGN.md). Keyed by the full session-identity map
/// (claude session id, and later spaceterm id) so the same surface always keeps
/// the same call-sign and voice.
///
/// Rules:
///   • A key keeps its pair across calls (sticky).
///   • We avoid handing out a name or voice that is currently active.
///   • The starting slot is derived from a stable hash of the key, so a given
///     session tends to land on the same pair even across process restarts;
///     linear probing resolves collisions with other *active* sessions.
///   • Idle keys are released after a TTL (freeing the pair) — see `reapIdle`.
actor NameVoiceRegistry {
    private struct Entry: Codable { let voice: NamedVoice; var lastSeen: Date }
    private var byKey: [String: Entry] = [:]
    private let table = NameVoiceTable.all

    // MARK: - Persistence (name↔session mapping survives restarts)

    private static let version = 1
    private static var fileURL: URL { HistoryStore.supportDir.appendingPathComponent("registry.json") }
    private struct Persisted: Codable { var version: Int; var entries: [String: Entry] }

    private let persistenceEnabled: Bool

    /// `persisting: false` gives an isolated, disk-free registry for tests.
    init(persisting: Bool = true) {
        persistenceEnabled = persisting
        if persisting { byKey = Self.loadPersisted() }
    }

    /// Load persisted mappings, resetting each `lastSeen` to now so a restart
    /// gives every mapping a fresh idle-TTL window (an active session keeps its
    /// name; a truly-dead one is reaped after the TTL of post-restart silence).
    /// Entries whose pair is no longer in NameVoiceTable are dropped, so a
    /// table regeneration can't resurrect stale (name, voice) pairings.
    /// Failure-tolerant: any decode problem yields an empty registry.
    private static func loadPersisted() -> [String: Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        do {
            let p = try JSONDecoder().decode(Persisted.self, from: data)
            guard p.version == version else {
                Log.log("registry: ignoring incompatible version \(p.version)")
                return [:]
            }
            let now = Date()
            let current = p.entries.filter { NameVoiceTable.all.contains($0.value.voice) }
            if current.count != p.entries.count {
                Log.log("registry: dropped \(p.entries.count - current.count) entries not in current table")
            }
            return current.mapValues { Entry(voice: $0.voice, lastSeen: now) }
        } catch {
            Log.log("registry: could not load (\(error)); starting empty")
            return [:]
        }
    }

    private func persist() {
        guard persistenceEnabled,
              let data = try? JSONEncoder().encode(Persisted(version: Self.version, entries: byKey)) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    /// Build the canonical key from the identity map the caller tracks.
    /// Sorted so key order never matters.
    static func key(_ identity: [String: String]) -> String {
        identity.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
    }

    private func stableStartIndex(_ key: String) -> Int {
        let digest = SHA256.hash(data: Data(key.utf8))
        // First 8 bytes → UInt64, modulo table size.
        let n = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Int(n % UInt64(table.count))
    }

    /// Return this key's pair, assigning one on first use. `now` is injectable
    /// for testing. Returns nil only if every pair is currently active.
    func assign(_ key: String, now: Date = Date()) -> NamedVoice? {
        if var entry = byKey[key] {
            entry.lastSeen = now
            byKey[key] = entry
            return entry.voice
        }
        // Avoid reusing an active name *and* any name that sounds like an active
        // one (so a directed reply can't be ambiguous, e.g. Ember vs. Amber, or
        // our own Willa/Ulla, Roman/Ramona clusters).
        let activeNames = Set(byKey.values.map { $0.voice.name.lowercased() })
        let activePhonetic = Set(byKey.values.compactMap {
            NameAliases.phoneticKey[$0.voice.name.lowercased()]
        })
        let start = stableStartIndex(key)
        for offset in 0..<table.count {
            let candidate = table[(start + offset) % table.count]
            let lname = candidate.name.lowercased()
            if activeNames.contains(lname) { continue }
            if let pk = NameAliases.phoneticKey[lname], activePhonetic.contains(pk) { continue }
            byKey[key] = Entry(voice: candidate, lastSeen: now)
            persist()
            return candidate
        }
        return nil   // pool exhausted (more concurrent sessions than table pairs)
    }

    /// Refresh a key's last-seen time so an active session isn't reaped.
    func touch(_ key: String, now: Date = Date()) {
        byKey[key]?.lastSeen = now
    }

    /// Explicitly release a key's pair (for the future "release" event).
    func release(_ key: String) { byKey[key] = nil; persist() }

    /// Reverse lookup for directed replies: the Claude session id currently
    /// assigned to a given call-sign (case-insensitive), or nil. Extracts the
    /// `claude=<id>` component of the identity key.
    func claudeSession(forName name: String) -> String? {
        // Resolve a spoken/ASR homophone to its canonical call-sign first.
        let lower = name.lowercased()
        let target = NameAliases.aliasToCanonical[lower] ?? lower
        for (key, entry) in byKey where entry.voice.name.lowercased() == target {
            for pair in key.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2, kv[0] == "claude" { return String(kv[1]) }
            }
        }
        return nil
    }

    /// Drop keys idle longer than `ttl`, freeing their pairs.
    @discardableResult
    func reapIdle(ttl: TimeInterval, now: Date = Date()) -> Int {
        let stale = byKey.filter { now.timeIntervalSince($0.value.lastSeen) > ttl }.map(\.key)
        stale.forEach { byKey[$0] = nil }
        if !stale.isEmpty { persist() }
        return stale.count
    }

    var activeCount: Int { byKey.count }
}
