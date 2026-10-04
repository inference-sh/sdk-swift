import Foundation
import InferenceSDK

/// A voice call with a stream app: wires an `AudioSource` (the microphone)
/// and an `AudioSink` (the speaker) to a `LiveSession` by the function's
/// schemas, the way the web app's live page does.
///
/// - `.state(.live)`: the source starts at the input's PCM format and its
///   frames go out through a `SilenceGate` (the relay keeps only 64 frames
///   for an app that is not there yet, so nothing is sent earlier).
/// - `.binary`: played by the sink, at the output's PCM format.
/// - `.clear` for the output's audio field: the sink drops what it queued
///   (the user talked over the answer).
/// - `.state(.ended)`: source and sink stop.
///
/// Every event is passed on through `events` after the call acted on it,
/// so the app still sees patches, errors and state. The call owns the
/// session's event stream: read `events`, not `session.events`.
///
///     let call = try await LiveVoiceCall.start(client: client,
///         request: ApiAppRunRequest(app: "xai/grok-voice", input: ["voice": "eve"], function: "talk"),
///         input: Microphone(voiceProcessing: true), output: PCMPlayer())
///     for await event in call.events { if case .patch(let p) = event { show(p) } }
public final class LiveVoiceCall: @unchecked Sendable {
    public let session: LiveSession
    /// The stream task, when the call started it.
    public let task: TaskResultDTO?
    /// The session's events, in order, after the call acted on them. One reader.
    public let events: AsyncStream<LiveEvent>
    /// The input's binary live field and its format (nil: the function takes no audio).
    public let inputField: LiveField?
    public let inputFormat: PCMFormat?
    /// The output's binary live field and its format (nil: the function sends no audio).
    public let outputField: LiveField?
    public let outputFormat: PCMFormat?

    private let input: (any AudioSource)?
    private let output: (any AudioSink)?
    private let sink: AsyncStream<LiveEvent>.Continuation
    private let lock = NSLock()
    private var gate: SilenceGate?
    private var muted = false
    private var levels: (input: Float, output: Float) = (0, 0)
    private var sent = (frames: 0, bytes: 0)
    private var received = (frames: 0, bytes: 0)
    private var inputStarted = false
    private var outputStarted = false
    private var audioStopped = false
    private var pump: Task<Void, Never>?
    private var reader: Task<Void, Never>?

    /// Wires a session that is already open. Pass the function's schemas
    /// (`AppFunction.inputSchema`/`outputSchema`); a nil `gate` sends every
    /// frame, silence included.
    public init(session: LiveSession, task: TaskResultDTO? = nil, input: (any AudioSource)?, output: (any AudioSink)?,
                inputSchema: JSONValue?, outputSchema: JSONValue?, gate: SilenceGate? = SilenceGate()) {
        self.session = session
        self.task = task
        self.input = input
        self.output = output
        self.gate = gate
        inputField = binaryLiveField(splitLiveSchema(inputSchema).live)
        outputField = binaryLiveField(splitLiveSchema(outputSchema).live)
        inputFormat = pcmFormat(inputField?.media)
        outputFormat = pcmFormat(outputField?.media)
        (events, sink) = AsyncStream.makeStream(of: LiveEvent.self)
        reader = Task { [weak self] in
            for await event in session.events {
                guard let self else { return }
                self.handle(event)
            }
            self?.sessionEnded()
        }
    }

    deinit {
        reader?.cancel()
        pump?.cancel()
        sink.finish()
    }

    /// Starts `request`'s stream function and wires it up. The function's
    /// schemas come from the app (`request.function`, else its stream function).
    public static func start(client: InferenceClient, request: ApiAppRunRequest, input: (any AudioSource)?,
                             output: (any AudioSink)?, gate: SilenceGate? = SilenceGate()) async throws -> LiveVoiceCall {
        let functions = try await client.apps.getByName(request.app ?? "").version?.functions ?? [:]
        let name = request.function ?? functions.filter { $0.value.kind == .stream }.keys.sorted().first
        guard let name, let function = functions[name] else {
            throw InferenceError.transport("\(request.app ?? "the app") has no stream function")
        }
        var request = request
        request.function = name
        let (task, session) = try await client.live(
            request, options: OpenSocketOptions(inputSchema: function.inputSchema, outputSchema: function.outputSchema))
        return LiveVoiceCall(session: session, task: task, input: input, output: output,
                             inputSchema: function.inputSchema, outputSchema: function.outputSchema, gate: gate)
    }

    /// Mutes the microphone: frames are captured (the level reads 0) and not sent.
    public var isMuted: Bool {
        get { lock.locked { muted } }
        set { lock.locked { muted = newValue } }
    }

    /// Peak level of the last frame sent and the last frame played, 0...1.
    public var level: (input: Float, output: Float) { lock.locked { levels } }

    /// Frames and bytes sent and received so far.
    public var counts: (sent: (frames: Int, bytes: Int), received: (frames: Int, bytes: Int)) {
        lock.locked { (sent: sent, received: received) }
    }

    /// Ends the call: the function returns and the task completes.
    public func hangUp() {
        session.close()
    }

    /// How the call ended; waits until it has.
    public var ended: LiveEnd {
        get async { await session.ended }
    }

    private func handle(_ event: LiveEvent) {
        switch event {
        case .state(.live):
            startOutput()
            startInput()
        case .binary(let pcm):
            let peak = PCM16.peak(pcm)
            let output: (any AudioSink)? = lock.locked {
                received.frames += 1
                received.bytes += pcm.count
                levels.output = peak
                return outputStarted ? self.output : nil
            }
            output?.play(pcm)
        case .clear(let field):
            if field == outputField?.key {
                lock.locked { levels.output = 0 }
                output?.flush()
            }
        case .state(.ended):
            stopAudio()
        default:
            break
        }
        sink.yield(event)
    }

    private func startOutput() {
        guard let output, let format = outputFormat else { return }
        do {
            try output.start(format: format)
            lock.locked { outputStarted = true }
        } catch {
            sink.yield(.error(field: outputField?.key, message: "the speaker could not start: \(error.localizedDescription)"))
        }
    }

    private func startInput() {
        guard let input, let field = inputField, let format = inputFormat else { return }
        let begin: Bool = lock.locked {
            guard !inputStarted else { return false }
            inputStarted = true
            return true
        }
        guard begin else { return }
        let session = self.session
        let pump = Task { [weak self] in
            do {
                let frames = try await input.start(format: format)
                for try await frame in frames {
                    guard let self else { break }
                    if self.shouldSend(frame) { session.sendBinary(frame) }
                }
            } catch {
                self?.sink.yield(.error(field: field.key, message: "the microphone failed: \(error.localizedDescription)"))
            }
        }
        lock.locked { self.pump = pump }
    }

    private func shouldSend(_ frame: Data) -> Bool {
        let peak = PCM16.peak(frame)
        return lock.locked {
            if muted {
                levels.input = 0
                return false
            }
            levels.input = peak
            if gate?.pass(level: peak) == false { return false }
            sent.frames += 1
            sent.bytes += frame.count
            return true
        }
    }

    private func stopAudio() {
        let (input, output, started, already): ((any AudioSource)?, (any AudioSink)?, Bool, Bool) = lock.locked {
            defer { audioStopped = true }
            return (inputStarted ? self.input : nil, self.output, outputStarted, audioStopped)
        }
        guard !already else { return }
        input?.stop()
        if started { output?.stop() }
        lock.locked { levels = (0, 0) }
    }

    private func sessionEnded() {
        stopAudio()
        sink.finish()
    }
}
