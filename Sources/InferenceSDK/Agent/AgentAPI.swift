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

    /// GET /chats/{id}. Messages are not preloaded; fetch them separately.
    func fetchChat(_ chatId: String) async throws -> ChatDTO {
        try await decode(send(request("chats/\(chatId)", method: "GET")))
    }

    /// GET /chats/{id}/messages with optional `limit`/`cursor`. One page plus the
    /// cursor to the next. The query is appended to the formed URL because
    /// `request`'s path join would percent-encode the `?`.
    func fetchMessagesPage(chatId: String, limit: Int? = nil, cursor: String? = nil)
        async throws -> (items: [ChatMessageDTO], nextCursor: String, hasNext: Bool) {
        var req = request("chats/\(chatId)/messages", method: "GET")
        var query: [String] = []
        if let limit { query.append("limit=\(limit)") }
        if let cursor {
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&=+?#;")
            let value = cursor.addingPercentEncoding(withAllowedCharacters: allowed) ?? cursor
            query.append("cursor=\(value)")
        }
        if !query.isEmpty, let base = req.url {
            req.url = URL(string: base.absoluteString + "?" + query.joined(separator: "&")) ?? base
        }
        let page: MessagesPage = try await decode(send(req))
        return (page.items, page.nextCursor, page.hasNext)
    }

    /// POST /chats/messages/{id}/cancel: cancel a message that is still running.
    func cancelMessage(_ messageId: String) async throws {
        _ = try await send(request("chats/messages/\(messageId)/cancel"))
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
        _ = try await send(request("tools/\(toolInvocationId)", body: ResultBody(result: result)))
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

    /// GET /agent-runs/{id}/interrupts: interrupts raised by one run.
    func listRunInterrupts(_ runId: String) async throws -> [InterruptDTO] {
        try await decode(send(request("agent-runs/\(runId)/interrupts", method: "GET")))
    }

    /// GET /agents/{ref} projected to what a chat header needs. Returns nil
    /// on any failure — agent info is decoration, not a dependency (js parity).
    func fetchAgentInfo(_ agentRef: String) async -> AgentInfo? {
        guard let agent: AgentDTO = try? await decode(send(request("agents/\(agentRef)", method: "GET"))) else { return nil }
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

private struct ResultBody: Encodable {
    let result: String
    enum CodingKeys: String, CodingKey { case result }
}

private struct ToolNameBody: Encodable {
    let toolName: String
    enum CodingKeys: String, CodingKey { case toolName = "tool_name" }
}

private struct DecisionBody: Encodable {
    let decision: String
    enum CodingKeys: String, CodingKey { case decision }
}

private struct MessagesPage: Decodable {
    let items: [ChatMessageDTO]
    let nextCursor: String
    let hasNext: Bool
    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
        case hasNext = "has_next"
    }
}
