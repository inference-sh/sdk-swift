import Foundation
import InferenceSDK

/// Everything known about one recording, kept as `manifest.json` in the
/// recording's directory and replaced atomically on every change
/// (`RecordingStore.save`).
///
/// The audio is a run of headerless segments (`seg-0000.pcm`, …) of mono
/// signed 16-bit little-endian samples at `sampleRate`. Sample positions
/// are on the recording's timeline, the segments end to end. Time lost to
/// interruptions is not on it; `gaps` say where it was cut and for how long.
public struct RecordingManifest: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchema = 1

    public var schema = RecordingManifest.currentSchema
    public var id: String
    public var startedAt: Date
    public var endedAt: Date?
    /// When the manifest was last saved: about when a recording that died
    /// stopped capturing.
    public var updatedAt: Date
    public var sampleRate: Int
    public var channels = 1
    /// The segments' sample format.
    public var format = "s16le"
    public var segments: [Segment] = []
    public var gaps: [Gap] = []
    public var state: State = .recording
    public var error: String?
    /// The app's own fields (title, device, flags, …): kept as they are.
    public var metadata: [String: JSONValue] = [:]

    public init(id: String, startedAt: Date = Date(), sampleRate: Int = 16_000, metadata: [String: JSONValue] = [:]) {
        self.id = id
        self.startedAt = startedAt
        self.updatedAt = startedAt
        self.sampleRate = sampleRate
        self.metadata = metadata
    }

    public enum State: String, Codable, Sendable {
        /// Capturing, or the process died while it was (`RecordingStore.recoverInterrupted`).
        case recording
        /// Finished: the segment table is final.
        case ended
        case failed
    }

    public struct Segment: Codable, Equatable, Sendable {
        public var file: String
        public var startSample: Int64
        public var sampleCount: Int64
        public var startedAt: Date?

        public init(file: String, startSample: Int64, sampleCount: Int64, startedAt: Date? = nil) {
            self.file = file
            self.startSample = startSample
            self.sampleCount = sampleCount
            self.startedAt = startedAt
        }
    }

    /// An interruption: capture stopped at `atSample` for a while.
    public struct Gap: Codable, Equatable, Sendable {
        public var atSample: Int64
        public var startedAt: Date
        public var endedAt: Date?
        public var reason: String

        public var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }

        public init(atSample: Int64, startedAt: Date, endedAt: Date? = nil, reason: String) {
            self.atSample = atSample
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.reason = reason
        }
    }

    /// Samples on the timeline.
    public var totalSamples: Int64 { segments.reduce(0) { $0 + $1.sampleCount } }

    /// Seconds of audio.
    public var duration: TimeInterval { TimeInterval(totalSamples) / TimeInterval(max(1, sampleRate)) }

    /// The segments' format.
    public var pcmFormat: PCMFormat { PCMFormat(sampleRate: sampleRate, channels: channels) }

    // Missing keys take their defaults, so manifests from older or newer
    // writers still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? Self.currentSchema
        id = try c.decode(String.self, forKey: .id)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? startedAt
        sampleRate = try c.decodeIfPresent(Int.self, forKey: .sampleRate) ?? 16_000
        channels = try c.decodeIfPresent(Int.self, forKey: .channels) ?? 1
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? "s16le"
        segments = try c.decodeIfPresent([Segment].self, forKey: .segments) ?? []
        gaps = try c.decodeIfPresent([Gap].self, forKey: .gaps) ?? []
        state = (try? c.decodeIfPresent(State.self, forKey: .state)) ?? .ended
        error = try c.decodeIfPresent(String.self, forKey: .error)
        metadata = try c.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
