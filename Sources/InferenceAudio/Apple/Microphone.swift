#if canImport(AVFoundation)
import AVFoundation
import Foundation
import InferenceSDK

/// The microphone as an `AudioSource`: 16-bit PCM frames of about 20 ms at
/// the format asked for (a live function's input: `pcmFormat(binaryLiveField(live)?.media)`),
/// resampled and downmixed on the way.
///
/// Two ways to capture, behind the one API (`Backend`):
///
/// - **engine**: an AVAudioEngine input tap, optionally with voice
///   processing (echo cancellation and gain control, for calls on the
///   built-in route; share the engine with `PCMPlayer` so it cancels what
///   the call plays).
/// - **recorder**: AVAudioRecorder writing a 16 kHz mono 16-bit WAV, tailed
///   as it grows (`WAVFileTailer`). On iOS over a Bluetooth HFP route (a
///   speaker mic) while Apple's PushToTalk framework owns the session
///   (`.playAndRecord`/`.voiceChat`), an engine input tap never fires: no
///   callbacks, though the engine says it runs and the route says
///   BluetoothHFP. A recorder records from whatever the route provides, so
///   it is the backend there.
///
/// `.automatic` (the default) takes the recorder when the session's input is
/// Bluetooth HFP and the engine otherwise; pass `.recorder` for PushToTalk
/// whatever the route. Over HFP the voice channel takes ¼–½ s to carry audio
/// after key-down: play a go-ahead tone, and drop takes that are too short
/// or near silent (`peak`, `capturedDuration`; `LiveTranscriber` does).
///
/// The audio session is the app's: on iOS apply a preset and activate it
/// first (`AudioSessionConfigurator`). The microphone asks for permission
/// when it has not been asked yet.
public final class Microphone: AudioSource, @unchecked Sendable {
    public enum Backend: String, Sendable, Equatable {
        /// The recorder over a Bluetooth HFP input, the engine otherwise.
        case automatic
        /// AVAudioEngine input tap (voice processing optional).
        case engine
        /// AVAudioRecorder to a WAV file, tailed (Bluetooth HFP, PushToTalk).
        case recorder
    }

    public let backend: Backend
    /// Echo cancellation and gain control on the engine backend.
    public let voiceProcessing: Bool
    /// Also keep what is captured as a 16-bit WAV here: at the frame format
    /// on the engine backend, as recorded (16 kHz) on the recorder backend.
    /// Finished when `stop` returns.
    public var recordingURL: URL? {
        get { lock.locked { savedURL } }
        set { lock.locked { savedURL = newValue } }
    }

