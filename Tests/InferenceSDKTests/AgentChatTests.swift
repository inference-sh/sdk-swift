import Foundation
import XCTest
@testable import InferenceSDK

/// switchAgent and MERGE_CHAT_AGENT (sdk-js reducer.test.ts, actions.test.ts),
/// MCP input requests (mcp-input.test.ts, actions.test.ts submitMCPInput),
/// run predicates (utils.test.ts) and system rows (common-js system-message.tsx).
final class AgentChatTests: XCTestCase {
    private func chat(_ id: String) -> ChatDTO {
        ChatDTO(id: id, visibility: .private, status: .idle, agentId: "agent-1", agentVersionId: "version-1",
                agentData: ChatData())
    }

    private func message(_ role: ChatMessageRole, _ content: [ChatMessageContent], order: Int = 1) -> ChatMessageDTO {
        ChatMessageDTO(id: "m\(order)", visibility: .private, order: order, status: .ready, role: role, content: content)
    }

    // MARK: switchAgent

    func testSetChatWithoutMessagesLeavesNone() {
        var c = chat("c1")
        c.chatMessages = nil
        XCTAssertEqual(chatReducer(.initial, .setChat(c)).messages.count, 0)
    }

    func testMergeChatAgent() {
        var state = chatReducer(.initial, .setChat(chat("c1")))
        state.messages = [message(.user, [ChatMessageContent(type: .text, text: "hi")])]
        let dto = ChatAgentDTO(chatId: "c1", agentId: "agent-2", agentVersionId: "version-2")
        let next = chatReducer(state, .mergeChatAgent(dto))
        XCTAssertEqual(next.chat?.agentId, "agent-2")
        XCTAssertEqual(next.chat?.agentVersionId, "version-2")
        XCTAssertNil(next.chat?.agent)
        XCTAssertNil(next.chat?.agentVersion)
        XCTAssertEqual(next.messages.map(\.id), state.messages.map(\.id))

        // Another chat's answer, or none held, leaves state alone.
        XCTAssertEqual(chatReducer(state, .mergeChatAgent(ChatAgentDTO(chatId: "c2", agentId: "x"))).chat?.agentId, "agent-1")
        XCTAssertNil(chatReducer(.initial, .mergeChatAgent(dto)).chat)
    }

