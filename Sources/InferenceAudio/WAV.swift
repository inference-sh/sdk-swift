// WAV files: the header live capture writes, and a parser that reads the
// files Apple's recorders write while they are still being written.

import Foundation
import InferenceSDK

/// The sample format a WAV file's `fmt ` chunk declares.
public struct WAVFormat: Equatable, Sendable {
    public var sampleRate: Int
    public var channels: Int
    public var bitsPerSample: Int
    public var isFloat: Bool

    public init(sampleRate: Int, channels: Int, bitsPerSample: Int = 16, isFloat: Bool = false) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
        self.isFloat = isFloat
    }

    /// Bytes per sample frame (all channels).
    public var blockAlign: Int { channels * bitsPerSample / 8 }

    /// 16, 24 and 32-bit integer PCM and 32-bit float: what `WAVStreamParser` reads.
    public var isSupported: Bool {
        channels > 0 && sampleRate > 0 && (isFloat ? bitsPerSample == 32 : [16, 24, 32].contains(bitsPerSample))
    }
}

/// WAV headers and whole-file reading.
public enum WAV {
    /// The canonical 44-byte RIFF/WAVE header for 16-bit PCM.
    public static func header(dataBytes: Int, format: PCMFormat) -> Data {
        let blockAlign = format.bytesPerFrame
        var d = Data(capacity: 44)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(truncatingIfNeeded: 36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1)  // integer PCM
        u16(UInt16(format.channels))
        u32(UInt32(format.sampleRate))
        u32(UInt32(format.sampleRate * blockAlign))
        u16(UInt16(blockAlign))
        u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(truncatingIfNeeded: dataBytes))
        return d
    }

    /// Byte offset of the data chunk's size field in `header(dataBytes:format:)`.
    static let canonicalDataSizeOffset = 40

    /// 16-bit PCM wrapped in a WAV header: a file `SpeechToText.transcribe` takes.
    public static func wrap(_ pcm: Data, format: PCMFormat = .speech) -> Data {
        header(dataBytes: pcm.count, format: format) + pcm
    }

    /// A whole WAV file's audio as mono 16-bit PCM at the file's rate, and
    /// the format the file declares. Reads 16/24/32-bit integer and 32-bit
    /// float, any channel count (averaged), and the chunks Apple's writers
    /// put before the audio.
    public static func decode(_ file: Data) throws -> (pcm: Data, format: WAVFormat) {
        var parser = WAVStreamParser()
        var pcm = try parser.feed(file)
        guard let format = parser.format, let at = parser.dataSizeOffset else {
            throw AudioError.invalidWAV("no data chunk")
        }
        // A finished file says how long its audio is; chunks may follow it.
        let declared = file.count >= at + 4 ? Int(file.readUInt32LE(at)) : 0
        let blocks = declared / max(1, format.blockAlign)
        if declared > 0, declared < 0x7FFF_FFF0, blocks * 2 < pcm.count { pcm = pcm.prefix(blocks * 2) }
        return (pcm, format)
    }

    /// `decode` from a file on disk.
    public static func read(_ url: URL) throws -> (pcm: Data, format: WAVFormat) {
        try decode(Data(contentsOf: url))
    }
}

extension Data {
    func readUInt32LE(_ at: Int) -> UInt32 {
        let s = startIndex + at
        return UInt32(self[s]) | UInt32(self[s + 1]) << 8 | UInt32(self[s + 2]) << 16 | UInt32(self[s + 3]) << 24
    }
}

/// Reads a WAV file as it is being written, bytes in whatever pieces they
/// arrive, and returns its audio as mono 16-bit little-endian PCM at the
/// file's rate.
///
/// The header is not always 44 bytes: AVAudioRecorder and AVAudioFile put a
/// `FLLR` filler chunk (AVAudioFile also a `JUNK` chunk) before `data`, so
/// on Apple platforms the audio starts around byte 4096. The parser walks
/// the RIFF chunks to `data` and treats everything after its header as
/// audio: a recorder that is still writing has not filled in the size yet.
public struct WAVStreamParser: Sendable {
    public private(set) var format: WAVFormat?
    /// Where the `data` chunk's size field is in the file, once found.
    public private(set) var dataSizeOffset: Int?
    /// Audio bytes consumed so far (whole sample frames, in the file's format).
    public private(set) var dataBytes = 0

    private var header = Data()
    /// File bytes the header walk has passed.
    private var consumed = 0
    private var inData = false
    /// A sample frame split across two pieces.
    private var partial = Data()

    public init() {}

    /// Feeds the next bytes of the file; returns the audio in them.
    public mutating func feed(_ bytes: Data) throws -> Data {
        guard !bytes.isEmpty else { return Data() }
        if inData { return convert(bytes) }
        header.append(bytes)
        guard try parseHeader() else { return Data() }
        let rest = header.suffix(from: header.startIndex + consumed)
        header = Data()
        return convert(Data(rest))
    }

