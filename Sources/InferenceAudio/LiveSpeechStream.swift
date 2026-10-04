// One take streamed into an STT app's stream function. The engine under
// LiveTranscriber, extracted from the inference.sh app (LiveSpeech).

import Foundation
import InferenceSDK

/// PCM in at any rate, resampled to the function's, cut into 20 ms frames
/// and sent once the app is there (frames before that wait); the transcript
/// so far out.
final class LiveSpeechStream: @unchecked Sendable {
    enum Phase: Equatable, Sendable {
        case connecting
        /// The relay took the socket; the app has not sent its first frame.
        case waiting
        case live
        /// Released: the last audio went out, the session is closing.
        case finishing
        case ended
        case failed(String)
    }

    /// Called on the stream's threads.
    var onChange: (@Sendable (LiveTranscript, Phase) -> Void)?
    let log: @Sendable (String) -> Void

    let plan: LiveSpeechPlan
    let sourceRate: Int
    /// How long `finish` waits for an app that has not come up yet.
    var liveWait: TimeInterval = 4
    /// How long `finish` waits for the task's result when the last patch
    /// already covers the speech, and when it does not. Measured after a
    /// release right at the end of speech: ElevenLabs 0.5 s, xAI 2.5 s,
    /// OpenAI 2.9 s, Inworld 5.2 s; the trailing words are only in the result.
    var resultWait: (complete: TimeInterval, incomplete: TimeInterval) = (2, 6)
    /// A patch this long after the last voiced frame went out covers it.
    var patchLag: TimeInterval = 0.6
    /// Frames held while the app comes up before the take counts as failed (60 s).
    var maxBacklogFrames = 3000

    private let client: InferenceClient
    private let audioQueue = DispatchQueue(label: "sh.inference.audio.livespeech", qos: .userInitiated)
    private let resampler: any PCMResampler
    private var framer: PCMFramer

    private let lock = NSLock()
    private var session: LiveSession?
    private var taskId: String?
    private var transcript = LiveTranscript()
    private var phase: Phase = .connecting
    private var backlog: [Data] = []
    private var isLive = false
    private var stopped = false
    private var liveWaiters: [CheckedContinuation<Bool, Never>] = []
    private var runner: Task<Void, Never>?
    private var sent = (frames: 0, bytes: 0)
    /// When the last frame with speech in it went out, and the last patch came.
    private var lastVoiceSent: Date?
    private var lastPatch: Date?

    init(client: InferenceClient, plan: LiveSpeechPlan, sourceRate: Int, log: @escaping @Sendable (String) -> Void) {
        self.client = client
        self.plan = plan
        self.sourceRate = sourceRate
        self.log = log
        resampler = makeResampler(from: sourceRate, to: plan.sampleRate)
        framer = PCMFramer(format: plan.format)
    }

    var currentPhase: Phase { lock.locked { phase } }

