import Foundation

/// A transcription provider with the on-device clean-up pass behind it: what the
/// wrapped provider recognises is passed through `DictationCleaner` before
/// anyone sees it. `TranscriptionProviders.primary` hands this out while
/// "Clean Up Transcripts" is on, so dictation, history retries and phone
/// dictation all get the same text.
///
/// The clean-up never costs the user their words: the result carries the raw
/// text beside the cleaned one (history keeps both), and when the pass fails the
/// raw transcript is what gets pasted, and the trace says why.
struct CleanedUpProvider: TranscriptionProvider {
    let base: any TranscriptionProvider
    /// The pass itself: raw text in, cleaned text out, or a throw.
    let clean: @Sendable (String) async throws -> String

    init(base: any TranscriptionProvider,
         clean: @escaping @Sendable (String) async throws -> String = { try await DictationCleaner.bundled().clean($0) }) {
        self.base = base
        self.clean = clean
    }

    var id: TranscriptionProviderID { base.id }
    var fallbackLabel: String { base.fallbackLabel }
    var retriesAfterLiveFailure: Bool { base.retriesAfterLiveFailure }

    func openSession(target: DictationTarget, trace: DictationTrace?) async throws -> any TranscriptionSession {
        Session(base: try await base.openSession(target: target, trace: trace), provider: self, trace: trace)
    }

    func transcribe(wavData: Data) async throws -> Transcript {
        await cleanUp(try await base.transcribe(wavData: wavData), trace: nil)
    }

    func transcribeAfterLiveFailure(wavData: Data) async throws -> Transcript {
        await cleanUp(try await base.transcribeAfterLiveFailure(wavData: wavData), trace: nil)
    }

    func prewarm() async -> String? { await base.prewarm() }

    /// The cleaned text with the recognised text beside it, or `recognized`
    /// unchanged when there is nothing to clean or the pass fails.
    func cleanUp(_ recognized: Transcript, trace: DictationTrace?) async -> Transcript {
        let raw = recognized.text
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return recognized }
        trace?.mark("cleanup-start")
        do {
            let cleaned = try await clean(raw)
            trace?.mark("cleanup-done")
            trace?.note("cleanup \(raw.count)→\(cleaned.count) chars")
            return Transcript(text: cleaned, raw: raw)
        } catch {
            trace?.mark("cleanup-failed")
            trace?.note("cleanup failed, pasting raw: \(error.localizedDescription)")
            Log.log("cleanup: failed, pasting the raw transcript — \(error.localizedDescription)")
            return recognized
        }
    }

    private struct Session: TranscriptionSession {
        let base: any TranscriptionSession
        let provider: CleanedUpProvider
        let trace: DictationTrace?

        func send(pcm: Data) async { await base.send(pcm: pcm) }
        func commit(pcm: Data) async throws -> Transcript {
            await provider.cleanUp(try await base.commit(pcm: pcm), trace: trace)
        }
        func cancel() async { await base.cancel() }
    }
}
