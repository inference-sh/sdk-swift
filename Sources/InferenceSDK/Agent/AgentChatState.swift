// Mirrors js/sdk-js/src/agent/reducer.ts plus the state/action types section
// of js/sdk-js/src/agent/types.ts. Pure reducer, no actors, no Combine.
//
// Divergences from JS:
// - `ConnectionStatus` is the js agent module's `ChatStatus`
//   ('idle' | 'connecting' | 'streaming' | 'error'); renamed because the
//   generated Types.swift already has `ChatStatus` (the chat's own
//   busy/idle/awaiting_input/completed status).
// - SET_CHAT: js reads pagination bookkeeping off hidden fields the client
//   stuffs onto the DTO (`(chat as any)._messageCursor` /
//   `._hasOlderMessages`). ChatDTO is a fixed type with no expando props,
//   so setChat clears the cursor state (as js does when the hidden fields
//   are absent) and the caller follows up with a prependMessages carrying
//   no messages to seed cursor/hasMore (see AgentChatSession.setChat).
// - DELTA_TOKEN: js spreads the target's `content` and would throw if it were
//   undefined; here nil content is treated as an empty array.

import Foundation

// MARK: - State (js agent/types.ts)

/// js agent/types.ts `ChatStatus`: stream/poll connection state, not the
/// chat's own status.
public enum ConnectionStatus: String, Codable, Sendable {
    case idle
    case connecting
    case streaming
    case error
}

// js agent/types.ts `AgentInfo` (Partial<Pick<AgentVersionDTO,
// 'description' | 'example_prompts'>>) already exists in Swift: see
// `AgentInfo` in Agent/AgentAPI.swift.

/// js agent/types.ts `AgentChatState`.
public struct AgentChatState {
    /// Current chat ID (nil if no chat started).
    public var chatId: String?
    /// Chat messages.
    public var messages: [ChatMessageDTO]
    /// Connection status (stream/poll state, not chat.status).
    public var connectionStatus: ConnectionStatus
    /// Error message if connectionStatus is .error.
    public var error: String?
    /// The full chat object (if loaded).
    public var chat: ChatDTO?
    /// Cursor for loading older messages.
    public var messageCursor: String?
    /// Whether older messages exist beyond the current page.
    public var hasOlderMessages: Bool?
    /// Agent info fetched from the backend (description, example_prompts).
    public var agentInfo: AgentInfo?

    public init(
        chatId: String? = nil,
        messages: [ChatMessageDTO] = [],
        connectionStatus: ConnectionStatus = .idle,
        error: String? = nil,
        chat: ChatDTO? = nil,
        messageCursor: String? = nil,
        hasOlderMessages: Bool? = nil,
        agentInfo: AgentInfo? = nil
    ) {
        self.chatId = chatId
        self.messages = messages
        self.connectionStatus = connectionStatus
        self.error = error
        self.chat = chat
        self.messageCursor = messageCursor
        self.hasOlderMessages = hasOlderMessages
        self.agentInfo = agentInfo
    }

    /// js reducer.ts `initialState`.
    public static let initial = AgentChatState()
}

// MARK: - Actions (js agent/types.ts ChatAction)

