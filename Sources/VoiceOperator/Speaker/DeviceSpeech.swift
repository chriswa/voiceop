import Foundation

/// Speech for a device that plays it itself — a phone, through the iOS SDK
/// (`VoiceOperatorSpeech`) or any client speaking the same protocol — rather
/// than on this Mac's speakers. Moved here from Spaceterm's `RemoteSpeech`
/// (2026-10-25), so that every client gets it.
///
/// A job is split as the Mac's are (`SpeechJobManager.segments`: the same
/// sentences, the same offsets), made a sentence at a time (`RemoteSynthesis`)
/// and sent down the device's connection (`sentence`). The device says when
/// each sentence starts and finishes playing (`progress`), and from that this
/// answers in the Mac's own job format — `GET /v1/speech/{id}` with
/// `character_offset`, `DELETE` with `heard_until` — so a client follows speech
/// on a device exactly as it follows speech here.
///
/// Devices connect on the client socket (`HandsFreeService`, role `speaker`),
/// named by client and device; a job goes to one with `POST /v1/speech
/// {…, "client", "device"}`. Which device speech belongs on is the client's
/// call. The jobs are their own: not queued behind the Mac's speech, not
/// stopped by a dictation here, not silenced by the menu's mute. Each device's
/// jobs are made one after another, in the order they were asked for.
///
/// All state is confined to `queue`. DESIGN.md, "Speech on a device", has the
/// protocol.
final class DeviceSpeech: @unchecked Sendable {
    static let shared = DeviceSpeech()
    static let idPrefix = "ds_"
    static let incognitoActivity = Incognito.Activity.spaceterm("device speech")
    /// Finished jobs kept for a late status or stop; the oldest beyond this go.
    static let keepFinished = 32

    struct Deps: Sendable {
        /// One sentence's audio, timed; nil when it could not be made.
        var synthesize: @Sendable (_ text: String, _ voice: String) async -> RemoteSynthesis.Clip?
        /// Epoch ms: the Mac's clock, which `heard_until` is on.
        var now: @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }
        var log: @Sendable (String) -> Void = { Log.log($0) }
        var newID: @Sendable () -> String = { DeviceSpeech.idPrefix + UUID().uuidString.lowercased() }

