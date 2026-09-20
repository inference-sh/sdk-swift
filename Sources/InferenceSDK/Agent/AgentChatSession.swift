// The agent chat state machine. Mirrors js/sdk-js/src/agent/actions.ts (the
// action creators) + context.ts (the wiring): one instance owns a chat's
// state, its SSE stream and the delta accumulator, and exposes the same
// actions the web provider does. UI-framework-free on purpose — the app wraps
// it in an ObservableObject the same way common-js wraps the JS SDK in React.
//
// Divergences from actions.ts, all deliberate:
//  - Client-side tool handlers (ad-hoc `tools` configs) are not ported; no
//    Swift caller defines them yet. The dispatch loop is the only omission.
//  - fetchChat attaches the message page cursor by dispatching a
//    prependMessages with no messages — Swift can't hang `_messageCursor`
//    expando props on a DTO like the js does.
//  - Polling mode (`streamEnabled: false`) polls /status like pollChat does,
//    at a fixed 3s.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor
public final class AgentChatSession {
    /// Mirrors AgentCallbacks in agent/types.ts.
    public struct Callbacks {
        /// "connecting" | "streaming" | "idle" — the connection-ish status the
        /// web surfaces; distinct from chat busy state (read `state.chat`).
        public var onStatusChange: ((String) -> Void)?
        /// The chat just went from busy to not-busy.
        public var onTurnEnd: ((ChatDTO) -> Void)?
        public var onChatCreated: ((String) -> Void)?
        public var onError: ((Error) -> Void)?
        public init() {}
    }

    public private(set) var state: AgentChatState = .initial {
        didSet { onChange?(state) }
    }
    /// Fired after every state transition with the new state (the SwiftUI
    /// wrapper republish hook; js gets this for free from useReducer).
    public var onChange: ((AgentChatState) -> Void)?
    public var callbacks = Callbacks()

    private let client: InferenceClient
    /// The agent ref new chats are created with (js: config.agent).
    public var agent: String
    private let streamEnabled: Bool
    private var streamTask: Task<Void, Never>?
    private var prevChatWasBusy = false

    public init(client: InferenceClient, agent: String, streamEnabled: Bool = true) {
        self.client = client
        self.agent = agent
        self.streamEnabled = streamEnabled
    }

    private func dispatch(_ action: ChatAction) {
        state = chatReducer(state, action)
    }

    private func checkTurnEnd(_ chat: ChatDTO) {
        let busy = chat.isBusy
        if prevChatWasBusy && !busy { callbacks.onTurnEnd?(chat) }
        prevChatWasBusy = busy
    }

    private func emitStatus(_ s: String) { callbacks.onStatusChange?(s) }

    private func setChat(_ chat: ChatDTO, cursor: String?, hasOlder: Bool?) {
        dispatch(.setChat(chat))
        if cursor != nil || hasOlder != nil {
            dispatch(.prependMessages(messages: [], cursor: cursor, hasMore: hasOlder ?? false))
        }
        emitStatus(chat.isBusy ? "streaming" : "idle")
        checkTurnEnd(chat)
    }

    // MARK: - Public actions (js publicActions)

    /// POST the message, creating the chat on first send, then ensure the
    /// stream is running. Files are already-uploaded refs; the message POST
    /// itself carries only text (server binds no files field) — parity with
    /// the js path where processFiles uploads and the POST ignores the refs.
    public func sendMessage(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        dispatch(.setConnectionStatus("streaming"))
        dispatch(.setError(nil))
        do {
            var chatId = state.chatId
            if chatId == nil {
                let chat = try await client.createChat(agent: agent)
                chatId = chat.id
                dispatch(.setChatId(chat.id))
                callbacks.onChatCreated?(chat.id)
            }
            guard let chatId else { return }
            let userMessage = try await client.sendChatMessage(chatId: chatId, message: trimmed)
            dispatch(.updateMessage(userMessage, partial: false))
            if streamTask == nil { streamChat(chatId) }
        } catch {
            dispatch(.setConnectionStatus("error"))
            dispatch(.setError(error.localizedDescription))
            callbacks.onError?(error)
        }
    }

