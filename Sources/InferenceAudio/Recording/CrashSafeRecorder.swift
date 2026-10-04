import Foundation
import InferenceSDK

/// Long recordings that survive the app dying: audio from any `AudioSource`
/// goes into headerless PCM segments synced to disk every second
/// (`SegmentWriter`), and the recording's manifest is replaced atomically on
/// every change (`RecordingStore`). After a crash, `store.recoverInterrupted()`
/// at the next launch finishes what was captured.
///
///     let recorder = CrashSafeRecorder(store: store, source: Microphone())
///     let started = try await recorder.start()
///     …
///     let recording = await recorder.stop()            // the finished manifest
///     let text = try await store.transcribe(recording!, with: SpeechToText(client: client, app: "elevenlabs/stt"))
///
/// An interruption (a call, Siri) ends capture and opens a gap; `resume`
/// continues on the same timeline. On iOS and watchOS the recorder follows
/// the audio session's interruptions itself (`handlesInterruptions`).
public final class CrashSafeRecorder: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case recording
        /// Capture stopped for a while (`interrupt`); `resume` continues.
        case interrupted(reason: String)
        /// Writing failed (the disk is full): `stop` keeps what was written.
        case failed(String)
    }

    public struct Snapshot: Equatable, Sendable {
        public var state: State
        /// The recording in progress.
        public var id: String?
        /// Seconds captured.
        public var elapsed: TimeInterval
        /// Meter level of the latest audio, 0...1.
        public var level: Float
    }

    public let store: RecordingStore
    public let source: any AudioSource
    /// The format recorded: mono 16-bit at this rate.
    public let format: PCMFormat
    public var segmentConfig: SegmentWriter.Config
    /// Follow the audio session's interruptions (iOS, watchOS): interrupt on
    /// began, resume on ended when the system says to.
    public var handlesInterruptions = true
    /// Every captured frame after it was written, on the capture task (e.g.
    /// to stream a long recording into a `LiveTranscriber` too).
    public var onAudio: (@Sendable (Data) -> Void)?
    /// The latest snapshot on every change. A slow reader gets the newest one.
    public let updates: AsyncStream<Snapshot>

    private let sink: AsyncStream<Snapshot>.Continuation
    private let lock = NSLock()
    private var snapshot = Snapshot(state: .idle, id: nil, elapsed: 0, level: 0)
    private var manifest: RecordingManifest?
    private var writer: SegmentWriter?
    private var pump: Task<Void, Never>?
    private var samples: Int64 = 0
    private var nextSegment = 0
    private var sessionWatcher: Task<Void, Never>?

    public init(store: RecordingStore, source: any AudioSource, sampleRate: Int = 16_000,
                segmentConfig: SegmentWriter.Config = SegmentWriter.Config()) {
        self.store = store
        self.source = source
        format = PCMFormat(sampleRate: sampleRate, channels: 1)
        self.segmentConfig = segmentConfig
        (updates, sink) = AsyncStream.makeStream(of: Snapshot.self, bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        sessionWatcher?.cancel()
        sink.finish()
    }

    public var current: Snapshot { lock.locked { snapshot } }

    /// The recording in progress, as last saved.
    public var recording: RecordingManifest? { lock.locked { manifest } }

    /// Starts a new recording; returns its first manifest once capture runs.
    @discardableResult
    public func start(metadata: [String: JSONValue] = [:]) async throws -> RecordingManifest {
        let busy: Bool = lock.locked { manifest != nil }
        guard !busy else { throw AudioError.alreadyRunning }
        let m = RecordingManifest(id: RecordingStore.newId(), sampleRate: format.sampleRate, metadata: metadata)
        try store.create(m)
        lock.locked {
            manifest = m
            samples = 0
            nextSegment = 0
            snapshot = Snapshot(state: .recording, id: m.id, elapsed: 0, level: 0)
        }
        do {
            try await beginCapture()
        } catch {
            var failed = m
            failed.state = .failed
            failed.error = error.localizedDescription
            failed.endedAt = Date()
            try? store.save(failed)
            lock.locked {
                manifest = nil
                snapshot = Snapshot(state: .idle, id: nil, elapsed: 0, level: 0)
            }
            publish()
            throw error
        }
        watchSession()
        publish()
        return m
    }

    /// Ends capture for now (an interruption) and opens a gap on the timeline.
    public func interrupt(reason: String) async {
        let recording: Bool = lock.locked { snapshot.state == .recording }
        guard recording else { return }
        await endCapture()
        update { m, samples in
            m.gaps.append(.init(atSample: samples, startedAt: Date(), reason: reason))
        }
        lock.locked { snapshot.state = .interrupted(reason: reason); snapshot.level = 0 }
        publish()
    }

    /// Continues an interrupted recording on the same timeline.
    public func resume() async throws {
        let interrupted: Bool = lock.locked {
            if case .interrupted = snapshot.state { return true }
            return false
        }
        guard interrupted else { return }
        try await beginCapture()
        update { m, _ in
            if let g = m.gaps.lastIndex(where: { $0.endedAt == nil }) { m.gaps[g].endedAt = Date() }
        }
        lock.locked { snapshot.state = .recording }
        publish()
    }

    /// Ends the recording and returns its finished manifest.
    @discardableResult
    public func stop() async -> RecordingManifest? {
        sessionWatcher?.cancel()
        await endCapture()
        let m: RecordingManifest? = lock.locked { defer { manifest = nil }; return manifest }
        guard var m else { return nil }
        if case .failed(let message) = current.state { m.error = message }
        store.finalize(&m, endedAt: Date())
        try? store.save(m)
        lock.locked { snapshot = Snapshot(state: .idle, id: nil, elapsed: snapshot.elapsed, level: 0) }
        publish()
        return (try? store.load(m.id)) ?? m
    }

    // MARK: - Capture

    private func beginCapture() async throws {
        guard let id = lock.locked({ manifest?.id }) else { return }
        let (first, start) = lock.locked { (nextSegment, samples) }
        let writer = SegmentWriter(directory: store.directory(id), firstIndex: first, startSample: start, config: segmentConfig)
        writer.onSegmentStarted = { [weak self] segment in
            self?.update { m, _ in
                if !m.segments.contains(where: { $0.file == segment.file }) { m.segments.append(segment) }
            }
        }
        let frames = try await source.start(format: format)
        lock.locked { self.writer = writer }
        let pump = Task { [weak self] in
            do {
                for try await frame in frames {
                    guard let self else { return }
                    try self.write(frame, to: writer)
                }
            } catch {
                self?.failed(error)
            }
        }
        lock.locked { self.pump = pump }
    }

    private func write(_ frame: Data, to writer: SegmentWriter) throws {
        let pcm = PCM16.downmix(frame, channels: format.channels)
        try writer.append(pcm)
        let level = PCM16.meter(PCM16.rms(pcm))
        lock.locked {
            samples = writer.totalSamples
            snapshot.elapsed = TimeInterval(samples) / TimeInterval(format.sampleRate)
            snapshot.level = level
        }
        onAudio?(pcm)
        publish()
    }

    private func failed(_ error: Error) {
        source.stop()
        lock.locked { snapshot.state = .failed(error.localizedDescription) }
        publish()
    }

    /// Stops the source, waits for its last audio, closes the segment.
    private func endCapture() async {
        let pump: Task<Void, Never>? = lock.locked { self.pump }
        source.stop()
        await pump?.value
        let writer: SegmentWriter? = lock.locked {
            defer { self.writer = nil; self.pump = nil }
            return self.writer
        }
        guard let writer else { return }
        try? writer.close()
        lock.locked {
            samples = writer.totalSamples
            nextSegment = writer.segmentIndex
        }
    }

    /// Changes the manifest and saves it.
    private func update(_ change: (inout RecordingManifest, Int64) -> Void) {
        let m: RecordingManifest? = lock.locked {
            guard var m = manifest else { return nil }
            change(&m, samples)
            manifest = m
            return m
        }
        if let m { try? store.save(m) }
    }

    private func publish() {
        sink.yield(lock.locked { snapshot })
    }

    private func watchSession() {
        #if canImport(AVFoundation) && !os(macOS)
        guard handlesInterruptions else { return }
        sessionWatcher?.cancel()
        sessionWatcher = Task { [weak self] in
            for await interruption in AudioSessionConfigurator.shared.interruptions() {
                guard let self else { return }
                switch interruption {
                case .began: await self.interrupt(reason: "interruption")
                case .ended(let shouldResume): if shouldResume { try? await self.resume() }
                }
            }
        }
        #endif
    }
}
