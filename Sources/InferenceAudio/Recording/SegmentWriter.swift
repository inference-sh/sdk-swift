import Foundation

/// Appends PCM to `seg-NNNN.pcm` files in a recording's directory.
///
/// Crash safety comes from the format, not from closing: segments are
/// headerless, every append goes straight to the kernel (FileHandle does
/// not buffer), and the file is synced to disk about once per
/// `flushInterval`, so a crash loses at most the last append and a power
/// loss about a second. Segments rotate every `maxSegmentSamples`, so no
/// file grows without bound and recovery only looks at the last one.
///
/// Not thread-safe; the caller serializes.
public final class SegmentWriter {
    public struct Config: Sendable {
        public var maxSegmentSamples: Int64
        public var flushInterval: TimeInterval

        /// Five minutes per segment at 16 kHz, synced every second.
        public init(maxSegmentSamples: Int64 = 16_000 * 300, flushInterval: TimeInterval = 1) {
            self.maxSegmentSamples = maxSegmentSamples
            self.flushInterval = flushInterval
        }
    }

    /// Bytes per sample in a segment (mono 16-bit).
    public static let bytesPerSample = 2

    public let directory: URL
    public let config: Config
    /// Called after a segment file is created, before any sample goes in.
    public var onSegmentStarted: ((RecordingManifest.Segment) -> Void)?

    public private(set) var segmentIndex: Int
    /// Samples on the timeline, including those before this writer.
    public private(set) var totalSamples: Int64
    private var segmentSamples: Int64 = 0
    private var handle: FileHandle?
    private var lastSync: TimeInterval
    /// Half a sample left over from the last append.
    private var oddByte: UInt8?

    public static func fileName(_ index: Int) -> String { String(format: "seg-%04d.pcm", index) }

    /// The index in a segment's file name.
    public static func index(of fileName: String) -> Int? {
        guard fileName.hasPrefix("seg-"), fileName.hasSuffix(".pcm") else { return nil }
        return Int(fileName.dropFirst(4).dropLast(4))
    }

    /// - Parameters:
    ///   - firstIndex: The next segment's index (after a resume: one past the last).
    ///   - startSample: Where on the timeline this writer starts.
    public init(directory: URL, firstIndex: Int = 0, startSample: Int64 = 0, config: Config = Config()) {
        self.directory = directory
        self.config = config
        segmentIndex = firstIndex
        totalSamples = startSample
        lastSync = monotonicNow()
    }

    deinit { try? close() }

    /// Appends mono 16-bit little-endian PCM.
    public func append(_ pcm: Data) throws {
        var bytes = pcm
        if let odd = oddByte {
            bytes.insert(odd, at: bytes.startIndex)
            oddByte = nil
        }
        if bytes.count % 2 == 1 { oddByte = bytes.removeLast() }
        var offset = bytes.startIndex
        while offset < bytes.endIndex {
            let h = try currentHandle()
            let room = Int(config.maxSegmentSamples - segmentSamples) * Self.bytesPerSample
            let n = min(room, bytes.endIndex - offset)
            try h.write(contentsOf: bytes[offset..<offset + n])
            let samples = Int64(n / Self.bytesPerSample)
            segmentSamples += samples
            totalSamples += samples
            offset += n
            if segmentSamples >= config.maxSegmentSamples { try closeSegment() }
        }
        if monotonicNow() - lastSync >= config.flushInterval { try flush() }
    }

    /// Syncs the open segment to disk.
    public func flush() throws {
        lastSync = monotonicNow()
        try handle?.synchronize()
    }

    /// Ends the current segment; the next append starts a new one.
    public func closeSegment() throws {
        guard let h = handle else { return }
        handle = nil
        segmentIndex += 1
        segmentSamples = 0
        try h.synchronize()
        try h.close()
    }

    public func close() throws { try closeSegment() }

    private func currentHandle() throws -> FileHandle {
        if let handle { return handle }
        let name = Self.fileName(segmentIndex)
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw AudioError.io("couldn't create \(name)")
        }
        let h = try FileHandle(forWritingTo: url)
        handle = h
        segmentSamples = 0
        onSegmentStarted?(.init(file: name, startSample: totalSamples, sampleCount: 0, startedAt: Date()))
        return h
    }
}
