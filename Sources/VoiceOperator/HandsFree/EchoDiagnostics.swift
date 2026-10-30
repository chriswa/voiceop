import Accelerate
import Foundation

/// One reply heard through the Mac's echo canceller (`MacEchoPath`), kept
/// whole so that what went wrong can be found afterwards: the microphone as it
/// came, the reference the canceller was fed (already `EchoCanceller.leadSeconds`
/// early), and what it let through. When the reply and its tail end, `report`
/// writes an `echo-path` line to hands-free's record with the three as clips
/// and what they say:
///
/// - `refCoveragePercent`: how much of the reply had a reference at all. Low,
///   and the tap or its timestamps are failing (`refHealth`).
/// - `micDb`, `outDb`, `erleDb`: how loud the echo was and how much the
///   canceller took off, over the frames where something was playing.
/// - `echoDelayMs`, `correlation`: where the echo sits against the reference
///   as fed. The filter covers 0…`tailMs`; outside it, nothing can be cancelled
///   and the timing is what to fix. A low correlation means the microphone did
///   not hear what the reference says was played.
///
/// Recorded only while the echo experiment is on, the Mac's speakers are the
/// output and our voice plays; incognito writes none of it (`HandsFreeRecord`).
final class EchoDiagnostics {
    static let maxSeconds = 60.0
    static let frame = 320
    /// The cross-correlation's window and range: the loudest stretch of reference, lags −100…+500 ms.
    static let correlationSeconds = 8.0
    static let lagRangeMs = (-100.0, 500.0)

    private(set) var mic: [Int16] = []
    private(set) var reference: [Int16] = []
    private(set) var out: [Int16] = []
    let startedAt = Date()

    var full: Bool { Double(mic.count) >= Self.maxSeconds * EchoReference.sampleRate }

    func add(mic: [Int16], reference: [Int16], out: [Int16]) {
        guard !full else { return }
        self.mic += mic
        self.reference += reference
        self.out += out
    }

    /// Analyse and write it, off the caller's queue.
    func report(health: EchoReference.Health, resets: Int, output: String, record: HandsFreeRecord = .shared) {
        let mic = self.mic, reference = self.reference, out = self.out, startedAt = self.startedAt
        DispatchQueue.global(qos: .utility).async {
            var detail = Self.analyse(mic: mic, reference: reference, out: out)
            let id = ISO8601DateFormatter.withFractions.string(from: startedAt)
            detail["id"] = id
            detail["startedAt"] = id
            detail["output"] = output
            detail["resets"] = resets
            detail["leadMs"] = Int(EchoCanceller.leadSeconds * 1000)
            detail["tailMs"] = EchoCanceller.tailSamples * 1000 / 16_000
            var refHealth: [String: Any] = ["taps": health.taps, "buffers": health.buffers, "noHostTime": health.noHostTime]
            if let ahead = health.lastAheadMs { refHealth["lastAheadMs"] = ahead }
            if let latency = health.latencyMs { refHealth["latencyMs"] = latency }
            if let format = health.format { refHealth["format"] = format }
            detail["refHealth"] = refHealth
            record.write("echo-path", detail, clip: HandsFreeService.data(mic), label: "echo-mic")
            record.write("echo-clip", ["of": id, "what": "reference"], clip: HandsFreeService.data(reference), label: "echo-ref")
            record.write("echo-clip", ["of": id, "what": "cancelled"], clip: HandsFreeService.data(out), label: "echo-out")
            Log.log("hands-free: echo path for a reply: " + ["seconds", "refCoveragePercent", "micDb", "outDb", "erleDb",
                                                             "echoDelayMs", "correlation"]
                .compactMap { key in detail[key].map { "\(key)=\($0)" } }.joined(separator: " "))
        }
    }