    /// POST /chats/{id}/stop — the cancellation comes back over the stream.
    public func stopGeneration() {
        guard let chatId = state.chatId else { return }
        let client = self.client
        Task.detached { try? await client.stopChat(chatId) }
    }

    public func reset() {
        stopStream()
        dispatch(.reset)
    }

    public func clearError() {
        dispatch(.setError(nil))
        dispatch(.setConnectionStatus("idle"))
    }

    public func uploadFile(_ data: Data, filename: String, contentType: String) async throws -> FileDTO {
        try await client.files.upload(data, filename: filename, contentType: contentType)
    }

    public func submitToolResult(_ toolInvocationId: String, result: String) async throws {
        try await surfacing { try await self.client.submitToolResult(toolInvocationId, result: result) }
    }

    public func approveTool(_ toolInvocationId: String) async throws {
        try await surfacing { try await self.client.approveTool(toolInvocationId) }
    }

    public func rejectTool(_ toolInvocationId: String, reason: String? = nil) async throws {
        try await surfacing { try await self.client.rejectTool(toolInvocationId, reason: reason) }
    }

    /// Whitelists AND approves server-side in one call.
    public func alwaysAllowTool(_ toolInvocationId: String, toolName: String) async throws {
        guard let chatId = state.chatId else { return }
        try await surfacing {
            try await self.client.alwaysAllowTool(chatId: chatId, toolInvocationId: toolInvocationId, toolName: toolName)
        }
    }

    public func cancelMessage(_ messageId: String) async throws {
        do { try await client.cancelMessage(messageId) }
        catch {
            dispatch(.setError(error.localizedDescription))
            callbacks.onError?(error)
            throw error
        }
    }

    public func resolveInterrupt(_ interruptId: String, decision: String) async throws {
        try await surfacing { _ = try await self.client.resolveInterrupt(interruptId, decision: decision) }
    }

    /// Fetch the page before the current cursor. Returns whether more remain.
    @discardableResult
    public func loadOlderMessages() async -> Bool {
        guard let chatId = state.chatId, let cursor = state.messageCursor, !cursor.isEmpty else { return false }
        guard let page = try? await client.fetchMessagesPage(chatId: chatId, cursor: cursor) else { return false }
        if !page.items.isEmpty {
            dispatch(.prependMessages(messages: page.items, cursor: page.nextCursor, hasMore: page.hasNext))
        }
        return page.hasNext
    }

    /// Tear down and rebuild the stream for the current chat, refetching the
    /// chat and its messages. Swift addition (no js equivalent): iOS suspends
    /// a backgrounded SSE connection without killing it, so foregrounding
    /// must force a fresh one and catch up on whatever arrived meanwhile.
    public func refresh() {
        guard let chatId = state.chatId else { return }
        streamChat(chatId)
    }

    /// Attach to an existing chat (or detach with nil). Mirrors the js
    /// internal setChatId: same id is a no-op, nil resets, new id streams.
    public func setChatId(_ newChatId: String?) {
        guard newChatId != state.chatId else { return }
        guard let newChatId else {
            stopStream()
            dispatch(.reset)
            return
        }
        dispatch(.setChatId(newChatId))
        streamChat(newChatId)
    }

    // MARK: - Stream lifecycle (js streamChat / pollChat / stopStream)