public enum ChatAction {
    /// js SET_CHAT_ID.
    case setChatId(String?)
    /// js SET_CHAT. Cursor/hasMore ride a follow-up prependMessages instead
    /// of the js hidden `_messageCursor`/`_hasOlderMessages` fields (header).
    case setChat(ChatDTO?)
    /// js UPDATE_CHAT: update chat metadata without replacing messages.
    case updateChat(ChatDTO?)
    /// js UPDATE_ACTIVE_RUN.
    case updateActiveRun(AgentRunDTO)
    /// js UPDATE_CHAT with fields: merged into the chat held; another
    /// chat's update is dropped.
    case mergeChatFields(FieldUpdate)
    /// js UPDATE_ACTIVE_RUN with fields: merged into the active run; another
    /// run's update is dropped.
    case mergeActiveRunFields(FieldUpdate)
    /// js MERGE_CHAT_SETTINGS: what POST /chats/{id}/settings answered,
    /// merged into the chat held (ignored for another chat).
    case mergeChatSettings(ChatSettingsDTO)
    /// js MERGE_CHAT_AGENT: what POST /chats/{id}/agent answered (the agent
    /// the chat now runs on), merged into the chat held (ignored for another chat).
    case mergeChatAgent(ChatAgentDTO)
    /// js SET_MESSAGES.
    case setMessages([ChatMessageDTO])
    /// js PREPEND_MESSAGES.
    case prependMessages(messages: [ChatMessageDTO], cursor: String?, hasMore: Bool)
    /// js UPDATE_MESSAGE.
    case updateMessage(ChatMessageDTO)
    /// js UPDATE_MESSAGE with partial: merged into the message; an unknown
    /// message's update is dropped.
    case mergeMessageFields(FieldUpdate)
    /// js ADD_MESSAGE.
    case addMessage(ChatMessageDTO)
    /// js DELTA_TOKEN: accumulated LLM output (see DeltaAccumulator.toOutput())
    /// and the id of the message it belongs to.
    case deltaToken(messageId: String, [String: JSONValue])
    /// js SET_CONNECTION_STATUS.
    case setConnectionStatus(ConnectionStatus)
    /// js SET_ERROR.
    case setError(String?)
    /// js SET_AGENT_INFO.
    case setAgentInfo(AgentInfo)
    /// js RESET.
    case reset
}

// MARK: - Reducer (js agent/reducer.ts)

/// js reducer.ts deriveChatStatus().
func deriveChatStatus(_ run: AgentRunDTO?) -> ChatStatus {
    guard let run else { return .idle }
    if run.state.isWorking { return .busy }
    if run.isWaiting { return .waiting }
    if run.state.isInterrupted { return .awaitingInput }
    return .idle
}

/// `state` with `merge` applied to the chat it holds, when that chat is
/// `chatId`; unchanged otherwise (no chat, or one switched to meanwhile).
private func mergingIntoChat(_ state: AgentChatState, _ chatId: String,
                             _ merge: (inout ChatDTO) -> Void) -> AgentChatState {
    guard var chat = state.chat, chat.id == chatId else { return state }
    merge(&chat)
    var next = state
    next.chat = chat
    return next
}

