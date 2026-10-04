import Foundation

/// Mono 16-bit PCM from one sample rate to another, in pieces as they
/// arrive. Not thread-safe: one stream, one caller at a time.
public protocol PCMResampler: AnyObject {
    var inputRate: Int { get }
    var outputRate: Int { get }
    /// The next piece, converted. A resampler may hold a few samples back
    /// until the next piece or `flush`.
    func process(_ pcm: Data) -> Data
    /// The samples held back. The resampler starts over afterwards.
    func flush() -> Data
}

/// The best resampler on this platform: AVAudioConverter where AVFoundation
/// is (`ConverterResampler`), `LinearResampler` elsewhere. The same rate
/// passes through untouched either way.
public func makeResampler(from inputRate: Int, to outputRate: Int) -> any PCMResampler {
    #if canImport(AVFoundation)
    if inputRate != outputRate, let converter = ConverterResampler(from: inputRate, to: outputRate) {
        return converter
    }
    #endif
    return LinearResampler(from: inputRate, to: outputRate)
}

/// Linear interpolation between neighbouring samples. Plenty for speech
/// going up (16 kHz → 24 kHz); going down it does not filter first, so
/// content above the new Nyquist frequency folds back. Use it where
/// AVAudioConverter is not available.
public final class LinearResampler: PCMResampler {
    public let inputRate: Int
    public let outputRate: Int
    /// Input samples per output sample.
    private let step: Double
    /// The last sample of the previous piece: index 0 of the next one.
    private var history: Int16?
    /// Where the next output sample falls, in input samples from `history`
    /// (or from the first sample when there is none yet).
    private var position: Double = 0

    public init(from inputRate: Int, to outputRate: Int) {
        self.inputRate = max(1, inputRate)
        self.outputRate = max(1, outputRate)
        step = Double(self.inputRate) / Double(self.outputRate)
    }

    public func process(_ pcm: Data) -> Data {
        guard inputRate != outputRate else { return pcm }
        var input = PCM16.samples(pcm)
        guard !input.isEmpty else { return Data() }
        if let history { input.insert(history, at: 0) }
        var out: [Int16] = []
        out.reserveCapacity(Int(Double(input.count) / step) + 1)
        let last = input.count - 1
        while position < Double(last) {
            let i = Int(position)
            let frac = position - Double(i)
            let a = Double(input[i]), b = Double(input[i + 1])
            out.append(Int16(clamping: Int((a + (b - a) * frac).rounded())))
            position += step
        }
        // The last sample opens the next piece.
        position -= Double(last)
        history = input[last]
        return PCM16.data(out)
    }

    public func flush() -> Data {
        guard inputRate != outputRate, let history else { reset(); return Data() }
        // Positions between the last sample and where the next would be.
        var out: [Int16] = []
        while position < 1 {
            out.append(history)
            position += step
        }
        reset()
        return PCM16.data(out)
    }

    private func reset() {
        history = nil
        position = 0
    }
}
