import Foundation
import InferenceSDK

/// Live dictation: speech in, the transcript so far out while you talk, the
/// final text on release.
///
/// Give it an STT app spec ("xai/grok-stt", "elevenlabs/stt language_code=eng").
/// It finds the app's stream function (`LiveSpeechPlan`), starts it with
/// `client.live`, streams the audio in 20 ms frames at the rate the
/// function's schema declares, and publishes the transcript, the level and
/// the elapsed time on `updates`. `finish()` returns the final text: the
/// task's result when it lands in time, else the last patch.
///
/// When the app has no stream function, or the live session fails, the
/// audio is kept and `finish()` transcribes it with `SpeechToText` instead
/// (`fallbackToBatch`).
///
///     let transcriber = LiveTranscriber(client: client, app: "xai/grok-stt")
///     try await transcriber.start(source: Microphone())
///     Task { for await s in transcriber.updates { strip.show(s.transcript.settled, s.transcript.tail) } }
///     // release
///     let text = try await transcriber.finish()
///
/// Audio is captured at `captureFormat` (16 kHz mono) and resampled to the
/// function's rate, so capture starts at once, before the app is looked up.
public final class LiveTranscriber: @unchecked Sendable {
    public enum Phase: Equatable, Sendable {
        /// Looking up the app's functions.
        case resolving
        /// Starting the stream task.
        case connecting
        /// The relay took the socket; the app has not sent its first frame
        /// (a cold start can take a while). Audio is held until it does.
        case waiting
        /// Streaming: the transcript grows as you talk.
        case live
        /// Not streaming (the app has no stream function, or the session
        /// failed): the audio is kept and transcribed on `finish`.
        case recording
        /// Released: waiting for the final text.
        case finishing
        case ended
        case failed(String)
    }

    /// What a dictation UI shows.
    public struct Snapshot: Equatable, Sendable {
        public var phase: Phase
        public var transcript: LiveTranscript
        /// Meter level of the latest audio, 0...1 (`PCM16.meter` of its RMS).
        public var level: Float
        /// Seconds of audio captured.
        public var elapsed: TimeInterval

        public init(phase: Phase = .resolving, transcript: LiveTranscript = LiveTranscript(), level: Float = 0,
                    elapsed: TimeInterval = 0) {
            self.phase = phase
            self.transcript = transcript
            self.level = level
            self.elapsed = elapsed
        }

        /// The transcript shows while you talk (or is about to).
        public var isStreaming: Bool {
            switch phase {
            case .resolving, .connecting, .waiting, .live: return true
            case .recording, .finishing, .ended, .failed: return false
            }
        }
    }

    /// The app spec: "namespace/name[@version] key=value …".
    public let app: String
    /// The latest snapshot on every change, many times a second. A slow
    /// reader gets the newest one. Finishes after `finish` or `cancel`.
    public let updates: AsyncStream<Snapshot>
    /// Transcribe the kept audio with `SpeechToText` when the take did not
    /// stream (default true). Off, `finish` returns "" then.
    public var fallbackToBatch = true
    /// The format `start(source:)` asks the source for.
    public var captureFormat = PCMFormat.speech
    /// Takes shorter than this are dropped: over Bluetooth HFP the voice
    /// channel takes ¼–½ s to carry audio after key-down, and STT apps
    /// reject near-empty clips.
    public var minimumDuration: TimeInterval = 0.25
    /// Takes whose loudest sample stays below this are dropped as silence.
    public var minimumPeak: Float = 0.02
    /// How long `finish` waits for an app that has not come up yet before it
    /// falls back to transcribing the audio.
    public var liveWait: TimeInterval = 4
    /// How long `finish` waits for the task's result, when the last patch
    /// covers the speech and when it does not.
    public var resultWait: (complete: TimeInterval, incomplete: TimeInterval) = (2, 6)

    private let client: InferenceClient
    private let plans: LiveSpeechPlans
    private let log: @Sendable (String) -> Void
    private let sink: AsyncStream<Snapshot>.Continuation

