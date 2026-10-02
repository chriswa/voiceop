import AVFoundation
import Foundation

/// Streaming converter from s16le mono PCM at any common rate to the 16 kHz the
/// ASR path wants, for audio that arrives over the wire in arbitrary chunks
/// (remote transcription) rather than from the microphone tap.
///
/// One instance per stream: `AVAudioConverter`'s filter carries state across
/// calls, which is what keeps chunk boundaries inaudible, so it must see the
/// whole stream in order and be drained once with `flush()` at the end. At
/// 16 kHz it is a pass-through. Not thread-safe; the owner confines it.
final class PCM16Resampler {
    static let outputRate = Int(OpusEncoder.sampleRate)
    static let supportedInputRates = 8_000...192_000

    let inputRate: Int
    private let converter: AVAudioConverter?
    private let inputFormat: AVAudioFormat
    /// A chunk may end mid-sample; the odd byte waits for the next one.
    private var carry = Data()

    init?(inputRate: Int) {
        guard Self.supportedInputRates.contains(inputRate),
              let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(inputRate),
                                              channels: 1, interleaved: true) else { return nil }
        self.inputRate = inputRate
        self.inputFormat = inputFormat
        if inputRate == Self.outputRate {
            converter = nil
        } else {
            guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                   sampleRate: Double(Self.outputRate),
                                                   channels: 1, interleaved: true),
                  let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
            self.converter = converter
        }
    }

    /// Convert the next chunk. Returns whatever 16 kHz audio is ready; the
    /// converter may hold back a few samples of filter latency until later.
    func convert(_ chunk: Data) -> Data {
        var bytes = carry
        bytes.append(chunk)
        let whole = bytes.count & ~1
        carry = bytes.count == whole ? Data() : Data(bytes.suffix(1))
        guard whole > 0 else { return Data() }
        let samples = bytes.prefix(whole)
        guard converter != nil else { return Data(samples) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                            frameCapacity: AVAudioFrameCount(whole / 2)) else { return Data() }
        buffer.frameLength = AVAudioFrameCount(whole / 2)
        samples.withUnsafeBytes { raw in
            buffer.int16ChannelData![0].update(from: raw.bindMemory(to: Int16.self).baseAddress!, count: whole / 2)
        }
        return run(buffer)
    }

    /// Drain the converter's tail at end of stream. The instance is spent after.
    func flush() -> Data {
        carry = Data()
        guard converter != nil else { return Data() }
        return run(nil)
    }

    /// Mirrors `AudioRecorder.convertAndStoreLocked`: feed the one buffer (or
    /// end-of-stream), then drain until the converter stops filling output.
    private func run(_ buffer: AVAudioPCMBuffer?) -> Data {
        guard let converter else { return Data() }
        let input = Input(buffer)
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            guard let buffer = input.buffer else { status.pointee = .endOfStream; return nil }
            if input.fed { status.pointee = .noDataNow; return nil }
            input.fed = true
            status.pointee = .haveData
            return buffer
        }
        let inFrames = Double(buffer?.frameLength ?? 4096)
        let capacity = AVAudioFrameCount(inFrames * Double(Self.outputRate) / Double(inputRate)) + 64
        var out = Data()
        while true {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                               frameCapacity: capacity) else { return out }
            var error: NSError?
            let status = converter.convert(to: chunk, error: &error, withInputFrom: inputBlock)
            if let error { Log.log("resampler: conversion failed \(error)"); return out }
            if chunk.frameLength > 0, let channel = chunk.int16ChannelData {
                out.append(Data(bytes: channel[0], count: Int(chunk.frameLength) * 2))
            }
            if status != .haveData { return out }
        }
    }

    private final class Input: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer?
        var fed = false
        init(_ buffer: AVAudioPCMBuffer?) { self.buffer = buffer }
    }
}
