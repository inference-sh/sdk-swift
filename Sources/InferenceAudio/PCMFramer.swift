import Foundation
import InferenceSDK

/// Cuts a PCM byte stream into fixed frames (20 ms by default), keeping the
/// remainder for the next piece. A live function takes its audio in frames
/// like these; 20 ms is what the web app and the SDK examples send.
public struct PCMFramer: Sendable {
    /// Bytes per frame: `milliseconds` of whole sample frames.
    public let bytesPerFrame: Int
    private var pending = Data()

    public init(format: PCMFormat, milliseconds: Int = 20) {
        bytesPerFrame = max(format.bytesPerFrame, format.sampleRate * milliseconds / 1000 * format.bytesPerFrame)
    }

    /// The whole frames `pcm` completes, in order.
    public mutating func append(_ pcm: Data) -> [Data] {
        guard !pcm.isEmpty else { return [] }
        pending.append(pcm)
        var frames: [Data] = []
        var start = pending.startIndex
        while pending.endIndex - start >= bytesPerFrame {
            frames.append(pending.subdata(in: start..<start + bytesPerFrame))
            start += bytesPerFrame
        }
        pending = Data(pending[start...])
        return frames
    }

    /// The short last frame, if any; the framer is empty afterwards.
    public mutating func flush() -> Data? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : pending
    }

    /// Bytes waiting for the next frame.
    public var pendingBytes: Int { pending.count }
}