    /// Walks the chunks in `header`; true once past the `data` chunk's header.
    private mutating func parseHeader() throws -> Bool {
        let h = header
        func u32(_ at: Int) -> Int { Int(h.readUInt32LE(at)) }
        func u16(_ at: Int) -> Int { Int(h[h.startIndex + at]) | Int(h[h.startIndex + at + 1]) << 8 }
        func id(_ at: Int) -> String { String(decoding: h[(h.startIndex + at)..<(h.startIndex + at + 4)], as: UTF8.self) }
        if consumed == 0 {
            guard h.count >= 12 else { return false }
            guard id(0) == "RIFF", id(8) == "WAVE" else { throw AudioError.invalidWAV("no RIFF/WAVE header") }
            consumed = 12
        }
        while h.count >= consumed + 8 {
            let chunk = id(consumed), size = u32(consumed + 4)
            if chunk == "data" {
                guard let format else { throw AudioError.invalidWAV("data before fmt") }
                guard format.isSupported else {
                    throw AudioError.unsupportedFormat("\(format.bitsPerSample)-bit \(format.isFloat ? "float" : "integer") WAV")
                }
                dataSizeOffset = consumed + 4
                consumed += 8
                inData = true
                return true
            }
            let end = consumed + 8 + size + size % 2
            if chunk == "fmt " {
                guard h.count >= consumed + 8 + 16 else { return false }
                var tag = u16(consumed + 8)
                // WAVE_FORMAT_EXTENSIBLE: the subformat GUID starts with the real tag.
                if tag == 0xFFFE, size >= 40, h.count >= consumed + 8 + 26 { tag = u16(consumed + 8 + 24) }
                format = WAVFormat(sampleRate: u32(consumed + 12), channels: u16(consumed + 10),
                                   bitsPerSample: u16(consumed + 22), isFloat: tag == 3)
                guard tag == 1 || tag == 3 else { throw AudioError.unsupportedFormat("WAV format tag \(tag)") }
            }
            guard h.count >= end else { return false }  // a filler chunk not fully written yet
            consumed = end
        }
        return false
    }

    /// Whole sample frames → mono Int16 LE.
    private mutating func convert(_ bytes: Data) -> Data {
        guard let format else { return Data() }
        var input = partial
        input.append(bytes)
        let block = format.blockAlign
        let whole = input.count / block * block
        partial = whole < input.count ? Data(input.suffix(from: input.startIndex + whole)) : Data()
        guard whole > 0 else { return Data() }
        dataBytes += whole
        if !format.isFloat, format.bitsPerSample == 16 {
            return format.channels == 1 ? Data(input.prefix(whole)) : PCM16.downmix(Data(input.prefix(whole)), channels: format.channels)
        }
        let frames = whole / block
        var out = [Int16](repeating: 0, count: frames)
        input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytesPerSample = format.bitsPerSample / 8
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<format.channels {
                    sum += Self.sample(raw, at: f * block + c * bytesPerSample, format: format)
                }
                let v = max(-1, min(1, sum / Float(format.channels)))
                out[f] = Int16(clamping: Int((v * 32767).rounded()))
            }
        }
        return PCM16.data(out)
    }

    private static func sample(_ raw: UnsafeRawBufferPointer, at: Int, format: WAVFormat) -> Float {
        if format.isFloat {
            return Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self)))
        }
        switch format.bitsPerSample {
        case 16: return Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: Int16.self))) / 32768
        case 24:
            let v = Int32(raw[at]) | Int32(raw[at + 1]) << 8 | Int32(Int8(bitPattern: raw[at + 2])) << 16
            return Float(v) / 8_388_608
        default: return Float(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: Int32.self))) / 2_147_483_648
        }
    }
}

/// Writes 16-bit PCM to a WAV file as it is captured. The header's sizes are
/// filled in on every `flush` and on `close`, so a file cut short by a crash
/// still plays up to its last flush (and `WAVStreamParser` reads all of it).
/// Not thread-safe; the caller serializes.
public final class WAVWriter {
    public let url: URL
    public let format: PCMFormat
    /// Audio bytes written.
    public private(set) var dataBytes = 0
    private var handle: FileHandle?

    /// Creates (or replaces) the file and writes the header.
    public init(url: URL, format: PCMFormat) throws {
        self.url = url
        self.format = format
        guard FileManager.default.createFile(atPath: url.path, contents: WAV.header(dataBytes: 0, format: format)) else {
            throw AudioError.io("couldn't create \(url.lastPathComponent)")
        }
        handle = try FileHandle(forWritingTo: url)
        try handle?.seekToEnd()
    }

    deinit { try? close() }

    public func append(_ pcm: Data) throws {
        guard let handle, !pcm.isEmpty else { return }
        try handle.write(contentsOf: pcm)
        dataBytes += pcm.count
    }

    /// Fills in the header's sizes and syncs the file to disk.
    public func flush() throws {
        guard let handle else { return }
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: Self.u32(36 + dataBytes))
        try handle.seek(toOffset: UInt64(WAV.canonicalDataSizeOffset))
        try handle.write(contentsOf: Self.u32(dataBytes))
        try handle.seekToEnd()
        try handle.synchronize()
    }

    /// Fills in the header and closes the file. Further appends are ignored.
    public func close() throws {
        guard handle != nil else { return }
        defer { try? handle?.close(); handle = nil }
        try flush()
    }

    private static func u32(_ v: Int) -> Data {
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: v).littleEndian) { Data($0) }
    }
}
