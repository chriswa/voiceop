import XCTest
@testable import VoiceOperator

final class NameVoiceRegistryTests: XCTestCase {
    func testTableIsUniqueAndNonEmpty() {
        // The roster is empirically curated (ASR round-trip), so its size can
        // change; the invariants are non-empty + unique names and voices.
        let all = NameVoiceTable.all
        XCTAssertFalse(all.isEmpty)
        XCTAssertEqual(Set(all.map(\.name)).count, all.count, "names must be unique")
        XCTAssertEqual(Set(all.map(\.voiceID)).count, all.count, "voices must be unique")
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
        // Concurrent capacity == number of distinct phonetic codes in the table
        // (100 names minus the two confusable-pair collisions = 98).
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
}
