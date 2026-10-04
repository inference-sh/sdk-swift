#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// Mono 16-bit PCM from one rate to another with AVAudioConverter, in pieces
/// as they arrive (filtered: no aliasing going down). `makeResampler` picks
/// it where AVFoundation is.
public final class ConverterResampler: PCMResampler {
    public let inputRate: Int
    public let outputRate: Int
    private let converter: AVAudioConverter
    private let inFormat: AVAudioFormat
    private let outFormat: AVAudioFormat

    /// Nil when AVAudioConverter cannot convert between the two rates.
    public init?(from inputRate: Int, to outputRate: Int) {
        guard let i = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(inputRate), channels: 1, interleaved: true),
              let o = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(outputRate), channels: 1, interleaved: true),
              let c = AVAudioConverter(from: i, to: o)
        else { return nil }
        c.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
        self.inputRate = inputRate
        self.outputRate = outputRate
        converter = c
        inFormat = i
        outFormat = o
    }

    public func process(_ pcm: Data) -> Data {
        run(pcm, end: false)
    }

    public func flush() -> Data {
        let out = run(Data(), end: true)
        converter.reset()
        return out
    }

    private func run(_ pcm: Data, end: Bool) -> Data {
        let frames = pcm.count / 2
        var input: AVAudioPCMBuffer?
        if frames > 0, let b = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(frames)),
           let channel = b.int16ChannelData?[0] {
            b.frameLength = AVAudioFrameCount(frames)
            pcm.withUnsafeBytes { raw in
                UnsafeMutableRawPointer(channel).copyMemory(from: raw.baseAddress!, byteCount: frames * 2)
            }
            input = b
        }
        if input == nil && !end { return Data() }
        var result = Data()
        var fed = false
        let capacity = AVAudioFrameCount(Double(max(frames, 512)) * Double(outputRate) / Double(inputRate) + 1024)
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { break }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, state in
                if !fed, let input {
                    fed = true
                    state.pointee = .haveData
                    return input
                }
                state.pointee = end ? .endOfStream : .noDataNow
                return nil
            }
            if out.frameLength > 0, let channel = out.int16ChannelData?[0] {
                result.append(Data(bytes: channel, count: Int(out.frameLength) * 2))
            }
            // A full output buffer: there may be more. Otherwise it gave all it can.
            if status == .haveData && out.frameLength == out.frameCapacity { continue }
            break
        }
        return result
    }
}
#endif
