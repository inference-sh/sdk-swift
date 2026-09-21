// SSE client for the chat stream. Mirrors StreamManager in sdk-js/src/http:
// typed events, {data, fields} partial wrapper, reconnect (max 5, 1s backoff,
// counter reset on any received event). Reuses HTTPLineStream so it builds on
// Linux (no URLSession.bytes there).

@preconcurrency import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One decoded event off the chat stream.
public enum ChatStreamEvent: Sendable {
    case chat(ChatDTO)
    case message(ChatMessageDTO, fields: [String]?)   // fields != nil => partial update
    case run(AgentRunDTO)
    /// Raw delta object (LLMDelta shape) — feed it to a DeltaAccumulator; the
    /// js SDK merges the whole object (response, reasoning, tool_calls, …),
    /// not just the text fields.
    /// A token delta and the id of the message it belongs to, from
    /// DeltaEvent.resourceId. Carried explicitly so consumers match instead of
    /// inferring a target from stream position.
    case delta(messageId: String, [String: JSONValue])
}

/// Server partial-update wrapper: `{ "data": <DTO>, "fields": ["..."] }`.
private struct PartialDataWrapper<T: Decodable>: Decodable {
    let data: T
    let fields: [String]
}

public extension InferenceClient {
    /// GET /chats/{id}/stream as SSE, with auto-reconnect (max 5, 1s backoff,
    /// counter resets after any successful event). Emits typed events until the
    /// consumer stops iterating or reconnects are exhausted.
    func chatStream(chatId: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        producerStream { continuation in
            let url = self.baseURL.appendingPathComponent("chats/\(chatId)/stream")
            let maxReconnects = 5
            let reconnectDelayMs: UInt64 = 1_000
            var attempts = 0
            var lastError: Error?

            while true {
                try Task.checkCancellation()

                // Build directly: request(...) sets Connection: close, which kills
                // a long-lived SSE stream.
                var req = URLRequest(url: url)
                req.httpMethod = "GET"
                req.setValue("Bearer \(self.apiKey)", forHTTPHeaderField: "Authorization")
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                // For a data task this is an INACTIVITY timeout (resets on every
                // byte). The server heartbeats every 10s (go/api common/stream),
                // so 45s of silence means the TCP connection is dead — surface it
                // so the reconnect loop below replaces it. `.infinity` here made
                // a stale connection hang forever with no error: the app sat
                // "thinking" while queued messages completed server-side unseen.
                req.timeoutInterval = 45

                let stream = HTTPLineStream()
                do {
                    let (status, _) = try await stream.start(req)
                    guard (200..<300).contains(status) else {
                        // Non-2xx is not transient: surface it, do not reconnect.
                        let body = try await stream.drain()
                        throw InferenceError.http(status: status, body: String(body.prefix(2000)))
                    }

                    // SSE frame state: an event ends on a blank line; `data:` lines
                    // concatenate with "\n"; lines starting with ":" are heartbeats.
                    var eventName = "message"
                    var dataBuffer = ""
                    var sawData = false
                    for try await line in stream.lines {
                        try Task.checkCancellation()
                        let text = String(decoding: line, as: UTF8.self)
                        if text.isEmpty {
                            if sawData, let event = Self.parseChatStreamEvent(eventName, dataBuffer) {
                                continuation.yield(event)
                                attempts = 0  // any event resets the reconnect counter
                            }
                            eventName = "message"; dataBuffer = ""; sawData = false
                            continue
                        }
                        if text.hasPrefix(":") { continue }  // heartbeat / comment
                        if text.hasPrefix("event:") {
                            eventName = Self.sseValue(text, after: "event:")
                        } else if text.hasPrefix("data:") {
                            let v = Self.sseValue(text, after: "data:")
                            dataBuffer += sawData ? "\n" + v : v
                            sawData = true
                        }
                        // id:/retry:/unknown fields ignored
                    }
                    // Stream ended without error: treat as an unexpected end and reconnect.
                    stream.cancel()
                } catch is CancellationError {
                    stream.cancel()
                    return
                } catch let e as InferenceError {
                    stream.cancel()
                    if case .http = e { throw e }  // non-2xx: no reconnect
                    lastError = e                  // transport error: reconnect
                } catch {
                    stream.cancel()
                    lastError = error              // transport error: reconnect
                }

                // Reconnect unless exhausted.
                if attempts >= maxReconnects {
                    if let lastError { throw lastError }
                    return
                }
                attempts += 1
                try await Task.sleep(nanoseconds: reconnectDelayMs * 1_000_000)
            }
        }
    }

    /// Strips a field prefix and one optional leading space, per the SSE grammar.
    private static func sseValue(_ line: String, after prefix: String) -> String {
        var v = Substring(line.dropFirst(prefix.count))
        if v.first == " " { v = v.dropFirst() }
        return String(v)
    }

    /// Decodes one SSE frame into a typed event. Unwraps the {data, fields}
    /// partial wrapper when present. Unknown event names yield nil.
    private static func parseChatStreamEvent(_ eventName: String, _ dataString: String) -> ChatStreamEvent? {
        let data = Data(dataString.utf8)
        switch eventName {
        case "chats":
            guard let (dto, _) = decodeMaybeWrapped(ChatDTO.self, data) else { return nil }
            return .chat(dto)
        case "chat_messages":
            guard let (dto, fields) = decodeMaybeWrapped(ChatMessageDTO.self, data) else { return nil }
            return .message(dto, fields: fields)
        case "agent_runs":
            guard let (dto, _) = decodeMaybeWrapped(AgentRunDTO.self, data) else { return nil }
            return .run(dto)
        case "delta":
            // No resource id means the server could not attribute the delta.
            // Drop it rather than pass an unattributable token downstream —
            // the message snapshot still carries the authoritative text.
            guard let (evt, _) = decodeMaybeWrapped(DeltaEvent.self, data),
                  let obj = evt.delta.objectValue,
                  let messageId = evt.resourceId, !messageId.isEmpty else { return nil }
            return .delta(messageId: messageId, obj)
        default:
            return nil
        }
    }

    /// Wrapper first ({data, fields}), then the bare DTO. Fields is nil unless wrapped.
    private static func decodeMaybeWrapped<T: Decodable>(_ type: T.Type, _ data: Data) -> (T, [String]?)? {
        // Same wire shims as the REST path (see InferenceClient.decode).
        let data = InferenceClient.patchWirePayload(data)
        if let w = try? decoder.decode(PartialDataWrapper<T>.self, from: data) {
            return (w.data, w.fields)
        }
        if let v = try? decoder.decode(T.self, from: data) {
            return (v, nil)
        }
        return nil
    }
}
