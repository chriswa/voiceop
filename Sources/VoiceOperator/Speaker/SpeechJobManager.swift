import Foundation

/// Sentence-aware, FIFO speech queue used by the local HTTP service and the
/// explicit Speak Clipboard action. Jobs acknowledge only complete sentences.
actor SpeechJobManager {
    static let shared = SpeechJobManager()

    enum State: String, Codable { case queued, waitingForUser = "waiting_for_user", speaking, completed, interruptedByUser = "interrupted_by_user", cancelledByClient = "cancelled_by_client", synthesisFailed = "synthesis_failed" }
    struct Result: Codable, Sendable {
        let id: String
        let state: State
        let characterOffset: Int
        let error: String?
    }
    private struct Segment: Sendable { let text: String; let end: Int }
    private struct Job: Sendable { let id: String; let voice: String; let segments: [Segment]; var next = 0; var state: State = .queued; var local = false }

    private var jobs: [String: Job] = [:]
    private var order: [String] = []
    private var current: String?
    private var dictating = false
    private var muted = false
    private var configured = false
    private var play: (@Sendable (String, String) async -> Bool)?
    private var prefetch: (@Sendable (String, String) -> Void)?
    private var halt: (@Sendable () -> Void)?
    private var waiters: [String: [CheckedContinuation<Result, Never>]] = [:]

    func configure(play: @escaping @Sendable (String, String) async -> Bool,
                   prefetch: @escaping @Sendable (String, String) -> Void,
                   halt: @escaping @Sendable () -> Void) {
        self.play = play; self.prefetch = prefetch; self.halt = halt; configured = true; pump()
    }

    func enqueue(text: String, voice: String, local: Bool = false) -> Result? {
        guard !muted else { return Result(id: "", state: .cancelledByClient, characterOffset: 0, error: "speech_muted") }
        let segments = Self.segments(text)
        guard !segments.isEmpty else { return Result(id: "", state: .synthesisFailed, characterOffset: 0, error: "empty_text") }
        let id = "sp_" + UUID().uuidString.lowercased()
        jobs[id] = Job(id: id, voice: voice, segments: segments, local: local)
        order.append(id); pump()
        return Result(id: id, state: .queued, characterOffset: 0, error: nil)
    }

    nonisolated func enqueueLocal(text: String) { Task { _ = await self.enqueue(text: text, voice: "af_heart", local: true) } }

    func result(id: String) -> Result? { jobs[id].map(result) }
    func wait(id: String, seconds: UInt64) async -> Result? {
        guard let job = jobs[id] else { return nil }
        if terminal(job.state) { return result(job) }
        return await withTaskGroup(of: Result?.self) { group in
            group.addTask { await self.waitForChange(id: id) }
            group.addTask { try? await Task.sleep(for: .seconds(Double(seconds))); return nil }
            let first = await group.next()!
            group.cancelAll()
            if let first { return first }
            return await self.result(id: id)
        }
    }
    private func waitForChange(id: String) async -> Result? {
        await withCheckedContinuation { cont in waiters[id, default: []].append(cont) }
    }

    func beginDictation() { dictating = true; interruptCurrent(state: .interruptedByUser) }
    func endDictation() { dictating = false; pump() }
    func cancel(id: String) -> Result? {
        guard var job = jobs[id] else { return nil }
        guard !terminal(job.state) else { return result(job) }
        if current == id { interruptCurrent(state: .cancelledByClient) }
        else { job.state = .cancelledByClient; jobs[id] = job; order.removeAll { $0 == id }; signal(job) }
        return jobs[id].map(result)
    }
    func setMuted(_ on: Bool) {
        muted = on
        guard on else { pump(); return }
        interruptCurrent(state: .cancelledByClient)
        for id in order where id != current {
            guard var job = jobs[id], !terminal(job.state) else { continue }
            job.state = .cancelledByClient; jobs[id] = job; signal(job)
        }
        order.removeAll { $0 != current }
    }

    private func pump() {
        guard configured, !dictating, !muted, current == nil, let play else { return }
        while let id = order.first {
            guard var job = jobs[id] else { order.removeFirst(); continue }
            if terminal(job.state) { order.removeFirst(); continue }
            guard job.next < job.segments.count else { job.state = .completed; jobs[id] = job; order.removeFirst(); signal(job); continue }
            current = id; job.state = .speaking; jobs[id] = job; signal(job)
            let segment = job.segments[job.next]
            if let prefetch {
                for index in (job.next + 1)..<min(job.segments.count, job.next + 3) {
                    prefetch(job.segments[index].text, job.voice)
                }
            }
            Task { [weak self] in
                let completed = await play(segment.text, job.voice)
                await self?.finishedSentence(id: id, completed: completed)
            }
            return
        }
    }
    private func finishedSentence(id: String, completed: Bool) {
        guard current == id, var job = jobs[id] else { return }
        current = nil
        if !completed {
            if !terminal(job.state) { job.state = .synthesisFailed; jobs[id] = job; order.removeAll { $0 == id }; signal(job) }
            pump(); return
        }
        job.next += 1
        if job.next == job.segments.count { job.state = .completed; order.removeAll { $0 == id } }
        else { job.state = dictating ? .waitingForUser : .queued }
        jobs[id] = job; signal(job); pump()
    }
    private func interruptCurrent(state: State) {
        guard let id = current, var job = jobs[id] else { return }
        job.state = state; jobs[id] = job; order.removeAll { $0 == id }; current = nil; halt?(); signal(job)
    }
    private func result(_ job: Job) -> Result {
        let offset = job.next == 0 ? 0 : job.segments[job.next - 1].end
        return Result(id: job.id, state: job.state, characterOffset: offset, error: job.state == .synthesisFailed ? "synthesis_failed" : nil)
    }
    private func signal(_ job: Job) { let r = result(job); let list = waiters.removeValue(forKey: job.id) ?? []; list.forEach { $0.resume(returning: r) } }
    private func terminal(_ s: State) -> Bool { [.completed, .interruptedByUser, .cancelledByClient, .synthesisFailed].contains(s) }

    /// Sentence ranges are based on Foundation's linguistic sentence boundary
    /// detector. Offsets count Unicode scalars in the original input.
    private static func segments(_ text: String) -> [Segment] {
        let ns = text as NSString
        var answer: [Segment] = []
        let tagger = NSLinguisticTagger(tagSchemes: [.tokenType], options: 0)
        tagger.string = text
        tagger.enumerateTags(in: NSRange(location: 0, length: ns.length), unit: .sentence, scheme: .tokenType, options: []) { _, range, _ in
            let part = ns.substring(with: range)
            guard !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let before = ns.substring(to: NSMaxRange(range))
            answer.append(Segment(text: part, end: before.unicodeScalars.count))
        }
        if answer.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { answer.append(Segment(text: text, end: text.unicodeScalars.count)) }
        return answer
    }
}
