import Foundation
import InferenceSDK
#if canImport(Glibc)
import Glibc
#endif

/// Recordings on disk: `<root>/<id>/manifest.json` plus `seg-NNNN.pcm`
/// segments. Stateless apart from the root; safe from any thread as long as
/// one recording is not written from two.
public struct RecordingStore: Sendable {
    public let root: URL
    public static let manifestName = "manifest.json"

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// `Application Support/Recordings` (excluded from backups where that exists).
    public static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #if canImport(Darwin)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = url
        try? excluded.setResourceValues(values)
        #endif
        return url
    }

    public func directory(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    public func url(_ id: String, _ file: String) -> URL { directory(id).appendingPathComponent(file) }

    /// A new recording id: a sortable local timestamp and a short random tail.
    public static func newId(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date) + "-" + UUID().uuidString.prefix(4).lowercased()
    }

    /// Creates the recording's directory and saves its first manifest.
    public func create(_ manifest: RecordingManifest) throws {
        try FileManager.default.createDirectory(at: directory(manifest.id), withIntermediateDirectories: true)
        try save(manifest)
    }

    // MARK: - Manifest

    /// Atomic replace: writes `manifest.json.tmp`, syncs it, renames it over
    /// the manifest. A crash leaves the old or the new manifest, never a torn
    /// one; a stray .tmp is ignored by `load`.
    public func save(_ manifest: RecordingManifest) throws {
        var m = manifest
        m.updatedAt = Date()
        let data = try RecordingManifest.encoder.encode(m)
        let final = url(m.id, Self.manifestName)
        let tmp = url(m.id, Self.manifestName + ".tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil) else {
            throw AudioError.io("couldn't write the manifest of \(m.id)")
        }
        let h = try FileHandle(forWritingTo: tmp)
        do {
            try h.write(contentsOf: data)
            try h.synchronize()
            try h.close()
        } catch {
            try? h.close()
            throw error
        }
        guard rename(tmp.path, final.path) == 0 else {
            throw AudioError.io("couldn't replace the manifest of \(m.id) (errno \(errno))")
        }
    }

    public func load(_ id: String) throws -> RecordingManifest {
        let data = try Data(contentsOf: url(id, Self.manifestName))
        return try RecordingManifest.decoder.decode(RecordingManifest.self, from: data)
    }

    /// Every readable manifest, newest first.
    public func list() -> [RecordingManifest] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return ids.compactMap { try? load($0) }.sorted { $0.startedAt > $1.startedAt }
    }

    public func delete(_ id: String) throws {
        try FileManager.default.removeItem(at: directory(id))
    }

    // MARK: - Recovery

    /// Finishes every recording still marked `recording`: the process died
    /// while it captured. Call at launch, before starting a new recording.
    /// Returns the recovered manifests.
    @discardableResult
    public func recoverInterrupted(now: Date = Date()) -> [RecordingManifest] {
        var recovered: [RecordingManifest] = []
        for var m in list() where m.state == .recording {
            finalize(&m, endedAt: m.updatedAt > m.startedAt ? m.updatedAt : now)
            if (try? save(m)) != nil { recovered.append(m) }
        }
        return recovered
    }

    /// Ends a recording: rebuilds the segment table from the files on disk
    /// (they are the truth: a crash can land between creating a segment and
    /// recording it in the manifest), trims a torn trailing byte, closes
    /// open gaps, sets `endedAt` and the `ended` state.
    public func finalize(_ m: inout RecordingManifest, endedAt: Date = Date()) {
        m.segments = scanSegments(m, repair: true)
        let total = m.totalSamples
        m.endedAt = m.endedAt ?? endedAt
        for i in m.gaps.indices {
            if m.gaps[i].endedAt == nil { m.gaps[i].endedAt = m.endedAt }
            m.gaps[i].atSample = min(m.gaps[i].atSample, total)
        }
        m.state = .ended
    }

    /// The segment table as the files on disk say. `repair` truncates a torn
    /// trailing byte and removes empty segments (recovery only: a recording
    /// in progress is read with `repair: false`).
    public func scanSegments(_ m: RecordingManifest, repair: Bool) -> [RecordingManifest.Segment] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: directory(m.id).path)) ?? [])
            .compactMap { name in SegmentWriter.index(of: name).map { (name, $0) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        let known = Dictionary(m.segments.map { ($0.file, $0) }, uniquingKeysWith: { a, _ in a })
        let bytesPerSample = Int64(SegmentWriter.bytesPerSample)
        var segments: [RecordingManifest.Segment] = []
        var offset: Int64 = 0
        for name in names {
            let u = url(m.id, name)
            var size = (try? fm.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.int64Value ?? 0
            let odd = size % bytesPerSample
            if odd != 0 {
                size -= odd
                if repair, let h = try? FileHandle(forWritingTo: u) {
                    try? h.truncate(atOffset: UInt64(size))
                    try? h.close()
                }
            }
            let count = size / bytesPerSample
            if count == 0 {
                if repair { try? fm.removeItem(at: u) }
                continue
            }
            segments.append(.init(file: name, startSample: offset, sampleCount: count, startedAt: known[name]?.startedAt))
            offset += count
        }
        return segments
    }

    /// The manifest with its segment table read from disk when it is still
    /// recording (the counts only settle when it ends).
    public func current(_ m: RecordingManifest) -> RecordingManifest {
        guard m.state == .recording else { return m }
        var view = m
        view.segments = scanSegments(m, repair: false)
        return view
    }

    // MARK: - Reading audio

    /// The PCM of `range` (timeline samples), across segment boundaries.
    public func readPCM(_ m: RecordingManifest, _ range: Range<Int64>) throws -> Data {
        var out = Data(capacity: Int(range.count) * SegmentWriter.bytesPerSample)
        try forEachChunk(m, range, chunkSamples: Int64(max(1, range.count))) { out.append($0) }
        return out
    }

    /// Streams `range` in chunks of at most `chunkSamples`, without loading
    /// the recording into memory.
    public func forEachChunk(_ m: RecordingManifest, _ range: Range<Int64>, chunkSamples: Int64 = 160_000,
                             _ body: (Data) throws -> Void) throws {
        let m = current(m)
        guard range.lowerBound >= 0, range.upperBound <= m.totalSamples else {
            throw AudioError.io("samples \(range) are outside the recording (0..<\(m.totalSamples))")
        }
        let bytesPerSample = SegmentWriter.bytesPerSample
        for seg in m.segments {
            let segRange = seg.startSample..<(seg.startSample + seg.sampleCount)
            let lo = max(range.lowerBound, segRange.lowerBound), hi = min(range.upperBound, segRange.upperBound)
            guard lo < hi else { continue }
            let h = try FileHandle(forReadingFrom: url(m.id, seg.file))
            defer { try? h.close() }
            try h.seek(toOffset: UInt64((lo - seg.startSample) * Int64(bytesPerSample)))
            var remaining = hi - lo
            while remaining > 0 {
                let n = min(remaining, max(chunkSamples, 1))
                guard let data = try h.read(upToCount: Int(n) * bytesPerSample), !data.isEmpty else {
                    throw AudioError.io("\(seg.file) is shorter than the manifest says")
                }
                try body(data)
                remaining -= Int64(data.count / bytesPerSample)
            }
        }
    }

    /// A clip by sample range as an in-memory WAV (clamped to the recording;
    /// works while it is still recording).
    public func clipWAV(_ m: RecordingManifest, from inSample: Int64, to outSample: Int64) throws -> Data {
        let view = current(m)
        let hi = min(outSample, view.totalSamples), lo = min(max(0, inSample), hi)
        return WAV.wrap(try readPCM(view, lo..<hi), format: view.pcmFormat)
    }

    /// Joins `range` (default: everything) into one WAV file, streamed.
    public func joinWAV(_ m: RecordingManifest, range: Range<Int64>? = nil, to dest: URL) throws {
        let view = current(m)
        let r = range ?? 0..<view.totalSamples
        guard FileManager.default.createFile(atPath: dest.path, contents: nil) else {
            throw AudioError.io("couldn't create \(dest.lastPathComponent)")
        }
        let h = try FileHandle(forWritingTo: dest)
        defer { try? h.close() }
        try h.write(contentsOf: WAV.header(dataBytes: Int(r.count) * SegmentWriter.bytesPerSample, format: view.pcmFormat))
        try forEachChunk(view, r) { try h.write(contentsOf: $0) }
    }

    // MARK: - Transcribing

    /// How parts go up for transcription.
    public enum UploadEncoding: Sendable {
        /// 16-bit PCM WAV: about 115 MB per hour at 16 kHz.
        case wav
        #if canImport(AVFoundation)
        /// AAC in an .m4a: about 14 MB per hour of speech at 32 kbps.
        case aac(bitRate: Int)
        #endif
    }

    /// Transcribes a recording with `stt`, in parts of `partSeconds` (STT
    /// apps limit how long one file may be), and joins the texts with a
    /// space. `progress` gets each part's text as it comes.
    public func transcribe(_ m: RecordingManifest, with stt: SpeechToText, partSeconds: TimeInterval = 600,
                           encoding: UploadEncoding = .wav,
                           progress: (@Sendable (_ part: Int, _ of: Int, _ text: String) -> Void)? = nil) async throws -> String {
        let view = current(m)
        let total = view.totalSamples
        let partSamples = max(Int64(view.sampleRate), Int64(partSeconds * Double(view.sampleRate)))
        let starts = Array(stride(from: Int64(0), to: total, by: Int(partSamples)))
        var texts: [String] = []
        for (i, start) in starts.enumerated() {
            let range = start..<min(total, start + partSamples)
            let (audio, filename, contentType) = try upload(view, range, encoding: encoding)
            let text = try await stt.transcribe(audio, filename: filename, contentType: contentType)
            progress?(i + 1, starts.count, text)
            if !text.isEmpty { texts.append(text) }
        }
        return texts.joined(separator: " ")
    }

    private func upload(_ m: RecordingManifest, _ range: Range<Int64>, encoding: UploadEncoding) throws
        -> (Data, filename: String, contentType: String) {
        switch encoding {
        case .wav:
            return (WAV.wrap(try readPCM(m, range), format: m.pcmFormat), "\(m.id).wav", "audio/wav")
        #if canImport(AVFoundation)
        case .aac(let bitRate):
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(m.id)-\(UUID().uuidString.prefix(8)).m4a")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try AudioEncoder.encodeAAC(store: self, manifest: m, range: range, to: tmp, bitRate: bitRate)
            return (try Data(contentsOf: tmp), "\(m.id).m4a", AudioEncoder.aacContentType)
        #endif
        }
    }
}
