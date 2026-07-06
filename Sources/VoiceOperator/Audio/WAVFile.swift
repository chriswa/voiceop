import Foundation

/// Minimal reader/writer for the app's canonical audio format: RIFF WAV holding
/// 16-bit little-endian mono PCM. Parsing walks the RIFF chunk list rather than
/// assuming a 44-byte header — `afconvert` (which produces our dictation WAVs)
/// inserts an `FLLR` padding chunk between `fmt ` and `data`.
struct WAVFile {
    let sampleRate: Int
    /// Raw s16le sample bytes (2 bytes per sample).
    let samples: Data

    enum WAVError: Error { case malformed, unsupportedFormat }

    init(sampleRate: Int, samples: Data) {
        self.sampleRate = sampleRate
        self.samples = samples
    }

    init(contentsOf url: URL) throws {
        self = try Self.parse(try Data(contentsOf: url))
    }

    var duration: Double { Double(samples.count / 2) / Double(sampleRate) }

    /// Split into consecutive segments of at most `maxSeconds` each, on a
    /// sample boundary. A clip shorter than `maxSeconds` yields one segment.
    func segments(maxSeconds: Double) -> [WAVFile] {
        let bytesPerSegment = max(2, Int(maxSeconds * Double(sampleRate)) * 2)
        var out: [WAVFile] = []
        var offset = 0
        while offset < samples.count {
            let end = min(offset + bytesPerSegment, samples.count)
            out.append(WAVFile(sampleRate: sampleRate, samples: samples.subdata(in: offset..<end)))
            offset = end
        }
        return out.isEmpty ? [self] : out
    }

    /// Serialize to a RIFF WAV blob (plain 44-byte header + sample data).
    var data: Data {
        var d = Data(capacity: 44 + samples.count)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + samples.count))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(samples.count))
        d.append(samples)
        return d
    }

    static func parse(_ data: Data) throws -> WAVFile {
        guard data.count >= 12,
              data[0..<4].elementsEqual("RIFF".utf8),
              data[8..<12].elementsEqual("WAVE".utf8) else { throw WAVError.malformed }

        var sampleRate: Int?
        var samples: Data?
        var offset = 12
        while offset + 8 <= data.count {
            let id = data[offset..<offset + 4]
            let size = Int(readU32(data, at: offset + 4))
            let body = offset + 8
            // Tolerate a truncated final chunk (clamp) but not a header overrun.
            let end = min(body + size, data.count)
            if id.elementsEqual("fmt ".utf8) {
                guard size >= 16, body + 16 <= data.count else { throw WAVError.malformed }
                let audioFormat = readU16(data, at: body)
                let channels = readU16(data, at: body + 2)
                let bits = readU16(data, at: body + 14)
                guard audioFormat == 1, channels == 1, bits == 16 else { throw WAVError.unsupportedFormat }
                sampleRate = Int(readU32(data, at: body + 4))
            } else if id.elementsEqual("data".utf8) {
                samples = data.subdata(in: body..<end)
            }
            offset = body + size + (size % 2)   // chunks are padded to even length
        }
        guard let sampleRate, let samples else { throw WAVError.malformed }
        return WAVFile(sampleRate: sampleRate, samples: samples)
    }

    private static func readU32(_ d: Data, at i: Int) -> UInt32 {
        UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
    }
    private static func readU16(_ d: Data, at i: Int) -> UInt16 {
        UInt16(d[i]) | UInt16(d[i + 1]) << 8
    }
}
