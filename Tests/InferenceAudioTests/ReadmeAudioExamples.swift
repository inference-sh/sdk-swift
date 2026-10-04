import Foundation
import InferenceAudio
import InferenceSDK
#if canImport(AVFoundation)
import AVFoundation
#endif

// The README's InferenceAudio code, compiled (never run) so the examples
// can't drift from the API. Keep in sync when either changes.
#if canImport(AVFoundation)
private enum ReadmeAudioExamples {
    @MainActor
    final class Strip {
        var settled = "", tail = "", level: Float = 0, elapsed: TimeInterval = 0
    }

    @MainActor
    static func dictation(client: InferenceClient, strip: Strip) async throws {
        let transcriber = LiveTranscriber(client: client, app: "xai/grok-stt")
        try await transcriber.start(source: Microphone())

        Task { @MainActor in
            for await snapshot in transcriber.updates {
                strip.settled = snapshot.transcript.settled
                strip.tail = snapshot.transcript.tail
                strip.level = snapshot.level
                strip.elapsed = snapshot.elapsed
            }
        }

        let text = try await transcriber.finish()
        print(text)
        await LiveTranscriber.prepare(client: client, app: "xai/grok-stt")
    }

    @MainActor
    static func pushToTalk(client: InferenceClient, chat: AgentChatSession) async throws {
        try AudioSessionConfigurator.shared.apply(.pushToTalk)

        let transcriber = LiveTranscriber(client: client, app: "xai/grok-stt")
        try await transcriber.start(source: Microphone(backend: .recorder))

        let text = try await transcriber.finish()
        if !text.isEmpty { await chat.sendMessage(text) }
    }

    static func voiceCall(client: InferenceClient) async throws {
        try AudioSessionConfigurator.shared.apply(.voiceChat)
        try await AudioSessionConfigurator.shared.activate()

        let engine = AVAudioEngine()
        let call = try await LiveVoiceCall.start(
            client: client,
            request: ApiAppRunRequest(app: "xai/grok-voice", input: ["voice": "eve"], function: "talk"),
            input: Microphone(backend: .engine, voiceProcessing: true, engine: engine),
            output: PCMPlayer(engine: engine)
        )
        for await event in call.events {
            if case .patch(let patch) = event { print(patch) }
        }
        call.isMuted = true
        call.hangUp()
    }

    static func recording(client: InferenceClient) async throws {
        let store = RecordingStore(root: RecordingStore.defaultRoot())
        let recovered = store.recoverInterrupted()
        print(recovered)

        try AudioSessionConfigurator.shared.apply(.record)
        try await AudioSessionConfigurator.shared.activate()
        let recorder = CrashSafeRecorder(store: store, source: Microphone())
        try await recorder.start(metadata: ["title": "standup"])
        if let recording = await recorder.stop() {
            let stt = SpeechToText(client: client, app: "elevenlabs/stt", extraInput: ["language_code": "eng"])
            let text = try await store.transcribe(recording, with: stt, encoding: .aac(bitRate: 32_000))
            let clip = try store.clipWAV(recording, from: 0, to: 16_000 * 30)
            print(text, clip.count)
        }
    }
}
#endif