    static func analyse(mic: [Int16], reference: [Int16], out: [Int16]) -> [String: Any] {
        let n = min(mic.count, reference.count)
        var detail: [String: Any] = ["seconds": (Double(n) / EchoReference.sampleRate * 10).rounded() / 10]
        guard n >= frame else { return detail }
        // Frame by frame: where something was playing, and how loud each was there.
        var active = 0, frames = 0
        var micActive = 0.0, refActive = 0.0, outActive = 0.0
        var at = 0
        while at + frame <= n {
            frames += 1
            let r = meanSquare(reference[at..<at + frame])
            if 10 * log10(r + 1e-12) > -60 {
                active += 1
                micActive += meanSquare(mic[at..<at + frame])
                refActive += r
                if at + frame <= out.count { outActive += meanSquare(out[at..<at + frame]) }
            }
            at += frame
        }
        detail["refCoveragePercent"] = 100 * active / max(1, frames)
        if active > 0 {
            let db = { (x: Double) in rounded(10 * log10(x / Double(active) + 1e-12)) }
            detail["micDb"] = db(micActive)
            detail["refDb"] = db(refActive)
            detail["outDb"] = db(outActive)
            detail["erleDb"] = rounded(10 * log10((micActive + 1e-12) / (outActive + 1e-12)))
        }
        if let (lagMs, correlation) = delay(mic: Array(mic.prefix(n)), reference: Array(reference.prefix(n))) {
            detail["echoDelayMs"] = lagMs
            detail["correlation"] = correlation
        }
        return detail
    }

    /// Where the microphone best matches the reference: the lag (ms, the echo
    /// after the reference) and its normalised correlation, over the
    /// `correlationSeconds` with the most reference, at 8 kHz.
    static func delay(mic: [Int16], reference: [Int16]) -> (Double, Double)? {
        // 8 kHz: each pair of samples averaged.
        func half(_ x: [Int16]) -> [Float] {
            stride(from: 0, to: x.count - 1, by: 2).map { (Float(x[$0]) + Float(x[$0 + 1])) / 65536 }
        }
        let m = half(mic), r = half(reference)
        let rate = 8_000.0
        let window = min(m.count, Int(correlationSeconds * rate))
        let minLag = Int(lagRangeMs.0 / 1000 * rate), maxLag = Int(lagRangeMs.1 / 1000 * rate)
        guard window > maxLag - minLag else { return nil }
        // The loudest stretch of reference, in steps of a quarter second.
        let step = Int(rate / 4)
        var best = 0, bestEnergy: Float = -1
        var start = max(0, -minLag)
        while start + window + max(0, maxLag) <= m.count, start + window <= r.count {
            var e: Float = 0
            r.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + start, 1, &e, vDSP_Length(window)) }
            if e > bestEnergy { bestEnergy = e; best = start }
            start += step
        }
        guard bestEnergy > 0 else { return nil }
        var refEnergy: Float = 0
        r.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + best, 1, &refEnergy, vDSP_Length(window)) }
        var top: Float = -2, topLag = 0
        for lag in minLag...maxLag {
            let from = best + lag
            guard from >= 0, from + window <= m.count else { continue }
            var dot: Float = 0, micEnergy: Float = 0
            m.withUnsafeBufferPointer { mp in
                r.withUnsafeBufferPointer { rp in
                    vDSP_dotpr(mp.baseAddress! + from, 1, rp.baseAddress! + best, 1, &dot, vDSP_Length(window))
                }
                vDSP_svesq(mp.baseAddress! + from, 1, &micEnergy, vDSP_Length(window))
            }
            let c = dot / max(1e-12, (micEnergy * refEnergy).squareRoot())
            if c > top { top = c; topLag = lag }
        }
        return (Double(topLag) / rate * 1000, (Double(top) * 100).rounded() / 100)
    }

    private static func meanSquare(_ x: ArraySlice<Int16>) -> Double {
        x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count) / (32768 * 32768)
    }

    private static func rounded(_ x: Double) -> Double { (x * 10).rounded() / 10 }
}
