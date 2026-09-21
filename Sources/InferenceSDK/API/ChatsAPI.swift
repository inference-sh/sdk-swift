// Mirrors js/sdk-js/src/api/chats.ts. Access as `client.chats`.
//
// Divergence from JS, shared by every API struct here: methods return the
// decoded DTO directly instead of a `Response<T>` envelope — `decode` unwraps
// `{data, messages}` and routes `messages` to `client.onMessage`.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ChatsAPI: Sendable {
    let client: InferenceClient
    init(_ client: InferenceClient) { self.client = client }

    /// POST /chats/list: cursor-paginated chats.
    public func list(_ params: CursorListRequest? = nil) async throws -> CursorListResponse<ChatDTO> {
        try await client.cursorList("chats/list", params)
    }

    /// GET /chats/{id}.
    public func get(_ chatId: String) async throws -> ChatDTO {
        try await client.fetchChat(chatId)
    }

    /// POST /chats/{id}: update chat fields.
    public func update(_ chatId: String, _ data: ChatDTO) async throws -> ChatDTO {
        try await client.decode(client.send(client.request("chats/\(chatId)", body: data)))
    }

    /// DELETE /chats/{id}.
    public func delete(_ chatId: String) async throws {
        _ = try await client.send(client.request("chats/\(chatId)", method: "DELETE"))
    }

    /// GET /chats/{id}/status.
    public func getStatus(_ chatId: String) async throws -> ResourceStatusDTO {
        try await client.decode(client.send(client.request("chats/\(chatId)/status", method: "GET")))
    }

    /// POST /chats/{id}/stop: cancel the active run and pending tools.
    public func stop(_ chatId: String) async throws {
        try await client.stopChat(chatId)
    }

    /// POST /chats/messages/{id}/cancel: cancel a queued message.
    public func cancelMessage(_ messageId: String) async throws {
        try await client.cancelMessage(messageId)
    }

    /// GET /chats/{id}/stream as typed SSE events (the JS `stream()`; transport
    /// in ChatStream.swift, reconnect and inactivity timeout included).
    public func stream(_ chatId: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        client.chatStream(chatId: chatId)
    }
}

// MARK: - Namespaces (js: client.chats / client.tasks / client.agents / …)

public extension InferenceClient {
    var chats: ChatsAPI { ChatsAPI(self) }
}