/// js reducer.ts chatReducer(). Pure function: returns a new state value.
public func chatReducer(_ state: AgentChatState, _ action: ChatAction) -> AgentChatState {
    switch action {
    case .setChatId(let chatId):
        var next = state
        next.chatId = chatId
        return next

    case .setChat(let chat):
        var next = state
        guard let chat else {
            next.chat = nil
            next.messages = []
            next.connectionStatus = .idle
            next.messageCursor = nil
            next.hasOlderMessages = nil
            return next
        }
        next.chat = chat
        next.messages = (chat.chatMessages ?? []).sorted { $0.order < $1.order }
        // js reads _messageCursor/_hasOlderMessages off the DTO; absent here
        // (see header), so this clears them like js does when they are unset.
        next.messageCursor = nil
        next.hasOlderMessages = nil
        return next

    case .updateChat(let chat):
        // Update chat metadata without replacing messages.
        guard let chat else { return state }
        var next = state
        next.chat = chat
        return next

    case .mergeChatFields(let update):
        guard let chat = state.chat, chat.id == update.id,
              var merged = update.applied(to: chat, clearingOmitted: true) else { return state }
        // The projector's update names active_run_id, which ChatDTO does not
        // declare. The run object belongs to that id: a new or cleared active
        // run drops it until the run's own event arrives.
        if update.fields.contains("active_run_id"), merged.activeRun?.id != update.values["active_run_id"]?.stringValue {
            merged.activeRun = nil
        }
        var next = state
        next.chat = merged
        return next

    case .mergeActiveRunFields(let update):
        guard var chat = state.chat, let run = chat.activeRun, run.id == update.id,
              let merged = update.applied(to: run, clearingOmitted: true) else { return state }
        chat.activeRun = merged
        chat.status = deriveChatStatus(merged)
        var next = state
        next.chat = chat
        return next

    case .updateActiveRun(let run):
        guard var chat = state.chat else { return state }
        // js: { ...state.chat, active_run, status } (ChatDTO is a value type)
        chat.activeRun = run
        chat.status = deriveChatStatus(run)
        var next = state
        next.chat = chat
        return next

    // The settings and set-agent endpoints answer with only what they wrote.
    // Merge it into the chat it belongs to; a chat switched away from in the
    // meantime is left alone.
    case .mergeChatSettings(let settings):
        return mergingIntoChat(state, settings.chatId) { chat in
            chat.name = settings.name
            chat.visibility = settings.visibility
            // One write: agentData is boxed (@Indirect), each set reallocates.
            var data = chat.agentData
            data.allowAllTools = settings.allowAllTools
            data.disableHooks = settings.disableHooks
            data.memory = settings.memory
            chat.agentData = data
        }

    case .mergeChatAgent(let agent):
        return mergingIntoChat(state, agent.chatId) { chat in
            chat.agentId = agent.agentId
            chat.agent = agent.agent
            chat.agentVersionId = agent.agentVersionId
            chat.agentVersion = agent.agentVersion
        }

    case .setMessages(let messages):
        var next = state
        next.messages = messages
        return next

    case .prependMessages(let older, let cursor, let hasMore):
        let existingIds = Set(state.messages.map(\.id))
        let deduped = older.filter { !existingIds.contains($0.id) }
        var next = state
        next.messages = (deduped + state.messages).sorted { $0.order < $1.order }
        next.messageCursor = cursor
        next.hasOlderMessages = hasMore
        return next

    case .updateMessage(let message):
        var next = state
        if let existingIndex = state.messages.firstIndex(where: { $0.id == message.id }) {
            next.messages[existingIndex] = message
            return next
        }
        next.messages = (state.messages + [message]).sorted { $0.order < $1.order }
        return next

    case .mergeMessageFields(let update):
        guard let index = state.messages.firstIndex(where: { $0.id == update.id }) else { return state }
        // js normalizeMessage: null content keeps the content the message had.
        let named = update.values["content"] == .null ? update.fields.filter { $0 != "content" } : update.fields
        let applying = FieldUpdate(fields: named, values: update.values)
        guard let merged = applying.applied(to: state.messages[index], clearingOmitted: false) else { return state }
        var next = state
        next.messages[index] = merged
        return next

    case .addMessage(let message):
        var next = state
        next.messages = (state.messages + [message]).sorted { $0.order < $1.order }
        return next

    case .deltaToken(let messageId, let output):
        // Apply to the message the delta names. A message whose row has not
        // arrived yet is skipped rather than misattributed — its snapshot
        // carries the authoritative text.
        guard let targetIndex = state.messages.firstIndex(where: {
            $0.id == messageId
        }) else {
            return state
        }
        var target = state.messages[targetIndex]
        var content = target.content ?? []
        let response = output["response"]?.stringValue
        if let textIndex = content.firstIndex(where: { $0.type == .text }) {
            content[textIndex].text = response
        } else {
            // js line 104: create the text block at the front of content.
            content.insert(ChatMessageContent(type: .text, text: response), at: 0)
        }
        target.content = content
        var next = state
        next.messages[targetIndex] = target
        return next

    case .setConnectionStatus(let status):
        var next = state
        next.connectionStatus = status
        return next

    case .setError(let error):
        var next = state
        next.error = error
        return next

    case .setAgentInfo(let info):
        var next = state
        next.agentInfo = info
        return next

    case .reset:
        // js: { ...initialState, agentInfo: state.agentInfo }.
        var next = AgentChatState.initial
        next.agentInfo = state.agentInfo
        return next
    }
}
