// 16-bit PCM, the format live functions carry (`audio/pcm;format=s16le`):
// signed 16-bit little-endian samples, channels interleaved. Mirrors the web
// app's src/lib/live/pcm.ts (floatToPCM16, pcm16ToFloat, peak).

import Foundation
import InferenceSDK

/// Conversions and levels for 16-bit little-endian PCM held in `Data`.
public enum PCM16 {
    /// Samples as -1...1 floats (divided by 32768, as the web player does).
    public static func toFloat(_ pcm: Data) -> [Float] {
        let count = pcm.count / 2
        return pcm.withUnsafeBytes { raw in
            (0..<count).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768 }
        }
    }

    /// Floats as 16-bit PCM, clamped to -1...1 (negative × 32768, positive × 32767).
    public static func fromFloat(_ samples: [Float]) -> Data {
        var out = [Int16](repeating: 0, count: samples.count)
        for i in samples.indices {
            let s = max(-1, min(1, samples[i]))
            out[i] = s < 0 ? Int16(s * 32768) : Int16(s * 32767)
        }
        return data(out)
    }

    /// The samples in `pcm` (an odd trailing byte is ignored).
    public static func samples(_ pcm: Data) -> [Int16] {
        let count = pcm.count / 2
        return pcm.withUnsafeBytes { raw in
            (0..<count).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) }
        }
    }

    /// Little-endian bytes for `samples`.
    public static func data(_ samples: [Int16]) -> Data {
        if 1.littleEndian == 1 { return samples.withUnsafeBufferPointer { Data(buffer: $0) } }
        return samples.map(\.littleEndian).withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// The loudest sample, 0...1.
    public static func peak(_ pcm: Data) -> Float {
        let count = pcm.count / 2
        guard count > 0 else { return 0 }
        var peak: Int = 0
        pcm.withUnsafeBytes { raw in
            for i in 0..<count {
                let v = abs(Int(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))))
                if v > peak { peak = v }
            }
        }
        return min(1, Float(peak) / 32768)
    }

    /// Root mean square level, 0...1.
    public static func rms(_ pcm: Data) -> Float {
        let count = pcm.count / 2
        guard count > 0 else { return 0 }
        var sum: Double = 0
        pcm.withUnsafeBytes { raw in
            for i in 0..<count {
                let s = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
                sum += s * s
            }
        }
        return Float((sum / Double(count)).squareRoot())
    }

    /// A level (RMS or peak) mapped to 0...1 for a meter: -50 dBFS and below
    /// is 0, -10 dBFS and above is 1.
    public static func meter(_ level: Float) -> Float {
        guard level > 0 else { return 0 }
        let db = 20 * log10(level)
        return max(0, min(1, (db + 50) / 40))
    }

    /// Mono samples repeated into `channels` interleaved channels.
    public static func upmix(_ mono: Data, channels: Int) -> Data {
        guard channels > 1 else { return mono }
        var out = Data(capacity: mono.count * channels)
        mono.withUnsafeBytes { raw in
            for i in 0..<(mono.count / 2) {
                let b0 = raw[i * 2], b1 = raw[i * 2 + 1]
                for _ in 0..<channels { out.append(b0); out.append(b1) }
            }
        }
        return out
    }

    /// Interleaved channels averaged into one.
    public static func downmix(_ pcm: Data, channels: Int) -> Data {
        guard channels > 1 else { return pcm }
        let all = samples(pcm)
        let frames = all.count / channels
        var out = [Int16](repeating: 0, count: frames)
        for f in 0..<frames {
            var sum = 0
            for c in 0..<channels { sum += Int(all[f * channels + c]) }
            out[f] = Int16(clamping: sum / channels)
        }
        return data(out)
    }
}

public extension PCMFormat {
    /// 16 kHz mono: what speech apps and Bluetooth HFP use, and what
    /// `Microphone`'s recorder writes.
    static let speech = PCMFormat(sampleRate: 16_000, channels: 1)

    /// Bytes of one sample frame (every channel).
    var bytesPerFrame: Int { 2 * channels }

    /// Bytes of one second of audio.
    var bytesPerSecond: Int { sampleRate * bytesPerFrame }

    /// Seconds of audio in `bytes`.
    func duration(ofBytes bytes: Int) -> TimeInterval {
        bytesPerSecond > 0 ? TimeInterval(bytes) / TimeInterval(bytesPerSecond) : 0
    }
}
