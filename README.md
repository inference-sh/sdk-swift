# InferenceSDK — ai inference api for swift

[![CI](https://github.com/inference-sh/sdk-swift/actions/workflows/ci.yml/badge.svg)](https://github.com/inference-sh/sdk-swift/actions/workflows/ci.yml)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS%2017%20%7C%20macOS%2014%20%7C%20Linux-lightgrey.svg)](#requirements)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

official swift sdk for [inference.sh](https://inference.sh) — the ai agent runtime for serverless ai inference.

run ai apps, chat with ai agents, and stream their output from ios, macos and server-side swift. same api surface as the [javascript](https://github.com/inference-sh/sdk-js) and [python](https://github.com/inference-sh/sdk-py) sdks, with swift concurrency (`async`/`await`, `AsyncThrowingStream`) and fully typed `Codable` models generated from the api.

## Installation

Swift Package Manager. In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/inference-sh/sdk-swift", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "InferenceSDK", package: "sdk-swift"),
    ]),
]
```

Or in Xcode: **File → Add Package Dependencies…** and paste `https://github.com/inference-sh/sdk-swift`.

## Requirements

- Swift 5.9+
- iOS 17+ / macOS 14+
- Linux (Foundation + FoundationNetworking; no Apple-only frameworks in the library)

## Getting an API Key

Get your API key from the [inference.sh dashboard](https://app.inference.sh/settings/keys).

Don't ship a raw key inside an app binary for other people to use. For a public app, call the api from your own backend (or proxy it) and hand the client a short-lived key.

## Quick Start

```swift
import InferenceSDK

let client = InferenceClient(apiKey: "your-api-key")

// Run an app and wait for the result
let task = try await client.tasks.run(ApiAppRunRequest(
    app: "infsh/flux-schnell",
    input: ["prompt": "a lighthouse at dawn, watercolor"]
))

print(task.output)
```

`run` returns the finished task. A failed task throws `TaskRunError.failed`, a cancelled one `TaskRunError.cancelled`.

## Running Apps

### Waiting for the result

```swift
let task = try await client.tasks.run(ApiAppRunRequest(
    app: "my-app",
    input: ["prompt": "Generate something amazing"]
))
```

`input` and `setup` are `JSONValue`, which takes Swift literals directly: strings, numbers, booleans, arrays, dictionaries and `nil`.

### Setup parameters

Setup parameters configure the app instance (e.g. model selection). Workers with matching setup are "warm" and skip setup:

```swift
let task = try await client.tasks.run(ApiAppRunRequest(
    app: "my-app",
    setup: ["model": "schnell"],
    input: ["prompt": "hello"]
))
```

### Real-time updates

`run` follows the task's stream by default and reports every change:

```swift
let task = try await client.tasks.run(
    ApiAppRunRequest(app: "my-app", input: ["prompt": "hello"]),
    options: TaskRunOptions(
        onUpdate: { task in print("status:", task.status.rawValue) },
        onDelta: { delta, seq in print("delta \(seq):", delta) }
    )
)
```

Pass `stream: false` to poll the task status instead (`pollIntervalMs`, default 2000).

### Fire and forget

```swift
let task = try await client.tasks.run(
    ApiAppRunRequest(app: "my-app", input: ["prompt": "hello"]),
    options: TaskRunOptions(wait: false)
)
print("started", task.id)

// later
let current = try await client.tasks.get(task.id)
```

### Managing tasks

```swift
try await client.tasks.cancel(taskId)
let logs = try await client.tasks.getLogs(taskId)
let page = try await client.tasks.list(CursorListRequest(limit: 20))
```

## Files

Upload a file and pass its uri as input. Uploads go straight to storage through a presigned url:

```swift
let file = try await client.files.upload(imageData, filename: "photo.jpg", contentType: "image/jpeg")

let task = try await client.tasks.run(ApiAppRunRequest(
    app: "my-image-app",
    input: ["image": .string(file.uri)]
))
```

App outputs that are files come back as urls. `TaskResultDTO.fileURL(_:)` reads either shape apps use (a bare url or `{"uri": ...}`), and `client.download(_:)` fetches the bytes.

## Agents

### Chat sessions

`AgentChatSession` is the full agent chat state machine: it creates the chat on the first message, follows the chat's server-sent event stream, applies token deltas to the right message, reconnects, and pages older messages. It's the same model the inference.sh web app runs on (a port of `sdk-js`'s agent actions and reducer), and it's UI-framework free, so you can drive SwiftUI, UIKit, AppKit or a CLI from it.

```swift
import InferenceSDK

@MainActor
func chat() async {
    let session = AgentChatSession(client: client, agent: "my-team/support-agent@latest")

    session.onChange = { state in
        // Every state transition: messages, chat status, connection, errors.
        if let last = state.messages.last { print(last.role.rawValue, last.text) }
    }
    session.callbacks.onTurnEnd = { chat in print("agent finished") }

    await session.sendMessage("What can you help me with?")
}
```

`AgentChatSession` is `@MainActor`. `state` is an `AgentChatState`:

| Field | What it holds |
| --- | --- |
| `messages` | `[ChatMessageDTO]`, in order. `message.text` joins the text blocks; `content` has reasoning, images, files and errors. |
| `chat` | The `ChatDTO`, including busy state and queued messages. |
| `connectionStatus` | `.idle`, `.connecting`, `.streaming` or `.error` |
| `error` | The last error, if any. `clearError()` resets it. |
| `hasOlderMessages` | More history to page in with `loadOlderMessages()`. |

Sending while the agent is still working queues the message on the server; it runs when the current turn ends. `cancelMessage(_:)` removes a queued one.

### SwiftUI

Mirror the state into an `ObservableObject` (or `@Observable`) and render from it:

```swift
@MainActor
final class ChatModel: ObservableObject {
    @Published private(set) var state = AgentChatState.initial
    let session: AgentChatSession

    init(client: InferenceClient, agent: String) {
        session = AgentChatSession(client: client, agent: agent)
        session.onChange = { [weak self] in self?.state = $0 }
    }

    func send(_ text: String) { Task { await session.sendMessage(text) } }
    func stop() { session.stopGeneration() }
}
```

### Tools, approvals and interrupts

When a tool call needs the user, its invocation (`message.toolInvocations`) waits in `awaitingApproval` or `awaitingInput`:

```swift
try await session.approveTool(invocation.id)
try await session.rejectTool(invocation.id, reason: "not now")
try await session.alwaysAllowTool(invocation.id, toolName: invocation.function.name)

// client-side tools and widget forms
try await session.submitToolResult(invocation.id, result: #"{"form_data":{"size":"large"}}"#)

// run-level interrupts (client.agents.listRunInterrupts(runId))
try await session.resolveInterrupt(interruptId, decision: "allow")   // or "deny"
```

Tools that render UI (A2UI widgets) carry it on `invocation.widget`, or in the result; `Widget.parse(string:)` reads every format the web app accepts.

### Resuming a chat

```swift
session.setChatId(existingChatId)   // loads the chat and its latest messages, then streams
let more = await session.loadOlderMessages()
```

### One-shot runs

Without a session, `runAgentStream` posts a message and streams snapshots of the assistant reply until it finishes:

```swift
let request = ApiAgentRunRequest(agent: "my-team/support-agent@latest", input: LLMInput(text: "hello"))
for try await message in client.runAgentStream(request) {
    print(message.status.rawValue, message.text)
    if message.status.isTerminal { break }
}
```

### Managing agents and chats

```swift
let agent = try await client.agents.getByName(namespace: "my-team", name: "support-agent")
let versions = try await client.agents.listVersions(agent.id)

let chats = try await client.chats.list(CursorListRequest(limit: 20))
try await client.chats.stop(chatId)
for try await event in client.chats.stream(chatId) {
    switch event {
    case .message(let message, _): print(message.text)
    case .chat(let chat): print("chat", chat.status.rawValue)
    case .delta(let messageId, let delta): print(messageId, delta)
    case .run: break
    }
}
```

## Speech

`TextToSpeech` and `SpeechToText` wrap any speech app on inference.sh. They read the app's input and output schema, so the same code works across providers:

```swift
let stt = SpeechToText(client: client, app: "elevenlabs/stt")
let text = try await stt.transcribe(wavData)

let tts = TextToSpeech(client: client, app: "infsh/kokoro-tts")
for try await audio in tts.synthesize(reply) {   // long text is chunked; one Data per chunk
    try player.enqueue(audio)
}
```

## API Reference

| Namespace | Covers |
| --- | --- |
| `client.tasks` | `run`, `create`, `get`, `list`, `cancel`, `delete`, logs, timings, telemetry, visibility |
| `client.agents` | `list`, `get`, `getByName`, create, update, versions, duplicate, visibility, A2A card, run interrupts |
| `client.chats` | `list`, `get`, `update`, `delete`, `getStatus`, `stop`, `cancelMessage`, `stream` |
| `client.apps` | `list`, `get`, `getByName`, create, update, versions, visibility, licenses |
| `client.files` | `upload`, `list`, `get`, `delete` |
| `client.search` | `search`, `suggest` |
| `AgentChatSession` | Stateful agent chat (above) |

Every request and response model (`TaskDTO`, `ChatMessageDTO`, `AgentDTO`, …) is generated from the api's own Go types, the same source the JS and Python SDKs are generated from. Enums tolerate values added to the api later: an unknown status decodes instead of failing.

## Error Handling

```swift
do {
    let task = try await client.tasks.run(request)
} catch let error as InferenceError {
    // .http(status:body:) carries the api's problem details;
    // localizedDescription reads e.g. "HTTP 402: Insufficient balance"
    print(error.localizedDescription)
} catch let error as TaskRunError {
    print("task failed:", error.localizedDescription)
}
```

Server warnings attached to a response arrive on `InferenceClient(apiKey:onMessage:)`.

## Configuration

```swift
let client = InferenceClient(
    baseURL: URL(string: "https://api.inference.sh")!,  // default
    apiKey: key,
    onMessage: { notices in print(notices) }
)
```

`InferenceClient` is a `Sendable` value type; create one and share it.

## Development

```bash
make test                                  # unit tests (Codable, stream parsing, deltas)
make e2e AGENT=my-team/my-agent            # live: streams a real agent run
make test-linux                            # same tests in the swift:5.10 docker image
```

`Sources/InferenceSDK/Types.swift` is generated by [gotypegen](https://github.com/inference-sh/gotypegen) from the api's types. Don't edit it by hand; regenerate it with the api's `make types`.

`Examples/agent-run` is a small CLI on top of the SDK and doubles as the live end-to-end check.

## License

MIT