    /// Starts the stream task and dials its socket.
    func start() {
        runner = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        do {
            let request = ApiAppRunRequest(app: plan.app, input: .object(plan.input), function: plan.function)
            let (task, session) = try await client.live(
                request, options: OpenSocketOptions(inputSchema: plan.inputSchema, outputSchema: plan.outputSchema))
            let cancelled: Bool = lock.locked {
                self.session = session
                self.taskId = task.id
                return stopped && phase == .ended
            }
            log("live: \(plan.app) \(plan.function) task \(task.id)")
            if cancelled {
                session.close()
                try? await client.tasks.cancel(task.id)
                return
            }
            for await event in session.events { handle(event) }
            let end = await session.ended
            if !end.byCaller { fail("the live session ended: \(end.reason.isEmpty ? "code \(end.code)" : end.reason)") }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func handle(_ event: LiveEvent) {
        switch event {
        case .state(.waiting):
            update { if $0 == .connecting { $0 = .waiting } }
        case .state(.live):
            lock.locked { isLive = true }
            update { if $0 == .connecting || $0 == .waiting { $0 = .live } }
            audioQueue.async { [self] in
                let frames: [Data] = lock.locked { defer { backlog = [] }; return backlog }
                send(frames)
                resumeLiveWaiters(true)
            }
        case .patch(let patch):
            guard let value = patch[plan.textField] else { return }
            lock.locked { lastPatch = Date() }
            changeTranscript { $0.apply(value.stringValue ?? "") }
        case .clear(let field):
            if field == plan.textField { changeTranscript { $0.clear() } }
        case .error(let field, let message):
            log("live: app error \(field ?? "-"): \(message)")
            changeTranscript { $0.error = message }
        case .text(let text):
            log("live: text frame \(text.prefix(80))")
        case .state, .binary:
            break
        }
    }

    // MARK: Audio

    /// The next mono Int16 LE samples at `sourceRate`.
    func append(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        audioQueue.async { [self] in
            route(framer.append(resampler.process(pcm)))
        }
    }

    /// On the audio queue: send now, or hold until the app is there.
    private func route(_ frames: [Data]) {
        guard !frames.isEmpty else { return }
        let held: Int? = lock.locked {
            guard !isLive else { return nil }
            backlog.append(contentsOf: frames)
            return backlog.count
        }
        guard let held else { return send(frames) }
        if held > maxBacklogFrames { fail("the app did not come up in time") }
    }

    private func send(_ frames: [Data]) {
        guard let session = lock.locked({ self.session }) else { return }
        for frame in frames {
            if (try? session.sendField(plan.audioField, .binary(frame))) == true {
                let voiced = PCM16.rms(frame) > Self.voiceRMS
                lock.locked {
                    if voiced { lastVoiceSent = Date() }
                    sent.frames += 1
                    sent.bytes += frame.count
                }
            }
        }
    }

    // MARK: Release / cancel

    /// Release: the remaining audio goes out, the session closes, and the
    /// final text comes back: the task's result when it lands in time, else
    /// the last patch. Nil when the take failed or has no words.
    func finish() async -> String? {
        // The resampler's and framer's remainders.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            audioQueue.async { [self] in
                var frames = framer.append(resampler.flush())
                if let last = framer.flush() { frames.append(last) }
                route(frames)
                done.resume()
            }
        }
        if case .failed = currentPhase { return nil }
        guard await waitUntilLive(liveWait) else {
            log("live: the app did not come up")
            await abandon()
            return nil
        }
        // The backlog flush was queued before the waiters were resumed.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in audioQueue.async { done.resume() } }
        let (session, taskId, last, failed, sent): (LiveSession?, String?, LiveTranscript, Bool, (frames: Int, bytes: Int)) = lock.locked {
            stopped = true
            var isFailed = false
            if case .failed = phase { isFailed = true } else { phase = .finishing }
            return (self.session, self.taskId, self.transcript, isFailed, self.sent)
        }
        if failed { return nil }
        notify()
        log("live: sent \(sent.frames) frames (\(sent.bytes) bytes), closing")
        session?.close()
        var output: JSONValue?
        if let taskId {
            let wait = coversSpeech ? resultWait.complete : resultWait.incomplete
            let client = self.client
            output = await withDeadline(wait) { try await client.tasks.watch(taskId).output }
            if output == nil { log("live: no task result within \(Int(wait))s; using the last patch") }
        }
        let final = LiveTranscript.finalText(result: output, lastPatch: last)
        lock.locked {
            phase = .ended
            if let final { transcript.apply(final) }
            transcript.settle()
        }
        notify()
        return final
    }

    /// -40 dBFS: quieter frames count as silence.
    static let voiceRMS: Float = 0.01

    /// The last patch came well after the last speech went out, so it has
    /// all the words: the release need not wait long for the result.
    private var coversSpeech: Bool {
        lock.locked {
            guard let lastPatch, !transcript.isEmpty else { return false }
            guard let lastVoiceSent else { return true }
            return lastPatch.timeIntervalSince(lastVoiceSent) >= patchLag
        }
    }

    /// Closes without a result, and cancels the task when the app never came
    /// up (so it does not start late and bill for nothing).
    func cancel() {
        let (session, taskId, wasLive): (LiveSession?, String?, Bool) = lock.locked {
            stopped = true
            phase = .ended
            return (self.session, self.taskId, isLive)
        }
        session?.close()
        resumeLiveWaiters(false)
        if !wasLive, let taskId {
            let client = self.client
            Task { try? await client.tasks.cancel(taskId) }
        }
    }

    private func abandon() async {
        let taskId = lock.locked { self.taskId }
        cancel()
        runner?.cancel()
        if let taskId { try? await client.tasks.cancel(taskId) }
    }

    private func fail(_ message: String) {
        let first: Bool = lock.locked {
            if case .failed = phase { return false }
            if phase == .ended { return false }
            phase = .failed(message)
            return true
        }
        guard first else { return }
        log("live: failed: \(message)")
        notify()
        resumeLiveWaiters(false)
    }

    private func waitUntilLive(_ timeout: TimeInterval) async -> Bool {
        if lock.locked({ isLive }) { return true }
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let resolved: Bool? = lock.locked {
                if isLive { return true }
                if case .failed = phase { return false }
                if stopped && phase == .ended { return false }
                liveWaiters.append(c)
                return nil
            }
            if let resolved { c.resume(returning: resolved) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.resumeLiveWaiters(false) }
        }
        return ok && lock.locked { isLive }
    }

    private func resumeLiveWaiters(_ value: Bool) {
        let waiters: [CheckedContinuation<Bool, Never>] = lock.locked { defer { liveWaiters = [] }; return liveWaiters }
        waiters.forEach { $0.resume(returning: value) }
    }

    private func update(_ change: (inout Phase) -> Void) {
        lock.locked { change(&phase) }
        notify()
    }

    private func changeTranscript(_ change: (inout LiveTranscript) -> Void) {
        lock.locked { change(&transcript) }
        notify()
    }

    private func notify() {
        let (t, p) = lock.locked { (transcript, phase) }
        onChange?(t, p)
    }
}
