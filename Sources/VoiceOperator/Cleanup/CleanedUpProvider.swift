import Foundation

/// A transcription provider with the on-device clean-up pass behind it: what the
/// wrapped provider recognises is passed through `DictationCleaner` before
/// anyone sees it. `TranscriptionProviders.primary` hands this out while
/// "Clean Up Transcripts" is on, so dictation, history retries and phone
/// dictation all get the same text.
///
/// The clean-up never costs the user their words: when it fails, the raw
/// transcript is returned and the trace says why.
struct CleanedUpProvider: TranscriptionProvider {
    let base: any TranscriptionProvider
    let cleaner: @Sendable () throws -> DictationCleaner

    init(base: any TranscriptionProvider,
         cleaner: @escaping @Sendable () throws -> DictationCleaner = { try DictationCleaner.bundled() }) {
        self.base = base
        self.cleaner = cleaner
    }

    var id: TranscriptionProviderID { base.id }
    var fallbackLabel: String { base.fallbackLabel }
    var retriesAfterLiveFailure: Bool { base.retriesAfterLiveFailure }

    func openSession(target: DictationTarget, trace: DictationTrace?) async throws -> any TranscriptionSession {
        Session(base: try await base.openSession(target: target, trace: trace), provider: self, trace: trace)
    }

    func transcribe(wavData: Data) async throws -> String {
        await cleanUp(try await base.transcribe(wavData: wavData), trace: nil)
    }

    func transcribeAfterLiveFailure(wavData: Data) async throws -> String {
        await cleanUp(try await base.transcribeAfterLiveFailure(wavData: wavData), trace: nil)
    }

    func prewarm() async -> String? { await base.prewarm() }

    /// The cleaned text, or `raw` unchanged when there is nothing to clean or
    /// the pass fails.
    func cleanUp(_ raw: String, trace: DictationTrace?) async -> String {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return raw }
        trace?.mark("cleanup-start")
        do {
            let cleaned = try await cleaner().clean(raw)
            trace?.mark("cleanup-done")
            trace?.note("cleanup \(raw.count)→\(cleaned.count) chars")
            return cleaned
        } catch {
            trace?.mark("cleanup-failed")
            trace?.note("cleanup failed, pasting raw: \(error.localizedDescription)")
            Log.log("cleanup: failed, pasting the raw transcript — \(error.localizedDescription)")
            return raw
        }
    }

    private struct Session: TranscriptionSession {
        let base: any TranscriptionSession
        let provider: CleanedUpProvider
        let trace: DictationTrace?

        func send(pcm: Data) async { await base.send(pcm: pcm) }
        func commit(pcm: Data) async throws -> String {
            await provider.cleanUp(try await base.commit(pcm: pcm), trace: trace)
        }
        func cancel() async { await base.cancel() }
    }
}
