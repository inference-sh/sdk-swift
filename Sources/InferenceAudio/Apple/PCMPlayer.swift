#if canImport(AVFoundation)
import AVFoundation
import Foundation
import InferenceSDK

/// Plays 16-bit PCM frames as they arrive from a live function (web app:
/// `Player` in src/lib/live/pcm.ts), on an AVAudioEngine player node.
///
/// Frames are scheduled back to back. When playback has run dry (a gap in
/// the frames, or the first frame) the next frame starts `lead` from now:
/// a little silence that absorbs network jitter, instead of a delay that
/// piles up. `flush()` drops everything queued, for `$clear` (the user
/// talked over the answer).
///
/// The audio session is the app's (`AudioSessionConfigurator`). For echo
/// cancellation in a call, give the player and the `Microphone` the same
/// engine: voice processing then cancels what the player plays.
public final class PCMPlayer: AudioSink, @unchecked Sendable {
    /// Silence before a frame that starts playback from dry.
    public let lead: TimeInterval

    private let sharedEngine: AVAudioEngine?
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var playFormat: AVAudioFormat?
    private var pcmFormat: PCMFormat?
    private var observer: ObserverToken?
    /// Sample frames scheduled and not yet played.
    private var pending = 0
    /// Bumped by `flush`: callbacks of dropped buffers do not count.
    private var generation = 0
    private var lastPeak: Float = 0

    /// - Parameters:
    ///   - engine: An engine to share with a `Microphone` (echo cancellation).
    ///     Nil: the player runs its own.
    ///   - lead: Silence before a frame that starts playback from dry (60 ms).
    public init(engine: AVAudioEngine? = nil, lead: TimeInterval = 0.06) {
        sharedEngine = engine
        self.lead = lead
    }

    /// The format being played.
    public var format: PCMFormat? { lock.locked { pcmFormat } }
    /// Seconds queued and not yet heard.
    public var queuedDuration: TimeInterval {
        lock.locked { pcmFormat.map { TimeInterval(pending) / TimeInterval($0.sampleRate) } ?? 0 }
    }
    /// Peak level of the last frame queued, 0...1.
    public var level: Float { lock.locked { lastPeak } }

    // MARK: - AudioSink

    public func start(format: PCMFormat) throws {
        guard format.sampleRate > 0, format.channels > 0,
              let playFormat = AVAudioFormat(standardFormatWithSampleRate: Double(format.sampleRate),
                                             channels: AVAudioChannelCount(format.channels)) else {
            throw AudioError.unsupportedFormat("\(format.sampleRate) Hz × \(format.channels)")
        }
        if lock.locked({ self.pcmFormat == format && self.node != nil }) { return }
        stop()
        let engine = sharedEngine ?? AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: playFormat)
        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                engine.detach(node)
                throw error
            }
        }
        node.play()
        let observer = ObserverToken(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.restart()
        })
        lock.locked {
            self.engine = engine
            self.node = node
            self.playFormat = playFormat
            self.pcmFormat = format
            self.observer = observer
            pending = 0
        }
    }

    /// Queues one frame right after the previous one.
    public func play(_ pcm: Data) {
        let current: (AVAudioEngine, AVAudioPlayerNode, AVAudioFormat, PCMFormat)? = lock.locked {
            guard let e = self.engine, let n = self.node, let p = self.playFormat, let f = self.pcmFormat else { return nil }
            return (e, n, p, f)
        }
        guard let (engine, node, playFormat, format) = current else { return }
        let frames = pcm.count / format.bytesPerFrame
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let count = format.channels
        pcm.withUnsafeBytes { raw in
            for f in 0..<frames {
                for c in 0..<count {
                    let s = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: (f * count + c) * 2, as: Int16.self))
                    channels[c][f] = Float(s) / 32768
                }
            }
        }
        // A shared engine may have been restarted (voice processing turned on).
        if !engine.isRunning { try? engine.start() }
        if !node.isPlaying { node.play() }

        let (dry, generation): (Bool, Int) = lock.locked {
            lastPeak = PCM16.peak(pcm)
            return (pending == 0, self.generation)
        }
        if dry, lead > 0, let silence = AVAudioPCMBuffer(pcmFormat: playFormat,
                                                         frameCapacity: AVAudioFrameCount(lead * playFormat.sampleRate)) {
            silence.frameLength = silence.frameCapacity  // zeroed
            schedule(silence, on: node, generation: generation)
        }
        schedule(buffer, on: node, generation: generation)
    }

    /// Drops everything queued and not yet heard.
    public func flush() {
        let node: AVAudioPlayerNode? = lock.locked {
            generation += 1
            pending = 0
            lastPeak = 0
            return self.node
        }
        node?.stop()
        if let node, node.engine?.isRunning == true { node.play() }
    }

    /// Stops playing and lets go of the output (and of the engine, unless shared).
    public func stop() {
        let (engine, node, observer): (AVAudioEngine?, AVAudioPlayerNode?, ObserverToken?) = lock.locked {
            defer {
                self.engine = nil
                self.node = nil
                self.playFormat = nil
                self.pcmFormat = nil
                self.observer = nil
                pending = 0
                generation += 1
                lastPeak = 0
            }
            return (self.engine, self.node, self.observer)
        }
        if let observer { NotificationCenter.default.removeObserver(observer.token) }
        node?.stop()
        if let engine, let node {
            engine.detach(node)
            if sharedEngine == nil { engine.stop() }
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, on node: AVAudioPlayerNode, generation: Int) {
        let frames = Int(buffer.frameLength)
        lock.locked { pending += frames }
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.locked {
                if self.generation == generation { self.pending = max(0, self.pending - frames) }
            }
        }
    }

    /// A route or format change stopped the engine: start it again.
    private func restart() {
        let (engine, node): (AVAudioEngine?, AVAudioPlayerNode?) = lock.locked {
            generation += 1
            pending = 0
            return (self.engine, self.node)
        }
        guard let engine, let node else { return }
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
        if engine.isRunning { node.play() }
    }
}
#endif