    private let sharedEngine: AVAudioEngine?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "sh.inference.audio.microphone", qos: .userInitiated)
    private var savedURL: URL?
    private var capture: Capture?
    private var lastPeak: Float = 0
    private var lastBytes = 0
    private var lastFormat: PCMFormat?
    private var resolved: Backend?

    /// - Parameters:
    ///   - backend: How to capture (see `Backend`).
    ///   - voiceProcessing: Echo cancellation on the engine backend (calls).
    ///   - engine: An engine to share with a `PCMPlayer`, so voice processing
    ///     cancels what it plays. Nil: the microphone runs its own.
    ///   - recordingURL: Also save the capture as a WAV here.
    public init(backend: Backend = .automatic, voiceProcessing: Bool = false, engine: AVAudioEngine? = nil,
                recordingURL: URL? = nil) {
        self.backend = backend
        self.voiceProcessing = voiceProcessing
        sharedEngine = engine
        savedURL = recordingURL
        // A shared engine gets its input now, before a player starts it: an
        // input node first touched on a running engine delivers nothing until
        // the engine restarts, which drops what the player queued. Voice
        // processing too can only be turned on while the engine is stopped.
        if let engine, !engine.isRunning {
            let input = engine.inputNode
            if voiceProcessing, !input.isVoiceProcessingEnabled { try? input.setVoiceProcessingEnabled(true) }
        }
    }

    /// The backend `.automatic` picks now: the recorder when the audio
    /// session's input is Bluetooth HFP (iOS, watchOS), the engine otherwise.
    public static func resolve(_ backend: Backend) -> Backend {
        guard backend == .automatic else { return backend }
        return AudioSessionConfigurator.shared.currentRoute.isBluetoothHFPInput ? .recorder : .engine
    }

    /// Asks for the microphone if the user has not been asked; true when allowed.
    public static func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    /// The backend of the last capture.
    public var activeBackend: Backend? { lock.locked { resolved } }
    /// The loudest sample of the last capture so far, 0...1. About 0 means
    /// the route delivered no voice.
    public var peak: Float { lock.locked { capture?.peak ?? lastPeak } }
    /// Seconds captured by the last capture so far.
    public var capturedDuration: TimeInterval {
        lock.locked {
            guard let format = capture?.format ?? lastFormat else { return 0 }
            return format.duration(ofBytes: capture?.bytes ?? lastBytes)
        }
    }

    // MARK: - AudioSource

    public func start(format: PCMFormat) async throws -> AsyncThrowingStream<Data, Error> {
        guard format.sampleRate > 0, format.channels > 0 else {
            throw AudioError.unsupportedFormat("\(format.sampleRate) Hz × \(format.channels)")
        }
        guard await Self.requestPermission() else { throw AudioError.permissionDenied }
        let backend = Self.resolve(self.backend)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        let capture = Capture(format: format, continuation: continuation)
        let url: URL? = try lock.locked {
            guard self.capture == nil else { throw AudioError.alreadyRunning }
            self.capture = capture
            resolved = backend
            return savedURL
        }
        do {
            switch backend {
            case .recorder: try startRecorder(capture, saveTo: url)
            case .engine, .automatic: try startEngine(capture, saveTo: url)
            }
        } catch {
            lock.locked { self.capture = nil }
            throw error
        }
        continuation.onTermination = { [weak self, weak capture] _ in
            guard let self, let capture else { return }
            // Not inline: a capture that failed finishes its stream on the queue `stop` syncs on.
            DispatchQueue.global().async { self.stop(capture) }
        }
        return stream
    }

    public func stop() {
        guard let capture = lock.locked({ self.capture }) else { return }
        stop(capture)
    }

    /// Records to a WAV file without streaming: `stop` finishes the file.
    /// The engine backend writes it at `format`; the recorder at 16 kHz.
    public func record(to url: URL, format: PCMFormat = .speech) async throws {
        recordingURL = url
        let frames = try await start(format: format)
        let drain = Task { for try await _ in frames {} }
        lock.locked { capture?.drain = drain }
    }

    // MARK: - Engine

    private func startEngine(_ capture: Capture, saveTo url: URL?) throws {
        let engine = sharedEngine ?? AVAudioEngine()
        capture.engine = engine
        capture.ownsEngine = sharedEngine == nil
        if let url { capture.writer = try WAVWriter(url: url, format: capture.format) }
        let input = engine.inputNode
        if voiceProcessing && !input.isVoiceProcessingEnabled {
            // Only on a stopped engine; a shared one that plays restarts below.
            if engine.isRunning { engine.stop() }
            try input.setVoiceProcessingEnabled(true)
        }
        try installTap(capture)
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        } catch {
            input.removeTap(onBus: 0)
            throw AudioError.inputUnavailable(error.localizedDescription)
        }
        // A route or format change stops the engine; start it again on the new input.
        capture.observer = ObserverToken(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self, weak capture] _ in
            guard let self, let capture else { return }
            self.queue.async { self.restartEngine(capture) }
        })
    }

    private func installTap(_ capture: Capture) throws {
        guard let engine = capture.engine else { return }
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw AudioError.inputUnavailable("no input (on iOS, apply an AudioSessionConfigurator preset and activate it first)")
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(capture.format.sampleRate),
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: target) else {
            throw AudioError.unsupportedFormat("\(inFormat) → \(capture.format.sampleRate) Hz")
        }
        converter.downmix = true
        let ratio = target.sampleRate / inFormat.sampleRate
        let queue = self.queue
        // ~21 ms at 48 kHz: frames go out about as fast as they are captured.
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(inFormat.sampleRate / 50), format: inFormat) { [weak capture] buffer, _ in
            guard let capture else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            _ = converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard out.frameLength > 0, let channel = out.int16ChannelData?[0] else { return }
            let pcm = Data(bytes: channel, count: Int(out.frameLength) * 2)
            queue.async { capture.deliver(pcm, save: true) }
        }
    }

    private func restartEngine(_ capture: Capture) {
        guard lock.locked({ self.capture === capture }), let engine = capture.engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        do {
            try installTap(capture)
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        } catch {
            capture.fail(error)
            lock.locked { if self.capture === capture { self.capture = nil } }
        }
    }

    // MARK: - Recorder

    private func startRecorder(_ capture: Capture, saveTo url: URL?) throws {
        let file = url ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("microphone-\(UUID().uuidString.prefix(8)).wav")
        capture.recorderFile = file
        capture.deleteRecorderFile = url == nil
        // 16 kHz mono 16-bit: the HFP voice channel's own rate (no resampling
        // there), and what STT apps take as is. The recorder converts from
        // the built-in mic's rate when needed.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: file, settings: settings)
        } catch {
            throw AudioError.inputUnavailable(error.localizedDescription)
        }
        guard recorder.record() else {
            throw AudioError.inputUnavailable("the recorder refused to start (on iOS, apply an AudioSessionConfigurator preset and activate it first)")
        }
        capture.recorder = recorder
        let tailer = WAVFileTailer(url: file)
        let queue = self.queue
        tailer.onAudio = { [weak capture] pcm, format in
            guard let capture else { return }
            queue.async { capture.deliverRecorded(pcm, rate: format.sampleRate) }
        }
        tailer.onError = { [weak capture] error in
            queue.async { capture?.fail(error) }
        }
        capture.tailer = tailer
        tailer.start()
    }

    // MARK: - Stopping

    private func stop(_ capture: Capture) {
        let current: Bool = lock.locked {
            guard self.capture === capture else { return false }
            self.capture = nil
            return true
        }
        guard current else { return }
        if let observer = capture.observer { NotificationCenter.default.removeObserver(observer.token) }
        if let engine = capture.engine {
            engine.inputNode.removeTap(onBus: 0)
            if capture.ownsEngine { engine.stop() }
        }
        if let recorder = capture.recorder {
            recorder.stop()            // finishes the file's header
            capture.tailer?.finish()   // delivers the rest of it (queued below)
        }
        queue.sync { capture.finish() }
        if capture.deleteRecorderFile, let file = capture.recorderFile {
            try? FileManager.default.removeItem(at: file)
        }
        lock.locked {
            lastPeak = capture.peak
            lastBytes = capture.bytes
            lastFormat = capture.format
        }
    }
}

