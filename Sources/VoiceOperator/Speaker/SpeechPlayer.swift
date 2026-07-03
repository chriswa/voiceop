import AVFoundation

/// Plays a WAV file and lets the caller `await` its completion. `halt()` stops
/// playback immediately (barge-in) and the awaiting `play` returns `false`;
/// natural completion returns `true`.
@MainActor
final class SpeechPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Bool, Never>?

    /// Play `url`, resolving `true` on natural finish or `false` if halted/failed.
    func play(url: URL) async -> Bool {
        halt()  // pre-empt anything currently playing
        return await withCheckedContinuation { cont in
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.delegate = self
                player = p
                continuation = cont
                if !p.play() { finish(false) }
            } catch {
                cont.resume(returning: false)
            }
        }
    }

    func halt() {
        player?.stop()
        player = nil
        finish(false)
    }

    private func finish(_ ok: Bool) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(returning: ok)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            self.finish(flag)
        }
    }
}