    private let lock = NSLock()
    private var snapshot = Snapshot()
    /// nil: not resolved yet; .some(nil): no stream function.
    private var plan: LiveSpeechPlan??
    private var stream: LiveSpeechStream?
    /// Audio that arrived before the plan.
    private var early: [Data] = []
    /// Everything captured, for the batch fallback.
    private var kept = Data()
    private var rate = 0
    private var samples = 0
    private var peak: Float = 0
    private var done = false
    private var resolver: Task<Void, Never>?
    private var source: (any AudioSource)?
    private var pump: Task<Void, Never>?

    /// - Parameters:
    ///   - app: An STT app spec; key=value pairs are inputs (`parseAppSpec`).
    ///   - plans: Where resolved plans are cached (`LiveSpeechPlans.shared`).
    ///   - log: Diagnostics, one line at a time.
    public init(client: InferenceClient, app: String, plans: LiveSpeechPlans = .shared,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.client = client
        self.app = app
        self.plans = plans
        self.log = log
        (updates, sink) = AsyncStream.makeStream(of: Snapshot.self, bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        sink.finish()
    }

    /// The latest snapshot.
    public var current: Snapshot { lock.locked { snapshot } }

    /// Looks the app up ahead of time, so the first take streams at once.
    public static func prepare(client: InferenceClient, app: String, plans: LiveSpeechPlans = .shared) async {
        _ = try? await plans.plan(for: app, client: client)
    }

    /// Starts capturing from `source` (at `captureFormat`) and streaming.
    /// Returns once the source runs; throws when it cannot start.
    public func start(source: any AudioSource) async throws {
        resolve()
        let format = captureFormat
        let frames: AsyncThrowingStream<Data, Error>
        do {
            frames = try await source.start(format: format)
        } catch {
            cancel()
            throw error
        }
        let stopNow: Bool = lock.locked {
            self.source = source
            return done
        }
        if stopNow { source.stop() }
        let pump = Task { [weak self, log] in
            do {
                for try await frame in frames {
                    self?.append(PCM16.downmix(frame, channels: format.channels), sampleRate: format.sampleRate)
                }
            } catch {
                log("live: the audio source failed: \(error.localizedDescription)")
            }
        }
        lock.locked { self.pump = pump }
    }

    /// Starts without a source: feed audio with `append(_:sampleRate:)`.
    public func start() {
        resolve()
    }

    private func resolve() {
        let spec = app
        let (name, _) = parseAppSpec(spec)
        guard !name.isEmpty else { return setPlan(nil) }
        let task = Task { [weak self, plans, client, log] in
            do {
                let plan = try await plans.plan(for: spec, client: client)
                if plan == nil { log("live: \(name) has no stream function; transcribing on finish") }
                self?.setPlan(plan)
            } catch {
                log("live: could not read \(name): \(error.localizedDescription)")
                self?.setPlan(nil)
            }
        }
        lock.locked { resolver = task }
    }

    private func setPlan(_ plan: LiveSpeechPlan?) {
        lock.locked {
            guard self.plan == nil else { return }
            self.plan = .some(plan)
            if plan == nil {
                if !done { snapshot.phase = .recording }
                early = []
            } else if rate > 0 {
                let stream = makeStream()
                for pcm in early { stream?.append(pcm) }
                early = []
            }
        }
        publish()
    }

    /// Lock held. Creates and starts the stream once the plan and the rate are known.
    @discardableResult
    private func makeStream() -> LiveSpeechStream? {
        if let stream { return stream }
        guard !done, rate > 0, case .some(.some(let plan)) = plan else { return nil }
        let stream = LiveSpeechStream(client: client, plan: plan, sourceRate: rate, log: log)
        stream.liveWait = liveWait
        stream.resultWait = resultWait
        self.stream = stream
        snapshot.phase = .connecting
        stream.onChange = { [weak self] transcript, phase in self?.streamChanged(transcript, phase) }
        stream.start()
        return stream
    }

    private func streamChanged(_ transcript: LiveTranscript, _ phase: LiveSpeechStream.Phase) {
        lock.locked {
            snapshot.transcript = transcript
            switch phase {
            case .connecting: snapshot.phase = .connecting
            case .waiting: snapshot.phase = .waiting
            case .live: snapshot.phase = .live
            case .finishing: snapshot.phase = .finishing
            case .ended: if !done || snapshot.phase == .finishing { snapshot.phase = .ended }
            case .failed(let message):
                snapshot.phase = fallbackToBatch ? .recording : .failed(message)
                snapshot.transcript.error = message
            }
        }
        publish()
    }

    /// The next captured audio: mono 16-bit PCM at `sampleRate`, which stays
    /// the same for the take.
    public func append(_ pcm: Data, sampleRate: Int) {
        guard !pcm.isEmpty, sampleRate > 0 else { return }
        let level = PCM16.meter(PCM16.rms(pcm))
        let framePeak = PCM16.peak(pcm)
        let accepted: Bool = lock.locked {
            guard !done else { return false }
            if rate == 0 { rate = sampleRate }
            samples += pcm.count / 2
            peak = max(peak, framePeak)
            snapshot.level = level
            snapshot.elapsed = Double(samples) / Double(rate)
            if fallbackToBatch { kept.append(pcm) }
            switch plan {
            case .none: early.append(pcm)
            case .some(.none): break
            case .some(.some): makeStream()?.append(pcm)
            }
            return true
        }
        if accepted { publish() }
    }

    /// Release: stops the source, sends the rest, and returns the final
    /// text. "" when nothing was said (too short, silent, no words).
    /// Throws when the batch fallback's `SpeechToText` fails.
    public func finish() async throws -> String {
        // The source delivers what it captured, then its stream ends.
        let (source, pump) = lock.locked { (self.source, self.pump) }
        source?.stop()
        await pump?.value
        // A first take of a new app may still be looking it up.
        if lock.locked({ plan == nil }) {
            let resolver = lock.locked { self.resolver }
            _ = await withDeadline(2) { await resolver?.value }
        }
        let (stream, kept, rate, seconds, peak): (LiveSpeechStream?, Data, Int, TimeInterval, Float) = lock.locked {
            done = true
            return (self.stream, self.kept, self.rate, self.rate > 0 ? Double(self.samples) / Double(self.rate) : 0, self.peak)
        }
        defer { sink.finish() }

        guard seconds >= minimumDuration, peak >= minimumPeak else {
            log("live: \(String(format: "%.2f", seconds)) s, peak \(String(format: "%.3f", peak)): nothing to transcribe")
            stream?.cancel()
            setPhase(.ended)
            return ""
        }
        if let stream {
            setPhase(.finishing)
            if let text = await stream.finish(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lock.locked {
                    snapshot.transcript.apply(text)
                    snapshot.transcript.settle()
                    snapshot.phase = .ended
                }
                publish()
                return text
            }
            log("live: the stream gave no text")
        }
        guard fallbackToBatch, !kept.isEmpty else {
            setPhase(.ended)
            return ""
        }
        setPhase(.finishing)
        let (name, extra) = parseAppSpec(app)
        do {
            log("live: transcribing \(String(format: "%.1f", seconds)) s with \(name)")
            let wav = WAV.wrap(kept, format: PCMFormat(sampleRate: rate, channels: 1))
            let text = try await SpeechToText(client: client, app: name, extraInput: extra).transcribe(wav)
            lock.locked {
                snapshot.transcript.apply(text)
                snapshot.transcript.settle()
                snapshot.phase = .ended
            }
            publish()
            return text
        } catch {
            setPhase(.failed(error.localizedDescription))
            throw error
        }
    }

    /// Stops without a result: the source stops, the session closes, and a
    /// task whose app never came up is cancelled.
    public func cancel() {
        let (source, stream, resolver, pump): ((any AudioSource)?, LiveSpeechStream?, Task<Void, Never>?, Task<Void, Never>?) = lock.locked {
            done = true
            early = []
            kept = Data()
            snapshot.phase = .ended
            return (self.source, self.stream, self.resolver, self.pump)
        }
        source?.stop()
        pump?.cancel()
        resolver?.cancel()
        stream?.cancel()
        publish()
        sink.finish()
    }

    private func setPhase(_ phase: Phase) {
        lock.locked { snapshot.phase = phase }
        publish()
    }

    private func publish() {
        sink.yield(lock.locked { snapshot })
    }
}
