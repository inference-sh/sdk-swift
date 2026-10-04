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
    .package(url: "https://github.com/inference-sh/sdk-swift", from: "0.3.0"),
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

## Authentication

The client sends `Authorization: Bearer <token>` on every api request. The token comes from an `InferenceAuthProvider`: a fixed API key, or a user's OAuth sign-in that refreshes itself.

### API key

Get a key from the [inference.sh dashboard](https://app.inference.sh/settings/keys):

```swift
let client = InferenceClient(apiKey: "your-api-key")
```

Don't ship a raw key inside an app binary for other people to use. For a public app, sign users in with OAuth (below), or call the api from your own backend.

### Signing users in (OAuth)

`InferenceOAuth` implements the authorization code flow with PKCE against the api's OAuth 2.1 server. All endpoints are on the api host; `/oauth/authorize` sends the browser on to app.inference.sh to log in and approve, then back to your redirect URI with a code.

```swift
// 1. Once per install: register a public client and store its id. Custom
//    schemes are accepted as redirect URIs. The id does not expire.
let registration = try await InferenceOAuth.register(
    clientName: "My App",
    redirectURIs: ["myapp://oauth/callback"]
)
let oauth = InferenceOAuth(clientId: registration.clientId)

// 2. Open the authorize URL in a browser session and wait for the redirect
//    (ASWebAuthenticationSession on Apple platforms, with request.callbackScheme).
let request = oauth.authorizationRequest(
    redirectURI: "myapp://oauth/callback",
    scope: "agents:read agents:execute conversations:read conversations:write files:read files:write apps:read apps:execute apps:write"
)
let callbackURL = try await openInBrowser(request.url, request.callbackScheme)

// 3. Check state, exchange the code.
let tokens = try await oauth.completeAuthorization(callbackURL: callbackURL, request: request)

// 4. A provider that refreshes before expiry and after a 401.
let auth = RefreshingAuthProvider(
    tokens: tokens,
    oauth: oauth,
    onTokens: { saveToKeychain($0) },        // every new pair; OAuthTokens is Codable
    onSignedOut: { _ in showSignIn() }       // refresh token rejected (revoked, expired)
)
let client = InferenceClient(auth: auth)
```

Access tokens last 10 minutes and refresh tokens 30 days. Each refresh returns a new refresh token and invalidates the old one, so `RefreshingAuthProvider` runs one refresh at a time and hands the result to every waiting request; persist the pair from `onTokens` each time. On the next launch, build the provider from the stored `OAuthTokens`.

A token carries the scopes approved at consent; requesting no scope grants unrestricted access. Writing knowledge needs `apps:write`.

Sign out:

```swift
if let refreshToken = await auth.tokens?.refreshToken {
    try await oauth.revoke(refreshToken)
}
await auth.clear()
```

#### Device flow

For devices without a browser (a watch, a CLI), the user approves on another device:

```swift
let device = try await oauth.startDeviceAuthorization()
print("Open \(device.verificationURI) and enter \(device.userCode)")
let tokens = try await oauth.pollDeviceToken(device)   // honors interval, slow_down, expiry
let client = InferenceClient(auth: RefreshingAuthProvider(tokens: tokens, oauth: oauth))
```

The device flow returns a session token without a refresh token (valid 7 days unless the approver picks another lifetime). The provider uses it until the server rejects it, then signs out.

#### Your own provider

```swift
struct BackendTokens: InferenceAuthProvider {
    func bearerToken(forceRefresh: Bool) async throws -> String {
        try await fetchTokenFromMyBackend(forceRefresh: forceRefresh)
    }
}
let client = InferenceClient(auth: BackendTokens())
```

`bearerToken` is called for every request and every stream (re)connect. After a 401 the client calls it once with `forceRefresh: true` and retries if the token changed. Presigned upload URLs and output file downloads never receive the token.

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

## Live Functions

A stream function keeps a socket open with its caller for the life of the task: audio and messages go both ways until the caller closes or the app returns. `client.live` starts the task and dials its socket.

```swift
let (task, session) = try await client.live(ApiAppRunRequest(
    app: "xai/grok-voice",
    input: ["voice": "eve"],
    function: "talk"
))

Task {
    for await event in session.events {
        switch event {
        case .state(.live): microphone.start()                 // connecting → waiting → live → ended
        case .state(let state): print(state)
        case .binary(let pcm): player.play(pcm)                // an item of the output's binary live field
        case .patch(let patch): print(patch)                   // ["user_text": "..."]
        case .clear: player.flush()                            // the app cut an answer short
        case .error(let field, let message): print(field ?? "-", message)
        case .text(let text): print(text)                      // text the app sent as text, not a patch
        }
    }
}

session.sendBinary(micFrame)                                   // an item of the input's binary live field
session.sendPatch(["events": ["type": "text", "text": "hi"]])  // a JSON frame
session.close()                                                // the function returns; the task completes
let result = try await client.tasks.watch(task.id)             // what it returned
```

The session is `waiting` until the app's first frame (a cold start can take a minute). Frames sent before the relay accepts the connection are dropped (`sendBinary` returns `false`), and the relay holds only 64 while the app is not there, so start the microphone on `.state(.live)`. The session gives up if the task ends before the app connects (`LiveEnd.taskEnded`), and dials again with a fresh credential when the relay restarts under it while it waits. `client.sockets.open(taskId)` reconnects to a running task's socket, e.g. after the app relaunches. Releasing the session closes its socket.

A task whose caller never connects keeps waiting for it, up to 15 minutes. When a session ends before it reached the app (`LiveEnd.code` 1006: the dial failed, the network dropped), dial again with `client.sockets.open(task.id)` or call `client.tasks.cancel(task.id)`.

What a function's socket carries is in its schemas: a live field is `{"type": "array", "format": "stream", "items": ...}`. `splitLiveSchema` separates the ordinary fields (the request body) from the live ones, and `pcmFormat` reads the format of a PCM audio field:

```swift
let function = try await client.apps.getByName("xai/grok-voice").version?.functions?["talk"]
let (form, live) = splitLiveSchema(function?.inputSchema)
let microphone = pcmFormat(binaryLiveField(live)?.media)       // PCMFormat(sampleRate: 24000, channels: 1)
```

Given the schemas, the session routes by field name:

```swift
let (_, session) = try await client.live(request, options: OpenSocketOptions(
    inputSchema: function?.inputSchema,
    outputSchema: function?.outputSchema
))
try session.sendField("audio", .binary(micFrame))              // binary: the input's binary live field
try session.sendField("voice", .json("ara"))                   // JSON: an ordinary field
for await event in session.events {
    for update in session.updates(for: event) { show(update.field, update.value) }
}
```

The SDK moves frames; recording and playing 16-bit PCM is the app's (`AVAudioEngine` on Apple platforms). The socket is a `URLSessionWebSocketTask` with the credential in an `Authorization` header. On Linux that needs a libcurl built with WebSockets (see `LiveSocket.swift`); pass `OpenSocketOptions(dial:)` to use another WebSocket client.

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

## Knowledge

Knowledge entries are versioned documents in your team's namespace. Save a markdown document:

```swift
let entry = try await client.knowledge.create(KnowledgeCreateRequest(
    name: "standup-2026-09-27",
    description: "Standup transcript",
    type: .observation,
    version: KnowledgeVersionInput(
        content: KnowledgeFile(content: markdown),
        tags: ["transcript"]
    )
))
```

`version.content.content` is the document text; the server stores it and fills in its path, uri, size and hash. Creating an entry with a name that already exists adds a version to it. `update` changes the title and description.

```swift
let same = try await client.knowledge.getByName(namespace: entry.namespace, name: entry.name)
let page = try await client.knowledge.list(CursorListRequest(limit: 20))
let versions = try await client.knowledge.listVersions(entry.id)
try await client.knowledge.delete(entry.id)
```

## API Reference

| Namespace | Covers |
| --- | --- |
| `client.tasks` | `run`, `watch`, `create`, `get`, `list`, `cancel`, `delete`, logs, timings, telemetry, visibility |
| `client.agents` | `list`, `get`, `getByName`, create, update, versions, duplicate, visibility, A2A card, run interrupts |
| `client.chats` | `list`, `get`, `update`, `delete`, `getStatus`, `stop`, `cancelMessage`, `stream` |
| `client.apps` | `list`, `get`, `getByName`, create, update, versions, visibility, licenses |
| `client.files` | `upload`, `list`, `get`, `delete` |
| `client.sockets` | `open`, `get`, `list`, `forTask`, `access`, `delete` |
| `client.live`, `LiveSession` | Stream functions (above) |
| `client.knowledge` | `list`, `get`, `getByName`, `create`, `update`, `delete`, versions, transfer, visibility |
| `client.search` | `search`, `suggest` |
| `AgentChatSession` | Stateful agent chat (above) |
| `InferenceOAuth`, `RefreshingAuthProvider` | User sign-in (above) |

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
    apiKey: key,                                         // or auth: any InferenceAuthProvider
    onMessage: { notices in print(notices) }
)
```

`InferenceClient` is a `Sendable` value type; create one and share it.

## Development

```bash
make test                                  # unit tests (Codable, stream parsing, deltas, live sessions)
make e2e AGENT=my-team/my-agent            # live: streams a real agent run
make live APP=infsh/voice-loop             # live: runs a stream function over its socket
make test-linux                            # same tests in the swift:5.10 docker image
```

`Sources/InferenceSDK/Types.swift` is generated by [gotypegen](https://github.com/inference-sh/gotypegen) from the api's types. Don't edit it by hand; regenerate it with the api's `make types`.

`Examples/agent-run` and `Examples/live-run` are small CLIs on top of the SDK and double as the live end-to-end checks.

## License

MIT
