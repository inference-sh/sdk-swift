import Foundation
import InferenceSDK

/// Where audio comes from: `Microphone`, `WAVFileSource`, or anything else
/// that yields 16-bit PCM. `LiveTranscriber`, `LiveVoiceCall` and
/// `CrashSafeRecorder` take any source, so a file can stand in for the
/// microphone (tests, a CLI, a server).
public protocol AudioSource: AnyObject, Sendable {
    /// Starts producing 16-bit little-endian PCM in `format`, in frames of
    /// about 20 ms. The stream finishes when the source stops (`stop()`, the
    /// end of a file) and throws when capture fails. One stream at a time.
    func start(format: PCMFormat) async throws -> AsyncThrowingStream<Data, Error>
    /// Stops producing. Audio already captured is still delivered, then the
    /// stream finishes. A stopped source can be started again.
    func stop()
}

/// Where audio goes: `PCMPlayer`, or anything else that takes 16-bit PCM.
public protocol AudioSink: AnyObject, Sendable {
    /// Gets ready to play PCM in `format`.
    func start(format: PCMFormat) throws
    /// Queues one frame right after the previous one.
    func play(_ pcm: Data)
    /// Drops everything queued and not yet heard: the answer being played
    /// was cut short (`$clear`).
    func flush()
    /// Stops playing and lets go of the output.
    func stop()
}

/// A WAV file as an `AudioSource`: its audio converted to the asked format
/// and yielded in 20 ms frames, in real time by default, as a microphone
/// would. The stand-in for a microphone where there is none.
public final class WAVFileSource: AudioSource, @unchecked Sendable {
    public let url: URL
    /// Paces frames at the speed of sound (true) or yields them all at once.
    public let realtime: Bool
    /// Silence appended after the file: lets an app's voice detection hear
    /// the end of a turn before the source finishes.
    public let trailingSilence: TimeInterval

    private let lock = NSLock()
    private var pump: Task<Void, Never>?

    public init(url: URL, realtime: Bool = true, trailingSilence: TimeInterval = 0) {
        self.url = url
        self.realtime = realtime
        self.trailingSilence = trailingSilence
    }

    public func start(format: PCMFormat) async throws -> AsyncThrowingStream<Data, Error> {
        let (pcm, fileFormat) = try WAV.read(url)
        let resampler = makeResampler(from: fileFormat.sampleRate, to: format.sampleRate)
        var mono = resampler.process(pcm)
        mono.append(resampler.flush())
        mono.append(Data(count: Int(trailingSilence * Double(format.sampleRate)) * 2))
        var framer = PCMFramer(format: format)
        var frames = framer.append(PCM16.upmix(mono, channels: format.channels))
        if let last = framer.flush() { frames.append(last) }
        let all = frames

        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        let realtime = self.realtime
        let started: Bool = lock.locked {
            guard pump == nil else { return false }
            pump = Task {
                let start = monotonicNow()
                for (i, frame) in all.enumerated() {
                    if Task.isCancelled { break }
                    if realtime {
                        let due = start + Double(i) * 0.02
                        let wait = due - monotonicNow()
                        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                        if Task.isCancelled { break }
                    }
                    continuation.yield(frame)
                }
                continuation.finish()
                self.ended()
            }
            return true
        }
        guard started else { throw AudioError.alreadyRunning }
        continuation.onTermination = { [weak self] _ in self?.stop() }
        return stream
    }

    /// Frames are still coming: started, and neither stopped nor at the end of the file.
    public var isRunning: Bool { lock.locked { pump != nil } }

    public func stop() {
        let pump: Task<Void, Never>? = lock.locked { defer { self.pump = nil }; return self.pump }
        pump?.cancel()
    }

    private func ended() {
        lock.locked { pump = nil }
    }
}
