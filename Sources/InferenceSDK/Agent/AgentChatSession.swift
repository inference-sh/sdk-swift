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
//  - alwaysAllowTool takes the option key (`option: String?`) where js takes
//    `AlwaysAllowChoice | string`; the old `toolName:` form is kept,
//    deprecated, and saves the default option like the js string form.

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
        didSet {
            onChange?(state)
            observers.yield(state)
        }
    }
    /// Fired after every state transition with the new state (the SwiftUI
    /// wrapper republish hook; js gets this for free from useReducer). One
    /// owner only: setting it replaces the last. Anyone else listens with
    /// `changes()`.
    public var onChange: ((AgentChatState) -> Void)?
    private let observers = StateObservers()
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

    deinit { observers.finishAll() }

    /// `changes()` readers still registered (tests).
    var observerCount: Int { observers.count }

    /// Every state from now on, starting with the current one: a new stream
    /// per call, so any number of listeners can follow one session without
    /// taking `onChange` from its owner. Unbounded, so a slow reader still
    /// sees each transition (a busy turn that ended, not just the end). A
    /// reset yields the reset state; the stream finishes when the session is
    /// released or the reader stops iterating.
    public func changes() -> AsyncStream<AgentChatState> {
        let (stream, continuation) = AsyncStream.makeStream(of: AgentChatState.self)
        continuation.yield(state)
        observers.add(continuation)
        return stream
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

    /// Connection-state changes always dispatch AND surface through
    /// onStatusChange — one seam instead of the pair at every site.
    private func setConnection(_ s: ConnectionStatus) {
        dispatch(.setConnectionStatus(s))
        emitStatus(s.rawValue)
    }

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

        dispatch(.setConnectionStatus(.streaming))
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
            dispatch(.setConnectionStatus(.error))
            dispatch(.setError(error.localizedDescription))
            callbacks.onError?(error)
        }
    }

    /// POST /chats/{id}/stop — the cancellation comes back over the stream.
    public func stopGeneration() {
        guard let chatId = state.chatId else { return }
        let client = self.client
        Task.detached { try? await client.chats.stop(chatId) }
    }

    public func reset() {
        stopStream()
        dispatch(.reset)
    }

    public func clearError() {
        dispatch(.setError(nil))
        dispatch(.setConnectionStatus(.idle))
    }

    public func uploadFile(_ data: Data, filename: String, contentType: String) async throws -> FileDTO {
        try await client.files.upload(data, filename: filename, contentType: contentType)
    }

    public func submitToolResult(_ toolInvocationId: String, result: String) async throws {
        try await surfacing { try await self.client.submitToolResult(toolInvocationId, result: result) }
    }

    /// Answer an MCP tool call's input requests (an awaiting_input call whose
    /// data is an `MCPInputState`), one `ElicitResult` per request key. A 400
    /// (the answers were rejected, the call is still waiting) is thrown
    /// without touching `state`: show it next to the form.
    public func submitMCPInput(_ toolInvocationId: String, responses: [String: ElicitResult]) async throws {
        try await surfacing(passing: [400]) {
            try await self.client.submitToolResult(toolInvocationId, result: buildMCPInputResult(responses))
        }
    }

    public func approveTool(_ toolInvocationId: String) async throws {
        try await surfacing { try await self.client.approveTool(toolInvocationId) }
    }

    public func rejectTool(_ toolInvocationId: String, reason: String? = nil) async throws {
        try await surfacing { try await self.client.rejectTool(toolInvocationId, reason: reason) }
    }

    /// What "always allow" can save for this call, narrowest first; nil
    /// before the chat exists. Errors are thrown, not surfaced in `state`.
    public func getAlwaysAllowOptions(_ toolInvocationId: String) async throws -> AlwaysAllowOptionsDTO? {
        guard let chatId = state.chatId else { return nil }
        return try await client.getAlwaysAllowOptions(chatId: chatId, toolInvocationId: toolInvocationId)
    }

    /// Save an option (a key from `getAlwaysAllowOptions`; nil for the api's
    /// default) as chat rules and approve the call once. A 409 (the option is
    /// stale: read the options again) or 400 (nothing can be always-allowed
    /// here) is thrown without touching `state`: the call is still waiting
    /// and the connection is fine.
    @discardableResult
    public func alwaysAllowTool(_ toolInvocationId: String, option: String?) async throws -> AlwaysAllowResultDTO? {
        guard let chatId = state.chatId else { return nil }
        return try await surfacing(passing: [400, 409]) {
            try await self.client.alwaysAllowTool(chatId: chatId, toolInvocationId: toolInvocationId, option: option)
        }
    }

    /// The api reads the tool from the call; this saves the default option.
    @available(*, deprecated, message: "use alwaysAllowTool(_:option:) with a key from getAlwaysAllowOptions")
    public func alwaysAllowTool(_ toolInvocationId: String, toolName: String) async throws {
        try await alwaysAllowTool(toolInvocationId, option: nil)
    }

    /// Explain a call awaiting approval in plain words. Throws without a chat.
    public func explainTool(_ toolInvocationId: String) async throws -> ToolExplanationDTO {
        guard let chatId = state.chatId else { throw InferenceError.http(status: 400, body: "no chat to explain a tool call in") }
        return try await client.explainTool(chatId: chatId, toolInvocationId: toolInvocationId)
    }

    /// Change this chat's settings and merge the answer into `state.chat`
    /// (e.g. `allowAllTools: true`, which also approves the calls waiting).
    /// A no-op before the chat exists. Errors set `state.error` and throw.
    public func updateChatSettings(_ settings: ChatSettingsRequest) async throws {
        guard let chatId = state.chatId else { return }
        let merged = try await surfacing(connection: false) { try await self.client.updateChatSettings(chatId: chatId, settings) }
        dispatch(.mergeChatSettings(merged))
    }

    /// Hand this chat to another agent (namespace/name); the next message
    /// goes to it. Only agents our loop runs: the api refuses others, and the
    /// refusal sets `state.error` and is thrown. A no-op before the chat exists.
    public func switchAgent(_ agentRef: String) async throws {
        guard let chatId = state.chatId else { return }
        let agent = try await surfacing(connection: false) { try await self.client.setAgent(chatId: chatId, agent: agentRef) }
        dispatch(.mergeChatAgent(agent))
    }

    public func cancelMessage(_ messageId: String) async throws {
        try await surfacing(connection: false) { try await self.client.chats.cancelMessage(messageId) }
    }

    public func resolveInterrupt(_ interruptId: String, decision: String) async throws {
        try await surfacing { _ = try await self.client.resolveInterrupt(interruptId, decision: decision) }
    }

    /// Fetch the page before the current cursor. Returns whether more remain.
    @discardableResult
    public func loadOlderMessages() async -> Bool {
        guard let chatId = state.chatId, let cursor = state.messageCursor, !cursor.isEmpty else { return false }
        guard let page = try? await client.fetchMessagesPage(chatId: chatId, cursor: cursor) else { return false }
        if let items = page.items, !items.isEmpty {
            dispatch(.prependMessages(messages: items, cursor: page.nextCursor, hasMore: page.hasNext))
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
        guard let newChatId else { reset(); return }
        dispatch(.setChatId(newChatId))
        streamChat(newChatId)
    }

    // MARK: - Stream lifecycle (js streamChat / pollChat / stopStream)

    private func streamChat(_ id: String) {
        streamTask?.cancel()
        streamTask = nil
        setConnection(.connecting)

        streamTask = Task { [weak self] in
            do {
                guard let self, let loaded = try await self.loadChat(id), !Task.isCancelled else { return }
                self.setChat(loaded.chat, cursor: loaded.cursor, hasOlder: loaded.hasOlder)
            } catch {
                guard let self else { return }
                self.setConnection(.idle)
                self.callbacks.onError?(error)
                return
            }

            guard let self else { return }
            if !self.streamEnabled {
                await self.pollLoop(id)
                return
            }

            self.setConnection(.streaming)
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
                self.setConnection(.idle)
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
        setConnection(.streaming)
        var prevStatus: JSONValue?
        while !Task.isCancelled {
            if let status = try? await client.chats.getStatus(id).status, status != prevStatus {
                prevStatus = status
                // setChat installs chat.chatMessages wholesale — no
                // per-message dispatch needed.
                if let loaded = try? await loadChat(id) {
                    setChat(loaded.chat, cursor: loaded.cursor, hasOlder: loaded.hasOlder)
                }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    /// Fetch the chat and, since Chat.Get no longer preloads messages, its
    /// first message page. Shared by the stream and poll paths.
    private func loadChat(_ id: String) async throws -> (chat: ChatDTO, cursor: String?, hasOlder: Bool?)? {
        var chat = try await client.chats.get(id)
        var cursor: String?
        var hasOlder: Bool?
        if chat.chatMessages?.isEmpty ?? true {
            let page = try await client.fetchMessagesPage(chatId: id)
            chat.chatMessages = page.items
            cursor = page.nextCursor
            hasOlder = page.hasNext
        }
        return (chat, cursor, hasOlder)
    }

    private func stopStream() {
        streamTask?.cancel()
        streamTask = nil
        setConnection(.idle)
    }

    /// Shared error surface for the tool/interrupt calls (js repeats this
    /// catch in every action).
    /// Runs `body`; a failure sets `state.error`, calls `onError` and is
    /// thrown. `passing`: HTTP statuses thrown untouched (the caller shows
    /// them in place: the request was refused, the connection is fine).
    /// `connection`: whether a failure also marks the connection failed.
    @discardableResult
    private func surfacing<T>(passing: Set<Int> = [], connection: Bool = true,
                              _ body: () async throws -> T) async throws -> T {
        do { return try await body() }
        catch {
            if case InferenceError.http(let status, _) = error, passing.contains(status) { throw error }
            if connection { dispatch(.setConnectionStatus(.error)) }
            dispatch(.setError(error.localizedDescription))
            callbacks.onError?(error)
            throw error
        }
    }
}

/// The continuations `changes()` handed out. Locked rather than main-actor
/// bound: a reader that stops iterating removes itself from any thread, and
/// the session's deinit is not isolated.
private final class StateObservers: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    private var continuations: [Int: AsyncStream<AgentChatState>.Continuation] = [:]

    func add(_ continuation: AsyncStream<AgentChatState>.Continuation) {
        lock.lock()
        let id = next
        next += 1
        continuations[id] = continuation
        lock.unlock()
        continuation.onTermination = { [weak self] _ in self?.remove(id) }
    }

    private func remove(_ id: Int) {
        lock.lock(); defer { lock.unlock() }
        continuations[id] = nil
    }

    /// Readers still registered; tests check a reader that left is dropped.
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return continuations.count
    }

    func yield(_ state: AgentChatState) {
        lock.lock()
        let all = Array(continuations.values)
        lock.unlock()
        for c in all { c.yield(state) }
    }

    func finishAll() {
        lock.lock()
        let all = Array(continuations.values)
        continuations = [:]
        lock.unlock()
        for c in all { c.finish() }
    }
}
