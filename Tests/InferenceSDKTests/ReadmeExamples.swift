import Foundation
import InferenceSDK
#if canImport(Combine)
import Combine
#endif

// The README's code, compiled (never run) so the examples can't drift from
// the API. Keep in sync when either changes.
private enum ReadmeExamples {
    static func tasks(client: InferenceClient, taskId: String, imageData: Data) async throws {
        let task = try await client.tasks.run(ApiAppRunRequest(
            app: "infsh/flux-schnell",
            input: ["prompt": "a lighthouse at dawn, watercolor"]
        ))
        print(task.output)

        _ = try await client.tasks.run(ApiAppRunRequest(
            app: "my-app",
            setup: ["model": "schnell"],
            input: ["prompt": "hello"]
        ))

        _ = try await client.tasks.run(
            ApiAppRunRequest(app: "my-app", input: ["prompt": "hello"]),
            options: TaskRunOptions(
                onUpdate: { task in print("status:", task.status.rawValue) },
                onDelta: { delta, seq in print("delta \(seq):", delta) }
            )
        )

        let started = try await client.tasks.run(
            ApiAppRunRequest(app: "my-app", input: ["prompt": "hello"]),
            options: TaskRunOptions(wait: false)
        )
        print("started", started.id)
        _ = try await client.tasks.get(started.id)

        try await client.tasks.cancel(taskId)
        _ = try await client.tasks.getLogs(taskId)
        _ = try await client.tasks.list(CursorListRequest(limit: 20))

        let file = try await client.files.upload(imageData, filename: "photo.jpg", contentType: "image/jpeg")
        _ = try await client.tasks.run(ApiAppRunRequest(
            app: "my-image-app",
            input: ["image": .string(file.uri)]
        ))
    }

    @MainActor
    static func chat(client: InferenceClient) async {
        let session = AgentChatSession(client: client, agent: "my-team/support-agent@latest")
        session.onChange = { state in
            if let last = state.messages.last { print(last.role.rawValue, last.text) }
        }
        session.callbacks.onTurnEnd = { chat in print("agent finished") }
        await session.sendMessage("What can you help me with?")
    }

    #if canImport(Combine)  // ObservableObject: Apple platforms only
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
    #endif

    @MainActor
    static func tools(session: AgentChatSession, invocation: ToolInvocationDTO, existingChatId: String, interruptId: String) async throws {
        try await session.approveTool(invocation.id)
        try await session.rejectTool(invocation.id, reason: "not now")
        try await session.alwaysAllowTool(invocation.id, toolName: invocation.function.name)
        try await session.submitToolResult(invocation.id, result: #"{"form_data":{"size":"large"}}"#)
        try await session.resolveInterrupt(interruptId, decision: "allow")
        _ = invocation.widget
        _ = Widget.parse(string: "{}")

        session.setChatId(existingChatId)
        _ = await session.loadOlderMessages()
    }

    static func agents(client: InferenceClient, chatId: String) async throws {
        let request = ApiAgentRunRequest(agent: "my-team/support-agent@latest", input: LLMInput(text: "hello"))
        for try await message in client.runAgentStream(request) {
            print(message.status.rawValue, message.text)
            if message.status.isTerminal { break }
        }

        let agent = try await client.agents.getByName(namespace: "my-team", name: "support-agent")
        _ = try await client.agents.listVersions(agent.id)

        _ = try await client.chats.list(CursorListRequest(limit: 20))
        try await client.chats.stop(chatId)
        for try await event in client.chats.stream(chatId) {
            switch event {
            case .message(let message, _): print(message.text)
            case .chat(let chat): print("chat", chat.status.rawValue)
            case .delta(let messageId, let delta): print(messageId, delta)
            case .run: break
            }
        }
    }

    static func speech(client: InferenceClient, wavData: Data, reply: String) async throws {
        let stt = SpeechToText(client: client, app: "elevenlabs/stt")
        _ = try await stt.transcribe(wavData)
        let tts = TextToSpeech(client: client, app: "infsh/kokoro-tts")
        for try await audio in tts.synthesize(reply) { _ = audio }
    }

    static func errors(client: InferenceClient, request: ApiAppRunRequest, key: String) async {
        do {
            _ = try await client.tasks.run(request)
        } catch let error as InferenceError {
            print(error.localizedDescription)
        } catch let error as TaskRunError {
            print("task failed:", error.localizedDescription)
        } catch {}

        _ = InferenceClient(
            baseURL: URL(string: "https://api.inference.sh")!,
            apiKey: key,
            onMessage: { notices in print(notices) }
        )
    }
}
