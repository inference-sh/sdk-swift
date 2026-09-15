// Usage example and end-to-end check for InferenceSDK:
//   INFERENCE_API_KEY=... swift run agent-run okaris/some-agent "hello"
// Streams POST /agents/run and prints assistant snapshots as they arrive.

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
        for try await msg in client.runAgentStream(req) {
            n += 1
            print("[\(n)] chat=\(msg.chatId) status=\(msg.status.rawValue) text=\(msg.text.debugDescription)")
            if msg.status.isTerminal {
                print(msg.status == .ready ? "OK: \(msg.text)" : "FAILED: \(msg.errorText ?? "?")")
                exit(msg.status == .ready ? 0 : 1)
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
