// Usage example and end-to-end check for InferenceSDK:
//   INFERENCE_API_KEY=... swift run agent-run okaris/some-agent "hello"
// Streams POST /agents/run and prints assistant snapshots as they arrive.
// With TTS_APP=infsh/kokoro-tts the reply is also synthesized via POST /run
// and the audio downloaded, which is what the voice app does on the phone.
// With INTERRUPT_AFTER=N the chat is stopped after N snapshots (what pressing
// talk mid-reply does); the stream is expected to end with `cancelled`.

import Foundation
import InferenceSDK

let args = CommandLine.arguments
guard args.count >= 3, let key = ProcessInfo.processInfo.environment["INFERENCE_API_KEY"], !key.isEmpty else {
    FileHandle.standardError.write(Data("usage: INFERENCE_API_KEY=... agent-run <namespace/name> <text> [chat_id]\n".utf8))
    exit(2)
}
let base = ProcessInfo.processInfo.environment["INFERENCE_API_URL"] ?? "https://api.inference.sh"
let client = InferenceClient(baseURL: URL(string: base)!, apiKey: key)
let req = ApiAgentRunRequest(chatId: args.count > 3 ? args[3] : nil, agent: args[1], input: LLMInput(role: .user, text: args[2]))

let sem = DispatchSemaphore(value: 0)
Task {
    defer { sem.signal() }
    do {
        var n = 0
        let interruptAfter = Int(ProcessInfo.processInfo.environment["INTERRUPT_AFTER"] ?? "") ?? 0
        for try await msg in client.runAgentStream(req) {
            n += 1
            print("[\(n)] chat=\(msg.chatId) status=\(msg.status.rawValue) text=\(msg.text.debugDescription)")
            if interruptAfter > 0, n == interruptAfter {
                try await client.stopChat(msg.chatId)
                print("stopChat sent")
            }
            if msg.status.isTerminal, interruptAfter > 0 {
                print(msg.status == .cancelled ? "INTERRUPT OK: \(msg.status.rawValue)" : "INTERRUPT UNEXPECTED: \(msg.status.rawValue)")
                exit(msg.status == .cancelled ? 0 : 1)
            }
            if msg.status.isTerminal {
                guard msg.status == .ready else { print("FAILED: \(msg.errorText ?? "?")"); exit(1) }
                print("OK: \(msg.text)")
                if let app = ProcessInfo.processInfo.environment["TTS_APP"], !app.isEmpty {
                    let tts = TextToSpeech(client: client, app: app)
                    print("TTS \(app) input key: \(try await tts.resolveInputKey())")
                    for try await audio in tts.synthesize(msg.text) {
                        let head = audio.prefix(4).map { String(format: "%02x", $0) }.joined()
                        print("TTS OK: \(audio.count) bytes, head \(head)")
                    }
                }
                exit(0)
            }
        }
        print("stream ended without terminal message")
        exit(1)
    } catch {
        print("ERROR: \(error)")
        exit(1)
    }
}
sem.wait()