    @MainActor
    func testSwitchAgent() async throws {
        var client = InferenceClient(apiKey: "k")
        client.transport = StubProtocol.start { req, _ in
            if req.url?.path == "/chats/c1/agent" {
                return .json(#"{"data":{"chat_id":"c1","agent_id":"agent-2","agent_version_id":"version-2"}}"#)
            }
            return .init(status: 404, body: Data())
        }
        let session = AgentChatSession(client: client, agent: "a/b")
        try await session.switchAgent("okaris/editor") // no chat yet: a no-op
        XCTAssertTrue(StubProtocol.recorded.isEmpty)

        session.setChatId("c1")
        try await session.switchAgent("okaris/editor")
        let sent = try XCTUnwrap(StubProtocol.recorded.first { $0.path == "/chats/c1/agent" })
        XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: sent.body), ["agent": "okaris/editor"])
        XCTAssertNil(session.state.error)
        session.reset()
    }

    @MainActor
    func testSwitchAgentRethrowsARefusal() async throws {
        var client = InferenceClient(apiKey: "k")
        client.transport = StubProtocol.start { _, _ in
            .init(status: 400, body: Data(#"{"title":"Bad Request","detail":"a chat can switch only to agents that run on inference"}"#.utf8))
        }
        let session = AgentChatSession(client: client, agent: "a/b")
        var errors = 0
        session.callbacks.onError = { _ in errors += 1 }
        session.setChatId("c1")
        do {
            try await session.switchAgent("okaris/claude")
            XCTFail("expected the refusal")
        } catch InferenceError.http(let status, _) {
            XCTAssertEqual(status, 400)
        }
        XCTAssertNotNil(session.state.error)
        XCTAssertGreaterThanOrEqual(errors, 1)
        session.reset()
    }

    // MARK: MCP input

    private let inputState: JSONValue = [
        "input_required": true,
        "input_requests": [
            "login": ["method": "elicitation/create",
                      "params": ["mode": "url", "message": "sign in", "url": "https://example.com/auth"]],
        ],
        "request_state": "opaque",
        "round": 2,
    ]

    func testParseMCPInputState() throws {
        let parsed = try XCTUnwrap(MCPInputState(data: inputState))
        XCTAssertEqual(parsed.round, 2)
        XCTAssertEqual(parsed.requestState, "opaque")
        XCTAssertEqual(parsed.inputRequests["login"]?.method, "elicitation/create")

        let json = String(decoding: try JSONEncoder().encode(inputState), as: UTF8.self)
        XCTAssertEqual(MCPInputState(data: .string(json))?.inputRequests.keys.sorted(), ["login"])

        var noRound = inputState.objectValue!
        noRound["round"] = nil
        XCTAssertEqual(MCPInputState(data: .object(noRound))?.round, 1)

        XCTAssertNil(MCPInputState(data: nil))
        XCTAssertNil(MCPInputState(data: "not json"))
        XCTAssertNil(MCPInputState(data: ["requirement_errors": []]))
        var notRequired = inputState.objectValue!
        notRequired["input_required"] = false
        XCTAssertNil(MCPInputState(data: .object(notRequired)))
        var noRequests = inputState.objectValue!
        noRequests["input_requests"] = [:]
        XCTAssertNil(MCPInputState(data: .object(noRequests)))

        let tool = ToolInvocationDTO(visibility: .private, type: .mcp, function: ToolInvocationFunction(),
                                     status: .awaitingInput, data: inputState)
        XCTAssertEqual(tool.mcpInputState?.round, 2)
    }

    func testElicitParams() throws {
        let login = try XCTUnwrap(MCPInputState(data: inputState)?.inputRequests["login"])
        XCTAssertEqual(login.elicitParams?.url, "https://example.com/auth")
        XCTAssertEqual(login.elicitParams?.message, "sign in")
        XCTAssertNil(InputRequest(method: "sampling/createMessage", params: [:]).elicitParams)

        let form = InputRequest(method: "elicitation/create", params: [
            "message": "who are you",
            "requestedSchema": ["type": "object", "required": ["name"],
                                "properties": ["name": ["type": "string", "minLength": 1],
                                               "size": ["type": "string", "enum": ["s", "m"], "enumNames": ["Small", "Medium"]]]],
        ])
        let schema = try XCTUnwrap(form.elicitParams?.requestedSchema)
        XCTAssertEqual(schema.required, ["name"])
        XCTAssertEqual(schema.properties?["name"]?.minLength, 1)
        XCTAssertEqual(schema.properties?["size"]?.enumNames, ["Small", "Medium"])
        XCTAssertEqual(InputRequest(method: "elicitation/create", params: [:]).elicitParams?.message, "")
    }

    func testElicitParamsLenient() throws {
        let request = InputRequest(method: "elicitation/create", params: [
            "message": "pick", "url": "https://x.test", "mode": 3,
            "requestedSchema": ["type": "object", "required": ["size", 1],
                                "properties": ["size": ["type": "string", "minLength": "1", "enum": ["s", 2],
                                                        "oneOf": [["const": "s"], ["title": "no const"]]],
                                               "bad": "not an object"]],
        ])
        let params = try XCTUnwrap(request.elicitParams)
        XCTAssertEqual(params.message, "pick")
        XCTAssertEqual(params.url, "https://x.test")
        XCTAssertNil(params.mode)
        XCTAssertEqual(params.requestedSchema?.required, ["size"])
        let size = try XCTUnwrap(params.requestedSchema?.properties?["size"])
        XCTAssertNil(size.minLength)
        XCTAssertEqual(size.enum, ["s"])
        XCTAssertEqual(size.oneOf?.map(\.const), ["s"])
        XCTAssertNil(params.requestedSchema?.properties?["bad"])
        XCTAssertNil(InputRequest(method: "elicitation/create", params: ["requestedSchema": "nope", "message": "m"])
            .elicitParams?.requestedSchema)
    }

    func testIsURLElicitation() {
        XCTAssertTrue(ElicitRequestParams(mode: "url").isURL)
        XCTAssertTrue(ElicitRequestParams(url: "https://x.test").isURL)
        XCTAssertFalse(ElicitRequestParams(mode: "form", url: "https://x.test").isURL)
        XCTAssertFalse(ElicitRequestParams().isURL)
    }

    func testBuildMCPInputResult() throws {
        let result = buildMCPInputResult([
            "a": ElicitResult(action: .accept, content: ["x": 1]),
            "b": ElicitResult(action: .decline, content: ["x": 2]),
            "c": ElicitResult(action: .accept),
        ])
        XCTAssertEqual(result, #"{"a":{"action":"accept","content":{"x":1}},"b":{"action":"decline"},"c":{"action":"accept"}}"#)
    }

    @MainActor
    func testSubmitMCPInput() async throws {
        var client = InferenceClient(apiKey: "k")
        client.transport = StubProtocol.start { _, _ in .json(#"{"data":null}"#) }
        let session = AgentChatSession(client: client, agent: "a/b")
        var changes = 0
        session.onChange = { _ in changes += 1 }
        try await session.submitMCPInput("inv-1", responses: [
            "login": ElicitResult(action: .accept),
            "details": ElicitResult(action: .accept, content: ["name": "ada"]),
        ])
        let sent = try XCTUnwrap(StubProtocol.recorded.first)
        XCTAssertEqual(sent.path, "/tools/inv-1")
        let body = try JSONDecoder().decode([String: String].self, from: sent.body)
        XCTAssertEqual(body["result"], #"{"details":{"action":"accept","content":{"name":"ada"}},"login":{"action":"accept"}}"#)
        XCTAssertEqual(changes, 0)
    }

    @MainActor
    func testSubmitMCPInputRejected() async throws {
        var client = InferenceClient(apiKey: "k")
        client.transport = StubProtocol.start { _, _ in
            .init(status: 400, body: Data(#"{"title":"Bad Request","detail":"missing response for \"login\""}"#.utf8))
        }
        let session = AgentChatSession(client: client, agent: "a/b")
        var errors = 0
        session.callbacks.onError = { _ in errors += 1 }
        do {
            try await session.submitMCPInput("inv-1", responses: [:])
            XCTFail("expected 400")
        } catch InferenceError.http(let status, _) {
            XCTAssertEqual(status, 400)
        }
        XCTAssertNil(session.state.error)
        XCTAssertEqual(session.state.connectionStatus, .idle)
        XCTAssertEqual(errors, 0)
    }

    @MainActor
    func testSubmitMCPInputFailure() async throws {
        var client = InferenceClient(apiKey: "k")
        client.transport = StubProtocol.start { _, _ in .init(status: 500, body: Data("boom".utf8)) }
        let session = AgentChatSession(client: client, agent: "a/b")
        var errors = 0
        session.callbacks.onError = { _ in errors += 1 }
        do {
            try await session.submitMCPInput("inv-1", responses: ["a": ElicitResult(action: .cancel)])
            XCTFail("expected 500")
        } catch {}
        XCTAssertEqual(session.state.connectionStatus, .error)
        XCTAssertNotNil(session.state.error)
        XCTAssertEqual(errors, 1)
    }

    // MARK: Run predicates (utils.test.ts)

    func testRunPredicates() {
        for s in [AgentRunState.completed, .failed, .canceled, .rejected] {
            XCTAssertEqual([s.isTerminal, s.isInterrupted, s.isSettled, s.isWorking], [true, false, true, false])
        }
        for s in [AgentRunState.inputRequired, .authRequired] {
            XCTAssertEqual([s.isTerminal, s.isInterrupted, s.isSettled, s.isWorking], [false, true, true, false])
        }
        for s in [AgentRunState.working, .submitted] {
            XCTAssertEqual([s.isTerminal, s.isInterrupted, s.isSettled, s.isWorking], [false, false, false, true])
        }
        XCTAssertTrue([ToolInvocationStatus.completed, .failed, .cancelled].allSatisfy(\.isTerminal))
        XCTAssertFalse([ToolInvocationStatus.pending, .inProgress, .awaitingInput, .awaitingApproval].contains(where: \.isTerminal))

        var c = chat("c1")
        c.activeRun = AgentRunDTO(visibility: .private, state: .authRequired)
        XCTAssertTrue(c.isAwaitingHuman)
        XCTAssertTrue(c.isBusy, "a run waiting on an authorization holds the chat (js isChatBusy)")
        XCTAssertEqual(chatReducer(chatReducer(.initial, .setChat(chat("c1"))), .updateActiveRun(c.activeRun!)).chat?.status, .awaitingInput)
        c.activeRun = AgentRunDTO(visibility: .private, state: .working)
        XCTAssertFalse(c.isAwaitingHuman)
        c.activeRun = nil
        c.status = .awaitingInput
        XCTAssertTrue(c.isAwaitingHuman)
    }

    // MARK: System rows (common-js system-message.tsx)

    func testSystemNotes() throws {
        XCTAssertNil(message(.user, [ChatMessageContent(type: .text, text: "hi")]).systemNote)
        XCTAssertFalse(message(.assistant, []).isSystemMessage)
        XCTAssertTrue(ChatMessageRole.tool.isLLMRole)
        XCTAssertFalse(ChatMessageRole.compaction.isLLMRole)

        let compaction = message(.compaction, [ChatMessageContent(type: .text,
            text: "[Earlier conversation compacted]\n\nThe user asked for a plan.")])
        guard case .compacted(let summary) = compaction.systemNote else { return XCTFail("\(String(describing: compaction.systemNote))") }
        XCTAssertEqual(summary, "The user asked for a plan.")

        let injection = message(.injection, [ChatMessageContent(type: .text, text: "  remember the goal \n")])
        guard case .contextAdded(let text) = injection.systemNote else { return XCTFail() }
        XCTAssertEqual(text, "remember the goal")
        XCTAssertNil(message(.injection, [ChatMessageContent(type: .text, text: "  ")]).systemNote)

        let hook = ChatHookEvent(event: .toolCall, handlerType: .hookHandlerBuiltin, handler: "guard",
                                 decision: .deny, reason: "not on main", injected: true, durationMs: 12)
        let event = message(.event, [ChatMessageContent(type: .event, text: "hook agent.tool_call: guard",
                                                        event: ChatEvent(type: .hook, hook: hook))])
        guard case .hook(let h) = event.systemNote else { return XCTFail() }
        XCTAssertEqual(h.handler, "guard")
        XCTAssertTrue(h.isBlocking)
        XCTAssertEqual(h.summary, "hook · agent.tool_call · guard · added context · deny: not on main")
        let allowed = ChatHookEvent(event: .turnStart, handlerType: .hookHandlerWebhook, handler: "hooks.example.com", decision: .allow)
        XCTAssertFalse(allowed.isBlocking)
        XCTAssertEqual(allowed.summary, "hook · agent.turn_start · hooks.example.com")

        // An event without a hook shows its text, as the web does.
        guard case .contextAdded = message(.event, [ChatMessageContent(type: .text, text: "something ran")]).systemNote
        else { return XCTFail() }
    }
}
