import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
import InferenceAudio
import InferenceSDK
import XCTest

/// Live end to end against the real API, skipped without a key:
///
///     INFERENCE_API_KEY=… LIVE_E2E=1 swift test --filter LiveE2ETests
///
/// LIVE_E2E_WAV=speech.wav  the file that stands in for the microphone (default: a tone)
/// LIVE_E2E_PLAY=1          also play what comes back on this Mac's speaker (PCMPlayer)
/// LIVE_E2E_MIC=1           the real microphone for 5 s instead (engine backend, voice
///                          processing, one engine shared with the PCMPlayer)
final class LiveE2ETests: XCTestCase {
    private func client() throws -> InferenceClient {
        let env = ProcessInfo.processInfo.environment
        guard env["LIVE_E2E"] == "1", let key = env["INFERENCE_API_KEY"], !key.isEmpty else {
            throw XCTSkip("set LIVE_E2E=1 and INFERENCE_API_KEY")
        }
        return InferenceClient(baseURL: URL(string: env["INFERENCE_API_URL"] ?? "https://api.inference.sh")!, apiKey: key)
    }

    #if canImport(AVFoundation)
    func testVoiceCallFromTheMicrophone() async throws {
        let client = try client()
        guard ProcessInfo.processInfo.environment["LIVE_E2E_MIC"] == "1" else { throw XCTSkip("set LIVE_E2E_MIC=1") }
        let engine = AVAudioEngine()
        let microphone = Microphone(backend: .engine, voiceProcessing: ProcessInfo.processInfo.environment["LIVE_E2E_VP"] != "0", engine: engine)
        let collected = CollectingSink()
        let call = try await LiveVoiceCall.start(
            client: client, request: ApiAppRunRequest(app: "infsh/voice-loop", input: ["effect": "echo"]),
            input: microphone, output: TeeSink(collected, PCMPlayer(engine: engine)), gate: nil)
        let reader = Task { for await event in call.events { if case .state(let s) = event { print("state", s) } } }
        for _ in 0..<1200 where call.session.state != .live { try await Task.sleep(nanoseconds: 100_000_000) }
        try await Task.sleep(nanoseconds: 5_000_000_000)
        call.hangUp()
        _ = await call.ended
        _ = await reader.value
        let counts = call.counts
        print("microphone \(microphone.activeBackend?.rawValue ?? "-"), peak \(microphone.peak), \(microphone.capturedDuration) s; sent \(counts.sent.frames), received \(counts.received.frames)")
        XCTAssertGreaterThan(counts.sent.frames, 150)
        XCTAssertGreaterThan(counts.received.frames, 100)
    }
    #endif

    /// infsh/voice-loop echoes every binary frame: a file goes in through
    /// LiveVoiceCall as if it were the microphone and comes back to the sink.
    func testVoiceCallRoundTrip() async throws {
        let client = try client()
        let env = ProcessInfo.processInfo.environment
        let wav = try env["LIVE_E2E_WAV"].map { URL(fileURLWithPath: $0) } ?? toneWAV(seconds: 3)
        let source = WAVFileSource(url: wav)
        let collected = CollectingSink()
        var sink: any AudioSink = collected
        #if canImport(AVFoundation)
        if env["LIVE_E2E_PLAY"] == "1" { sink = TeeSink(collected, PCMPlayer()) }
        #endif
        let call = try await LiveVoiceCall.start(
            client: client, request: ApiAppRunRequest(app: "infsh/voice-loop", input: ["effect": "echo"]),
            input: source, output: sink)
        print("task \(call.task?.id ?? "-"): in \(String(describing: call.inputFormat)), out \(String(describing: call.outputFormat))")
        let started = Date()
        let reader = Task {
            for await event in call.events {
                switch event {
                case .state(let state): print(String(format: "%5.2fs", Date().timeIntervalSince(started)), "state", state)
                case .patch(let patch): print("patch", patch)
                case .error(let field, let message): print("error", field ?? "-", message)
                default: break
                }
            }
        }
        do {
            // Live, then the whole file, then a moment for the echo to come back.
            for _ in 0..<1200 where !source.isRunning { try await Task.sleep(nanoseconds: 100_000_000) }
            while source.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        } catch {
            call.hangUp()
            throw error
        }
        call.hangUp()
        let end = await call.ended
        _ = await reader.value
        let counts = call.counts
        print("sent \(counts.sent.frames) frames (\(counts.sent.bytes) B), received \(counts.received.frames) (\(counts.received.bytes) B), played \(collected.played.value.count)")
        print("ended \(end.code) \(end.reason) byCaller=\(end.byCaller)")
        XCTAssertTrue(end.byCaller)
        XCTAssertGreaterThan(counts.sent.frames, 100)
        XCTAssertEqual(Double(counts.received.frames), Double(counts.sent.frames), accuracy: Double(counts.sent.frames) * 0.05)
        XCTAssertEqual(collected.played.value.count, counts.received.frames)
        XCTAssertEqual(collected.log.value.last, "stop")
        if let id = call.task?.id {
            let done = try await client.tasks.watch(id)
            print("task \(done.status == .completed ? "completed" : "status \(done.status.rawValue)")")
            XCTAssertEqual(done.status, .completed)
        }
    }
}

/// Hands every call to two sinks.
final class TeeSink: AudioSink, @unchecked Sendable {
    let a: any AudioSink, b: any AudioSink
    init(_ a: any AudioSink, _ b: any AudioSink) { self.a = a; self.b = b }
    func start(format: PCMFormat) throws { try a.start(format: format); try b.start(format: format) }
    func play(_ pcm: Data) { a.play(pcm); b.play(pcm) }
    func flush() { a.flush(); b.flush() }
    func stop() { a.stop(); b.stop() }
}