        static let real = Deps(synthesize: { text, voice in
            do { return try await RemoteSynthesis.make(text: text, voice: voice, timed: true) } catch {
                Log.log("device speech: synthesis failed: \(error)")
                return nil
            }
        })
    }

    enum Speak: Sendable {
        case accepted(SpeechJobManager.Result)
        /// No device by that client and name is connected.
        case unknownDevice
        case refused(Incognito.Blocked)
    }

    typealias Result = SpeechJobManager.Result
    typealias State = SpeechJobManager.State

    let queue = DispatchQueue(label: "com.voiceop.device-speech")
    private let deps: Deps
    private var devices: [String: Device] = [:]
    private var jobs: [String: Job] = [:]
    /// Ended jobs, oldest first: kept for a late status or stop, up to `keepFinished`.
    private var ended: [String] = []
    /// Each device's synthesis, one job after another.
    private var lanes: [String: Task<Void, Never>] = [:]
    private var nextToken = 1
    private let busyLock = NSLock()
    private var busyCount = 0
    /// Called (on any thread) when the last job in progress ends: a restart waits for none.
    var onIdle: (@Sendable () -> Void)?

    init(deps: Deps = .real) { self.deps = deps }

    /// Whether a device is playing, or about to play, speech of ours — a restart waits.
    var isSpeaking: Bool { busyLock.withLock { busyCount > 0 } }

    static func owns(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    private struct Device {
        let token: Int
        let client: String
        let name: String
        let send: @Sendable ([String: Any]) -> Void
    }

    private struct Audio {
        let seconds: Double
        let words: [RemoteSynthesis.Word]?
    }

    private final class Job: @unchecked Sendable {
        let id: String
        let key: String
        let token: Int
        let segments: [SpeechJobManager.Segment]
        var state = State.inProgress
        var playback = SpeechJobManager.PlaybackState.queued
        /// What was heard: through the last sentence the device finished, and on a cut, into the
        /// one it was part way through — see `heardAt`.
        var offset = 0
        var audio: [Int: Audio] = [:]
        /// When the device said each sentence started (with its audio) and finished, by index: so
        /// what was heard can be told at any moment, not just now — a cut can be dated back.
        var started: [Int: (at: Double, audio: Audio)] = [:]
        var finished: [Int: Double] = [:]
        var version = 0
        var waiters: [Waiter] = []
        init(id: String, key: String, token: Int, segments: [SpeechJobManager.Segment]) {
            self.id = id
            self.key = key
            self.token = token
            self.segments = segments
        }
    }

    /// A parked status call: woken at any change past `since`, or without it at the end.
    private final class Waiter: @unchecked Sendable {
        let since: Int?
        private var resume: ((Result) -> Void)?
        init(since: Int?, resume: @escaping (Result) -> Void) {
            self.since = since
            self.resume = resume
        }
        func fire(_ result: Result) {
            resume?(result)
            resume = nil
        }
    }

    private static func key(client: String, device: String) -> String { "\(client)\u{0}\(device)" }

    // MARK: - Devices

    /// A device connected: `send` carries a message to it, from any thread. A device of the same
    /// client and name before it is replaced, and what it was playing stops where it got to.
    func connect(client: String, device: String, send: @escaping @Sendable ([String: Any]) -> Void) -> Int {
        queue.sync {
            let token = nextToken
            nextToken += 1
            let key = Self.key(client: client, device: device)
            if let old = devices[key] {
                old.send(["type": "replaced"])
                cutOff(token: old.token, why: "replaced")
            }
            devices[key] = Device(token: token, client: client, name: device, send: send)
            deps.log("device speech: \(client)'s \(device) connected")
            return token
        }
    }

    /// The device went: whatever it was playing has stopped where it got to.
    func disconnect(_ token: Int) {
        queue.async { [self] in
            guard let (key, device) = devices.first(where: { $0.value.token == token }) else { return }
            devices[key] = nil
            deps.log("device speech: \(device.client)'s \(device.name) disconnected")
            cutOff(token: token, why: "disconnected")
        }
    }

    /// The device's account of its playback: a sentence `started`, `finished`, or `failed`.
    func progress(_ token: Int, id: String, index: Int, event: String) {
        let at = deps.now()
        queue.async { [self] in
            guard let job = jobs[id], job.token == token, job.state == .inProgress,
                  job.segments.indices.contains(index) else { return }
            switch event {
            case "started":
                if let audio = job.audio[index] { job.started[index] = (at, audio) }
                if job.playback != .speaking { change(job) { $0.playback = .speaking } }
            case "finished":
                job.finished[index] = at
                change(job) { $0.offset = max($0.offset, $0.segments[index].end) }
                if index == job.segments.count - 1 { end(job, .completed) }
            case "failed":
                deps.log("device speech \(id): sentence \(index + 1)/\(job.segments.count) could not be played")
                end(job, .synthesisFailed)
            default:
                break
            }
        }
    }

    private func cutOff(token: Int, why: String) {
        let now = deps.now()
        for job in jobs.values where job.token == token && job.state == .inProgress {
            job.offset = heardAt(job, now)
            end(job, .cancelledByClient, why: why)
        }
    }

    // MARK: - Jobs

    func speak(parts: [SpeechJobManager.Part], client: String, device: String) async -> Speak {
        if let blocked = Incognito.refusal(Self.incognitoActivity) { return .refused(blocked) }
        let segments = SpeechJobManager.segments(parts)
        return await onQueue { [self] in
            let key = Self.key(client: client, device: device)
            guard let target = devices[key], !segments.isEmpty else { return .unknownDevice }
            let job = Job(id: deps.newID(), key: key, token: target.token, segments: segments)
            jobs[job.id] = job
            setBusy(+1)
            deps.log("device speech \(job.id): \(segments.count) sentence(s) for \(client)'s \(device)")
            let previous = lanes[key]
            lanes[key] = Task { [weak self] in
                await previous?.value
                await self?.pump(job.id)
            }
            return .accepted(result(job))
        }
    }

    /// A job's status; with `wait`, parked until it changes past `since`, or without `since`
    /// until it ends. Mid-speech, `character_offset` is where the voice is now, word by word.
    func status(id: String, wait: Double = 0, since: Int? = nil) async -> Result? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result?, Never>) in
            queue.async { [self] in
                guard let job = jobs[id] else { continuation.resume(returning: nil); return }
                guard wait > 0, !settled(job, since: since) else {
                    continuation.resume(returning: live(job))
                    return
                }
                let waiter = Waiter(since: since) { continuation.resume(returning: $0) }
                job.waiters.append(waiter)
                queue.asyncAfter(deadline: .now() + wait) { [self] in
                    job.waiters.removeAll { $0 === waiter }
                    waiter.fire(live(job))
                }
            }
        }
    }

    /// Stop a job. `heardUntil` (epoch ms): the listener stopped hearing it then, before now —
    /// they began talking over it, and the client decided to stop it only later.
    func cancel(id: String, heardUntil: Double? = nil) async -> Result? {
        await onQueue { [self] in
            guard let job = jobs[id] else { return nil }
            if job.state == .inProgress {
                let now = deps.now()
                let at = min(heardUntil ?? now, now)
                job.offset = heardAt(job, at)
                end(job, .cancelledByClient, why: at < now ? String(format: "cut %.1fs back", (now - at) / 1000) : "stopped")
            }
            return result(job)
        }
    }

    /// Make each sentence in turn and send it on; the device queues them.
    private func pump(_ id: String) async {
        for index in 0... {
            guard let (text, voice) = await onQueue({ [self] () -> (String, String)? in
                guard let job = jobs[id], job.state == .inProgress, job.segments.indices.contains(index) else { return nil }
                return (job.segments[index].text, job.segments[index].voice)
            }) else { return }
            let began = deps.now()
            let clip = await deps.synthesize(text, voice)
            guard await onQueue({ [self] in deliver(id, index, clip, synthMs: deps.now() - began) }) else { return }
        }
    }

    /// One sentence made: to the device, if the job still wants it. False when the job is over.
    private func deliver(_ id: String, _ index: Int, _ clip: RemoteSynthesis.Clip?, synthMs: Double) -> Bool {
        guard let job = jobs[id], job.state == .inProgress else { return false }
        guard let clip else {
            deps.log("device speech \(id): sentence \(index + 1)/\(job.segments.count) could not be made")
            end(job, .synthesisFailed)
            return false
        }
        // The words leave this process for the device, through its client.
        if Incognito.refusal(Self.incognitoActivity) != nil {
            end(job, .synthesisFailed, why: "incognito")
            return false
        }
        guard let device = devices[job.key], device.token == job.token else {
            end(job, .cancelledByClient, why: "device gone")
            return false
        }
        job.audio[index] = Audio(seconds: clip.wav.duration, words: clip.words)
        // For hands-free's echo experiment: what the device's microphone hears of this is not the user.
        RecentSpeech.shared.note(job.segments[index].text)
        device.send([
            "type": "sentence", "id": id, "index": index, "count": job.segments.count,
            "sampleRate": clip.wav.sampleRate, "pcm": clip.wav.samples.base64EncodedString(),
            "sentAt": deps.now(), "synthMs": Int(synthMs.rounded()),
        ])
        return true
    }

    /// How much of the job had been heard at `at`, without changing it.
    ///
    /// The device reports only sentence boundaries, and a sentence can run for
    /// seconds: counting only finished ones once told Spaceterm's receptionist
    /// the listener had heard none of a question they were already answering.
    /// So the time since the device said a sentence started is looked up in its
    /// word timings, by the rule for speech played here: a word counts once it
    /// has started, and the offset lands just past it.
    ///
    /// The clock is this Mac's, so it is off by however long the `started`
    /// report took to arrive, less however long the device keeps playing until
    /// a stop reaches it — both network hops on the same link, shorter than a
    /// word. Untimed audio counts nothing of its sentence rather than guess.
    private func heardAt(_ job: Job, _ at: Double) -> Int {
        var heard = 0
        for (index, finishedAt) in job.finished where finishedAt <= at {
            heard = max(heard, job.segments[index].end)
        }
        for (index, started) in job.started {
            let elapsed = (at - started.at) / 1000
            guard elapsed >= 0 else { continue }
            let segment = job.segments[index]
            if elapsed >= started.audio.seconds {
                heard = max(heard, segment.end)
            } else if let word = started.audio.words?.last(where: { $0.start <= elapsed }) {
                heard = max(heard, segment.start + min(word.characterEnd, (segment.text as NSString).length))
            }
        }
        return heard
    }

    private func end(_ job: Job, _ state: State, why: String? = nil) {
        change(job) { $0.state = state }
        setBusy(-1)
        ended.append(job.id)
        while ended.count > Self.keepFinished { jobs[ended.removeFirst()] = nil }
        deps.log("device speech \(job.id): \(state.rawValue)\(why.map { " (\($0))" } ?? ""), \(job.offset) chars heard")
        // To the device too, which stops playing it unless it is what finished.
        if let device = devices[job.key], device.token == job.token {
            device.send(["type": "ended", "id": job.id, "state": state.rawValue, "characterOffset": job.offset])
        }
    }

    /// The only way a job is written after it is made: bumps the version and wakes waiters.
    private func change(_ job: Job, _ apply: (Job) -> Void) {
        apply(job)
        job.version += 1
        let parked = job.waiters
        job.waiters = parked.filter { !ready($0, job) }
        for waiter in parked where ready(waiter, job) { waiter.fire(live(job)) }
    }

    private func ready(_ waiter: Waiter, _ job: Job) -> Bool {
        waiter.since.map { job.version > $0 } ?? (job.state != .inProgress)
    }

    private func settled(_ job: Job, since: Int?) -> Bool {
        job.state != .inProgress || since.map { job.version > $0 } == true
    }

    private func live(_ job: Job) -> Result {
        result(job, offset: job.state == .inProgress ? max(job.offset, heardAt(job, deps.now())) : job.offset)
    }

    private func result(_ job: Job, offset: Int? = nil) -> Result {
        Result(id: job.id, state: job.state, playbackState: job.state == .inProgress ? job.playback : nil,
               characterOffset: offset ?? job.offset, error: job.state == .synthesisFailed ? "synthesis_failed" : nil,
               version: job.version)
    }


    private func setBusy(_ delta: Int) {
        let idle: Bool = busyLock.withLock {
            busyCount = max(0, busyCount + delta)
            return delta < 0 && busyCount == 0
        }
        if idle { onIdle?() }
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }
}
