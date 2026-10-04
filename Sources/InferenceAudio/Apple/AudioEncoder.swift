#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// AAC for recordings: a span of a recording encoded to an .m4a, streamed
/// from the segments ten seconds at a time, so memory stays flat however
/// long it is. 16 kHz mono speech at 32 kbps is about 14 MB per hour,
/// against about 115 MB of PCM.
public enum AudioEncoder {
    /// The content type of the .m4a files `encodeAAC` writes.
    public static let aacContentType = "audio/mp4"

    /// Encodes `range` (default: everything) of a recording to AAC at `dest`.
    public static func encodeAAC(store: RecordingStore, manifest: RecordingManifest, range: Range<Int64>? = nil,
                                 to dest: URL, bitRate: Int = 32_000) throws {
        let m = store.current(manifest)
        let range = range ?? 0..<m.totalSamples
        try? FileManager.default.removeItem(at: dest)
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(m.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: dest, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        } catch {
            // Some encoder builds reject an explicit bit rate at 16 kHz; let it pick.
            settings.removeValue(forKey: AVEncoderBitRateKey)
            file = try AVAudioFile(forWriting: dest, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        }
        let chunk = Int64(m.sampleRate) * 10
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk)),
              let channel = buffer.int16ChannelData?[0] else {
            throw AudioError.io("couldn't allocate an encode buffer")
        }
        try store.forEachChunk(m, range, chunkSamples: chunk) { data in
            let frames = data.count / SegmentWriter.bytesPerSample
            data.withUnsafeBytes { raw in
                UnsafeMutableRawPointer(channel).copyMemory(from: raw.baseAddress!, byteCount: frames * SegmentWriter.bytesPerSample)
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            try file.write(from: buffer)
        }
        if #available(macOS 15.0, iOS 18.0, watchOS 11.0, *) { file.close() }
    }

    /// Seconds of audio in a file AVAudioFile can read.
    public static func duration(of url: URL) throws -> TimeInterval {
        let f = try AVAudioFile(forReading: url)
        return Double(f.length) / f.fileFormat.sampleRate
    }
}
#endif
