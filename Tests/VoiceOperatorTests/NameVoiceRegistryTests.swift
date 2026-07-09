import XCTest
@testable import VoiceOperator

final class NameVoiceRegistryTests: XCTestCase {
    func testTableIsUniqueAndNonEmpty() {
        // The roster is empirically curated (ASR round-trip), so its size can
        // change; the invariants are non-empty + unique names. Voices are
        // intentionally shared (~3 names each), so voiceIDs are NOT unique — but
        // every voice in the pool must be used, and names must outnumber voices.
        let all = NameVoiceTable.all
        XCTAssertFalse(all.isEmpty)
        XCTAssertEqual(Set(all.map(\.name)).count, all.count, "names must be unique")
        XCTAssertGreaterThan(all.count, Set(all.map(\.voiceID)).count,
                             "names share voices, so names outnumber distinct voices")
    }

    func testPrefersDistinctVoicesUntilPoolExhausted() async {
        // With several names per voice, the registry should still give each of
        // the first N concurrent sessions a distinct voice (N = voice-pool size),
        // and only start reusing a voice once all of them are in play.
        let reg = NameVoiceRegistry(persisting: false)
        let voicePool = Set(NameVoiceTable.all.map(\.voiceID)).count
        var voices: [String] = []
        for i in 0..<voicePool {
            if let v = await reg.assign(NameVoiceRegistry.key(["claude": "s\(i)"])) {
                voices.append(v.voiceID)
            }
        }
        XCTAssertEqual(voices.count, voicePool, "one session assigned per voice")
        XCTAssertEqual(Set(voices).count, voicePool, "every early session gets a distinct voice")
        // One more session: all voices are active, so it must double up on a voice
        // already in use (while still getting a unique name — checked elsewhere).
        let extra = await reg.assign(NameVoiceRegistry.key(["claude": "extra"]))
        XCTAssertNotNil(extra)
        XCTAssertTrue(voices.contains(extra!.voiceID), "voice doubles up once the pool is exhausted")
    }

    func testStickyAssignment() async {
        let reg = NameVoiceRegistry(persisting: false)
        let key = NameVoiceRegistry.key(["claude": "abc"])
        let first = await reg.assign(key)
        let second = await reg.assign(key)
        XCTAssertEqual(first, second, "same key keeps its pair")
    }

    func testNoActiveNameReuseOrSoundAlikes() async {
        let reg = NameVoiceRegistry(persisting: false)
        var assigned: [String] = []
        for i in 0..<130 {
            if let v = await reg.assign(NameVoiceRegistry.key(["claude": "s\(i)"])) {
                assigned.append(v.name.lowercased())
            }
        }
        // No name reused while active.
        XCTAssertEqual(Set(assigned).count, assigned.count, "no active name reuse")
        // No two active names share a phonetic key (Willa/Ulla, Roman/Ramona).
        let keys = assigned.compactMap { NameAliases.phoneticKey[$0] }
        XCTAssertEqual(keys.count, assigned.count, "every name has a phonetic key")
        XCTAssertEqual(Set(keys).count, keys.count, "no sound-alike active names")
        // Concurrent capacity == number of distinct phonetic codes in the table.
        // (The Kokoro roster's names were chosen with all-distinct codes, so this
        // equals the table size; a future table with sound-alikes would be lower.)
        let capacity = Set(NameVoiceTable.all.compactMap { NameAliases.phoneticKey[$0.name.lowercased()] }).count
        XCTAssertEqual(assigned.count, capacity)
    }

    func testHomophoneResolvesToCanonical() async {
        // Roster-agnostic: fill the registry, then for every alias whose canonical
        // ended up active, confirm the alias resolves to that session.
        let reg = NameVoiceRegistry(persisting: false)
        var active: [String: String] = [:]   // canonical (lowercased) -> sessionId
        for i in 0..<200 {
            let sid = "c\(i)"
            if let v = await reg.assign(NameVoiceRegistry.key(["claude": sid])) {
                active[v.name.lowercased()] = sid
            }
        }
        // Canonical names always resolve to their own session.
        for (canonical, sid) in active {
            let r = await reg.claudeSession(forName: canonical)
            XCTAssertEqual(r, sid, "canonical '\(canonical)' resolves")
        }
        // Every alias whose canonical is active resolves to it.
        var exercisedAlias = false
        for (alias, canonical) in NameAliases.aliasToCanonical {
            guard let sid = active[canonical] else { continue }
            let r = await reg.claudeSession(forName: alias)
            XCTAssertEqual(r, sid, "alias '\(alias)' → \(canonical)")
            exercisedAlias = true
        }
        XCTAssertTrue(exercisedAlias, "expected at least one active name to have an alias")
    }

    func testIdleReapFreesPair() async {
        let reg = NameVoiceRegistry(persisting: false)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let key = NameVoiceRegistry.key(["claude": "x"])
        _ = await reg.assign(key, now: t0)
        let reaped = await reg.reapIdle(ttl: 60, now: t0.addingTimeInterval(120))
        XCTAssertEqual(reaped, 1)
        let count = await reg.activeCount
        XCTAssertEqual(count, 0)
    }

    // MARK: - session→name snapshot + change broadcast

    func testSnapshotMapsClaudeSessionToName() async {
        let reg = NameVoiceRegistry(persisting: false)
        let sid = "sess-1"
        let v = await reg.assign(NameVoiceRegistry.key(["claude": sid]))
        let snap = await reg.snapshot()
        XCTAssertEqual(snap[sid], v?.name, "snapshot maps session id → assigned name")
        XCTAssertEqual(snap.count, 1)
    }

    /// A `@Sendable` sink is needed because `setOnChange` takes a `@Sendable`
    /// closure. The registry fires `onChange` *synchronously* inside its actor
    /// methods, so this records synchronously under a lock — every emission is
    /// visible the instant the awaited mutating call returns. (An `actor` sink
    /// would force the synchronous handler to fire-and-forget a `Task`, leaving
    /// the test to guess how many `Task.yield()`s drain them — the old flake.)
    private final class Emissions: @unchecked Sendable {
        private let lock = NSLock()
        private var maps: [[String: String]] = []
        func record(_ m: [String: String]) { lock.withLock { maps.append(m) } }
        var count: Int { lock.withLock { maps.count } }
        var last: [String: String]? { lock.withLock { maps.last } }
    }

    func testSetOnChangeEmitsImmediately() async {
        let reg = NameVoiceRegistry(persisting: false)
        _ = await reg.assign(NameVoiceRegistry.key(["claude": "s"]))
        let sink = Emissions()
        await reg.setOnChange { m in sink.record(m) }
        // The immediate emit is the persisted-map (restart) broadcast.
        XCTAssertEqual(sink.last?.count, 1, "setOnChange broadcasts the current map at once")
    }

    func testAssignAndReapEmitButTouchDoesNot() async {
        let reg = NameVoiceRegistry(persisting: false)
        let sink = Emissions()
        await reg.setOnChange { m in sink.record(m) }   // emit #1 (empty)

        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let key = NameVoiceRegistry.key(["claude": "s"])
        _ = await reg.assign(key, now: t0)                            // emit #2 (new entry)
        _ = await reg.assign(key, now: t0)                            // no emit (already present)
        await reg.touch(key, now: t0)                                 // no emit (name unchanged)
        _ = await reg.reapIdle(ttl: 60, now: t0.addingTimeInterval(120))  // emit #3 (removed)

        XCTAssertEqual(sink.count, 3, "emits on set + assign + reap; not on re-assign or touch")
        XCTAssertEqual(sink.last?.isEmpty, true, "final map is empty after reap")
    }
}