/// One capture's state; touched on the microphone's queue.
private final class Capture: @unchecked Sendable {
    let format: PCMFormat
    let continuation: AsyncThrowingStream<Data, Error>.Continuation
    var framer: PCMFramer
    var engine: AVAudioEngine?
    var ownsEngine = false
    var observer: ObserverToken?
    var writer: WAVWriter?
    var recorder: AVAudioRecorder?
    var tailer: WAVFileTailer?
    var recorderFile: URL?
    var deleteRecorderFile = false
    var resampler: (any PCMResampler)?
    var drain: Task<Void, Error>?
    private let lock = NSLock()
    private var loudest: Float = 0
    private var captured = 0
    private var finished = false

    init(format: PCMFormat, continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.format = format
        self.continuation = continuation
        framer = PCMFramer(format: format)
    }

    var peak: Float { lock.locked { loudest } }
    var bytes: Int { lock.locked { captured } }

    /// Mono 16-bit PCM at the target rate.
    func deliver(_ pcm: Data, save: Bool) {
        guard !finished, !pcm.isEmpty else { return }
        let framePeak = PCM16.peak(pcm)
        lock.locked {
            loudest = max(loudest, framePeak)
            captured += pcm.count * format.channels
        }
        if save { try? writer?.append(PCM16.upmix(pcm, channels: format.channels)) }
        for frame in framer.append(PCM16.upmix(pcm, channels: format.channels)) { continuation.yield(frame) }
    }

    /// Mono 16-bit PCM at the recorder's rate.
    func deliverRecorded(_ pcm: Data, rate: Int) {
        if resampler == nil { resampler = makeResampler(from: rate, to: format.sampleRate) }
        deliver(resampler?.process(pcm) ?? pcm, save: false)
    }

    func fail(_ error: Error) {
        guard !finished else { return }
        finished = true
        try? writer?.close()
        continuation.finish(throwing: error)
    }

    func finish() {
        if let rest = resampler?.flush() { deliver(rest, save: false) }
        guard !finished else { return }
        if let last = framer.flush() { continuation.yield(last) }
        finished = true
        try? writer?.close()
        continuation.finish()
    }
}
#endif