    private func streamChat(_ id: String) {
        streamTask?.cancel()
        streamTask = nil
        dispatch(.setConnectionStatus("connecting"))
        emitStatus("connecting")

        streamTask = Task { [weak self] in
            // Initial fetch: chat + first message page (Chat.Get no longer
            // preloads messages).
            guard let client = self?.client else { return }
            do {
                let chat = try await client.fetchChat(id)
                var cursor: String?
                var hasOlder: Bool?
                if chat.chatMessages?.isEmpty ?? true {
                    let page = try await client.fetchMessagesPage(chatId: id)
                    chat.chatMessages = page.items
                    cursor = page.nextCursor
                    hasOlder = page.hasNext
                }
                guard let self, !Task.isCancelled else { return }
                self.setChat(chat, cursor: cursor, hasOlder: hasOlder)
            } catch {
                guard let self else { return }
                self.dispatch(.setConnectionStatus("idle"))
                self.emitStatus("idle")
                self.callbacks.onError?(error)
                return
            }

            guard let self else { return }
            if !self.streamEnabled {
                await self.pollLoop(id)
                return
            }

            self.dispatch(.setConnectionStatus("streaming"))
            self.emitStatus("streaming")
            self.deltaAccum = createLLMDeltaAccumulator()
            self.deltaTargetId = nil
            do {
                for try await event in client.chatStream(chatId: id) {
                    if Task.isCancelled { return }
                    self.apply(event)
                }
            } catch is CancellationError {
                return
            } catch {
                self.callbacks.onError?(error)
            }
            // Unexpected end (reconnects exhausted): mirror js onEnd.
            if !Task.isCancelled, self.streamTask != nil {
                self.streamTask = nil
                self.dispatch(.setConnectionStatus("idle"))
                self.emitStatus("idle")
            }
        }
    }

    /// Delta accumulator, scoped to ONE assistant message. The accumulator is
    /// cumulative, so sharing one across a stream concats `response` across
    /// every LLM phase of a tool run.
    private var deltaAccum = createLLMDeltaAccumulator()
    /// The message id `deltaAccum` is accumulating for.
    private var deltaTargetId: String?

    /// Apply one stream event — the exact event→action mapping of streamChat's
    /// listeners in actions.ts (delta scoping aside, see `deltaAccum`).
    private func apply(_ event: ChatStreamEvent) {
        switch event {
        case .chat(let chat):
            dispatch(.updateChat(chat))
            emitStatus(chat.isBusy ? "streaming" : "idle")
            checkTurnEnd(chat)
        case .message(let message, let fields):
            dispatch(.updateMessage(message, partial: fields != nil))
        case .run(let run):
            dispatch(.updateActiveRun(run))
            emitStatus(run.isActive ? "streaming" : "idle")
            if let chat = state.chat { checkTurnEnd(chat) }
        case .delta(let messageId, let raw):
            // The delta names its message, so no target is inferred from
            // stream position. A new target starts a fresh accumulator.
            if messageId != deltaTargetId {
                deltaTargetId = messageId
                deltaAccum = createLLMDeltaAccumulator()
            }
            deltaAccum.apply(raw)
            dispatch(.deltaToken(messageId: messageId, deltaAccum.toOutput()))
        }
    }

    /// Poll /chats/{id}/status; on any change refetch the chat + messages.
    private func pollLoop(_ id: String) async {
        dispatch(.setConnectionStatus("streaming"))
        emitStatus("streaming")
        var prevStatus: JSONValue?
        while !Task.isCancelled {
            if let status = try? await client.chats.getStatus(id).status, status != prevStatus {
                prevStatus = status
                if let chat = try? await client.fetchChat(id) {
                    var cursor: String?
                    var hasOlder: Bool?
                    if chat.chatMessages?.isEmpty ?? true,
                       let page = try? await client.fetchMessagesPage(chatId: id) {
                        chat.chatMessages = page.items
                        cursor = page.nextCursor
                        hasOlder = page.hasNext
                    }
                    setChat(chat, cursor: cursor, hasOlder: hasOlder)
                    for m in chat.chatMessages ?? [] { dispatch(.updateMessage(m, partial: false)) }
                }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func stopStream() {
        streamTask?.cancel()
        streamTask = nil
        dispatch(.setConnectionStatus("idle"))
        emitStatus("idle")
    }

    /// Shared error surface for the tool/interrupt calls (js repeats this
    /// catch in every action).
    private func surfacing(_ body: () async throws -> Void) async throws {
        do { try await body() }
        catch {
            dispatch(.setConnectionStatus("error"))
            dispatch(.setError(error.localizedDescription))
            callbacks.onError?(error)
            throw error
        }
    }
}
