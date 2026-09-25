// Usage example and end-to-end check for InferenceSDK:
//   INFERENCE_API_KEY=... swift run agent-run okaris/some-agent "hello" [chat_id]
// Streams POST /agents/run and prints assistant snapshots as they arrive.
// TTS_APP=inworld/text-to-speech-1-5-mini also synthesizes the reply and downloads
// the audio, which is what the voice app does on the phone.
// INTERRUPT_AFTER=N stops the chat after N snapshots (what pressing talk
// mid-reply does); the stream is expected to end with `cancelled`.
// STT_APP="elevenlabs/stt language_code=eng" STT_FILE=path.wav transcribes the
// file and uses the transcript as the message instead of <text>. App specs
// accept trailing key=value extra inputs, same as the app's Settings fields.

import Foundation
import InferenceSDK

signal(SIGPIPE, SIG_IGN) // Linux: a peer closing mid-write must surface as an error, not kill the process
let args = CommandLine.arguments
let env = ProcessInfo.processInfo.environment
guard args.count >= 3, let key = env["INFERENCE_API_KEY"], !key.isEmpty else {
    FileHandle.standardError.write(Data("usage: INFERENCE_API_KEY=... agent-run <namespace/name> <text> [chat_id]\n".utf8))
    exit(2)
}
let client = InferenceClient(baseURL: URL(string: env["INFERENCE_API_URL"] ?? "https://api.inference.sh")!, apiKey: key)
let interruptAfter = Int(env["INTERRUPT_AFTER"] ?? "") ?? 0

do {
    var text = args[2]
    if let spec = env["STT_APP"], !spec.isEmpty, let path = env["STT_FILE"], !path.isEmpty {
        let (app, extra) = parseAppSpec(spec)
        let audio = try Data(contentsOf: URL(fileURLWithPath: path))
        text = try await SpeechToText(client: client, app: app, extraInput: extra).transcribe(audio)
        print("STT \(app): \(text.debugDescription)")
    }
    let req = ApiAgentRunRequest(chatId: args.count > 3 ? args[3] : nil, agent: args[1], input: LLMInput(role: .user, text: text))
    var n = 0
    for try await msg in client.runAgentStream(req) {
        n += 1
        print("[\(n)] chat=\(msg.chatId) status=\(msg.status.rawValue) text=\(msg.text.debugDescription)")
        if n == interruptAfter {
            try await client.chats.stop(msg.chatId)
            print("chats.stop sent")
        }
        guard msg.status.isTerminal else { continue }
        if interruptAfter > 0 {
            let ok = msg.status == .cancelled
            print("INTERRUPT \(ok ? "OK" : "UNEXPECTED"): \(msg.status.rawValue)")
            exit(ok ? 0 : 1)
        }
        guard msg.status == .ready else { print("FAILED: \(msg.errorText ?? "?")"); exit(1) }
        print("OK: \(msg.text)")
        if let spec = env["TTS_APP"], !spec.isEmpty {
            let (app, extra) = parseAppSpec(spec)
            let tts = TextToSpeech(client: client, app: app, extraInput: extra)
            print("TTS \(app) spec: \(try await tts.resolveSpec())")
            for try await audio in tts.synthesize(msg.text) {
                print("TTS OK: \(audio.count) bytes, head \(audio.prefix(4).map { String(format: "%02x", $0) }.joined())")
            }
        }
        exit(0)
    }
    print("stream ended without terminal message")
    exit(1)
} catch {
    print("ERROR: \(error)")
    exit(1)
}
