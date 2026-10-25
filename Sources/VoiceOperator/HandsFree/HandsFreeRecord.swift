import Foundation

/// The record of what hands-free heard and decided, kept for review: every
/// trigger-word and words check (what Apple's model heard, and whether it
/// counted), every Smart Turn verdict, every dictation's outcome, and the
/// engine's own events — each with its time, and checks and verdicts with the
/// audio they were decided on.
///
/// `hands-free/decisions.jsonl` in Application Support holds one JSON object
/// per line. Its `clip` names a WAV in `hands-free/clips/` (16 kHz mono): the
/// clip checked for the trigger word, or the eight seconds Smart Turn heard.
/// Clips are pruned to the newest `maxClips`; the lines are kept.
///
/// This is the one place hands-free keeps what was said, on purpose — so a
/// "Control" heard as "patrol", or a finished sentence Smart Turn called
/// unfinished, can be found and listened to afterwards. Spaceterm kept the same
/// record in `~/.spaceterm/voice-decisions.jsonl` before hands-free moved here.
/// Incognito mode writes none of it.
final class HandsFreeRecord: @unchecked Sendable {
    static let shared = HandsFreeRecord(directory: HistoryStore.supportDir.appendingPathComponent("hands-free"))
    static let maxClips = 400
    static let incognitoActivity = Incognito.Activity.persist("hands-free record")

    private let directory: URL
    private var clips: URL { directory.appendingPathComponent("clips") }
    private let queue = DispatchQueue(label: "com.voiceop.hands-free-record")
    /// Touched only on `queue`.
    private var clipCount: Int?

    init(directory: URL) { self.directory = directory }

    /// One line, with `clip` (16 kHz s16le) kept beside it if given.
    func write(_ kind: String, _ detail: [String: Any], clip: Data? = nil, label: String? = nil, now: Date = Date()) {
        guard Incognito.refusal(Self.incognitoActivity) == nil else { return }
        queue.async { [self] in
            var line = detail
            line["t"] = ISO8601DateFormatter.withFractions.string(from: now)
            line["kind"] = kind
            if let clip, !clip.isEmpty {
                line["clip"] = keep(clip, label: label ?? kind, now: now)
                line["clipMs"] = clip.count / 32
            }
            guard JSONSerialization.isValidJSONObject(line),
                  var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
            data.append(0x0A)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent("decisions.jsonl")
                if let handle = try? FileHandle(forWritingTo: file) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: file)
                }
            } catch {
                Log.log("hands-free: could not write the record: \(error)")
            }
        }
    }

    /// **queue only.**
    private func keep(_ pcm: Data, label: String, now: Date) -> String? {
        let stamp = ISO8601DateFormatter.withFractions.string(from: now)
            .replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-")
        let name = "\(stamp)-\(label).wav"
        do {
            try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
            try WAVFile(sampleRate: 16_000, samples: pcm).data.write(to: clips.appendingPathComponent(name))
            let count = (clipCount ?? (existingClips().count - 1)) + 1
            clipCount = count
            if count > Self.maxClips {
                // Names start with the time, so the oldest sort first.
                let all = existingClips().sorted()
                for old in all.prefix(max(0, all.count - Self.maxClips)) {
                    try? FileManager.default.removeItem(at: clips.appendingPathComponent(old))
                }
                clipCount = min(all.count, Self.maxClips)
            }
            return name
        } catch {
            Log.log("hands-free: could not keep a clip: \(error)")
            return nil
        }
    }

    private func existingClips() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: clips.path)) ?? []).filter { $0.hasSuffix(".wav") }
    }
}

extension ISO8601DateFormatter {
    /// `2026-10-24T19:13:45.688Z`.
    nonisolated(unsafe) static let withFractions: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
