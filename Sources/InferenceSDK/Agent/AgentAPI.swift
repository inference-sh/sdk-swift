// Agent chat REST endpoints. Mirrors js/sdk-js/src/agent/api.ts.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public extension InferenceClient {

    // MARK: - Chats

    /// POST /chats: start a new chat with `agent`. `context` is dropped when nil.
    func createChat(agent: String, context: [String: String]? = nil) async throws -> ChatDTO {
        try await decode(send(request("chats", body: CreateChatBody(agent: agent, context: context))))
    }

    /// POST /chats/{id}/messages: append a user message. Returns the user message DTO.
    func sendChatMessage(chatId: String, message: String) async throws -> ChatMessageDTO {
        try await decode(send(request("chats/\(chatId)/messages", body: MessageBody(message: message))))
    }

    /// GET /chats/{id}/messages with optional `limit`/`cursor`. One page; the
    /// chat itself (without preloaded messages) is `chats.get`.
    func fetchMessagesPage(chatId: String, limit: Int? = nil, cursor: String? = nil)
        async throws -> CursorListResponse<ChatMessageDTO> {
        var query: [URLQueryItem] = []
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await decode(send(request("chats/\(chatId)/messages", method: "GET", query: query)))
    }

    /// POST /chats/{id}/agent: switch the chat's agent. Returns the updated chat.
    func setAgent(chatId: String, agent: String) async throws -> ChatDTO {
        try await decode(send(request("chats/\(chatId)/agent", body: AgentBody(agent: agent))))
    }

    // MARK: - Tools

    /// POST /tools/{id}/invoke: approve a pending tool invocation.
    func approveTool(_ toolInvocationId: String) async throws {
        _ = try await send(request("tools/\(toolInvocationId)/invoke"))
    }

    /// POST /tools/{id}/reject: reject a pending tool invocation. `reason` is dropped when nil.
    func rejectTool(_ toolInvocationId: String, reason: String? = nil) async throws {
        _ = try await send(request("tools/\(toolInvocationId)/reject", body: RejectBody(reason: reason)))
    }

    /// POST /tools/{id}: submit a client-side tool result.
    func submitToolResult(_ toolInvocationId: String, result: String) async throws {
        _ = try await send(request("tools/\(toolInvocationId)", body: ToolResultRequest(result: result)))
    }

    /// POST /chats/{chatId}/tools/{id}/always-allow: whitelist `toolName` for the chat.
    func alwaysAllowTool(chatId: String, toolInvocationId: String, toolName: String) async throws {
        _ = try await send(request("chats/\(chatId)/tools/\(toolInvocationId)/always-allow",
                                   body: ToolNameBody(toolName: toolName)))
    }

    // MARK: - Interrupts

    /// POST /interrupts/{id}/resolve: `decision` is "allow" or "deny". Returns the interrupt.
    func resolveInterrupt(_ interruptId: String, decision: String) async throws -> InterruptDTO {
        try await decode(send(request("interrupts/\(interruptId)/resolve", body: DecisionBody(decision: decision))))
    }

    /// GET /agents/{ref} projected to what a chat header needs. Returns nil
    /// on any failure — agent info is decoration, not a dependency (js parity).
    /// (Run interrupts: `client.agents.listRunInterrupts`.)
    func fetchAgentInfo(_ agentRef: String) async -> AgentInfo? {
        guard let agent = try? await agents.get(agentRef) else { return nil }
        return AgentInfo(description: agent.version?.description,
                         examplePrompts: agent.version?.examplePrompts)
    }
}

/// The slice of an agent the chat UI shows (js agent/api.ts AgentInfo).
public struct AgentInfo: Sendable {
    public var description: String?
    public var examplePrompts: [String]?
}

// MARK: - Busy state (mirrors js/sdk-js/src/utils.ts isChatBusy)

public extension AgentRunDTO {
    /// The run is holding the chat: submitted, working, or waiting on input.
    var isActive: Bool {
        state == .working || state == .submitted || state == .inputRequired
    }
}

public extension ChatDTO {
    /// The JS SDK's `isChatBusy`: the active run decides when there is one,
    /// else the chat status. Busy chats queue new messages server-side.
    var isBusy: Bool {
        if let run = activeRun { return run.isActive }
        return status == .busy || status == .awaitingInput
    }
}

// MARK: - Request/response bodies

private struct CreateChatBody: Encodable {
    let agent: String
    let context: [String: String]?
    enum CodingKeys: String, CodingKey { case agent, context }
}

private struct MessageBody: Encodable {
    let message: String
    enum CodingKeys: String, CodingKey { case message }
}

private struct AgentBody: Encodable {
    let agent: String
    enum CodingKeys: String, CodingKey { case agent }
}

private struct RejectBody: Encodable {
    let reason: String?
    enum CodingKeys: String, CodingKey { case reason }
}

private struct ToolNameBody: Encodable {
    let toolName: String
    enum CodingKeys: String, CodingKey { case toolName = "tool_name" }
}

private struct DecisionBody: Encodable {
    let decision: String
    enum CodingKeys: String, CodingKey { case decision }
}
