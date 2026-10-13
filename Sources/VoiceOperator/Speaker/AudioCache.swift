import Foundation
import CryptoKit

/// On-disk cache of synthesized TTS WAVs, keyed by (text, voice). Lets us
/// replay any past utterance for free and re-cue instantly after a dictation
/// barge-in (DESIGN.md). Entries older than `ttl` are reaped.
struct AudioCache {
    /// Speech audio is what was said, so incognito mode keeps it off the disk.
    static let incognitoActivity = Incognito.Activity.persist("speech audio")

    let directory: URL
    let ttl: TimeInterval
    /// Folded into every key. The name the cache has always used, so entries
    /// made before custom servers were removed stay valid.
    private static let namespace = "kokoro-82m"

    init(ttl: TimeInterval = 24 * 60 * 60) {
        self.ttl = ttl
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("VoiceOperator/tts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Stable cache key for a text+voice pair (also
    /// the WAV filename stem).
    func key(text: String, voiceID: String) -> String {
        let digest = SHA256.hash(data: Data("\(Self.namespace)|\(voiceID)|\(text)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func url(text: String, voiceID: String) -> URL {
        directory.appendingPathComponent("\(key(text: text, voiceID: voiceID)).wav")
    }

    /// Whether a WAV is cached for this text+voice (no mtime side effect —
    /// suitable for a status check).
    func contains(text: String, voiceID: String) -> Bool {
        FileManager.default.fileExists(atPath: url(text: text, voiceID: voiceID).path)
    }

    /// Cached WAV for this text+voice, if present. Bumps mtime so active audio
    /// survives reaping (LRU-ish).
    func cached(text: String, voiceID: String) -> URL? {
        let u = url(text: text, voiceID: voiceID)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path)
        return u
    }

    /// Store WAV bytes and return the file URL.
    @discardableResult
    func store(_ data: Data, text: String, voiceID: String) throws -> URL {
        try Incognito.check(Self.incognitoActivity)
        let u = url(text: text, voiceID: voiceID)
        try data.write(to: u, options: .atomic)
        return u
    }

    /// Delete entries not modified within `ttl`.
    @discardableResult
    func reap(now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return 0 }
        var removed = 0
        for f in files {
            let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mod, now.timeIntervalSince(mod) > ttl {
                try? fm.removeItem(at: f); removed += 1
            }
        }
        return removed
    }
}
