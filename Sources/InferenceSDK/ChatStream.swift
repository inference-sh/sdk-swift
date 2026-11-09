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
    case message(ChatMessageDTO)
    case run(AgentRunDTO)
    /// A token delta and the id of the message it belongs to, from
    /// DeltaEvent.resourceId. Carried explicitly so consumers match instead of
    /// inferring a target from stream position.
    case delta(messageId: String, [String: JSONValue])
    /// Partial updates: only the named fields of the object, see FieldUpdate.
    case chatFields(FieldUpdate)
    case messageFields(FieldUpdate)
    case runFields(FieldUpdate)
}

/// A partial stream update: the server's `{ "data": ..., "fields": [...] }`
/// with only the named fields in `data`. It cannot decode as a DTO, so it
/// stays JSON and merges into the object it updates.
public struct FieldUpdate: Sendable, Equatable {
    public let fields: [String]
    public let values: [String: JSONValue]

    public init(fields: [String], values: [String: JSONValue]) {
        self.fields = fields
        self.values = values
    }

    /// The id of the object this update belongs to.
    public var id: String? { values["id"]?.stringValue }

    /// `existing` with the named fields applied, nil if the result is not a
    /// valid `T`. `clearingOmitted`: a named field missing from the payload
    /// was cleared (omitempty), so it is removed.
    func applied<T: Codable>(to existing: T, clearingOmitted: Bool) -> T? {
        guard let encoded = try? InferenceClient.encoder.encode(existing),
              var object = try? InferenceClient.decoder.decode([String: JSONValue].self, from: encoded) else {
            return nil
        }
        for field in fields {
            if let value = values[field] {
                object[field] = value
            } else if clearingOmitted {
                object[field] = nil
            }
        }
        guard let merged = try? InferenceClient.encoder.encode(object) else { return nil }
        return try? InferenceClient.decoder.decode(T.self, from: merged)
    }
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
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                req.setValue(self.clientSource, forHTTPHeaderField: "X-Client-Source")
                // For a data task this is an INACTIVITY timeout (resets on every
                // byte). The server heartbeats every 10s (go/api common/stream),
                // so 45s of silence means the TCP connection is dead — surface it
                // so the reconnect loop below replaces it. `.infinity` here made
                // a stale connection hang forever with no error: the app sat
                // "thinking" while queued messages completed server-side unseen.
                req.timeoutInterval = 45

                // openLineStream asks `auth` for a token on every connect,
                // retries a 401 once with a forced refresh and throws a
                // non-2xx answer as InferenceError.http, which is not
                // transient: surfaced below, never reconnected.
                var stream: HTTPLineStream?
                do {
                    let (opened, _) = try await self.openLineStream(req)
                    stream = opened

                    // SSE frame state: an event ends on a blank line; `data:` lines
                    // concatenate with "\n"; lines starting with ":" are heartbeats.
                    var eventName = "message"
                    var dataBuffer = ""
                    var sawData = false
                    for try await line in opened.lines {
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
                    opened.cancel()
                } catch is CancellationError {
                    stream?.cancel()
                    return
                } catch let e as InferenceError {
                    stream?.cancel()
                    if case .http = e { throw e }  // non-2xx: no reconnect
                    lastError = e                  // transport error: reconnect
                } catch let e as OAuthError where e.isPermanent {
                    stream?.cancel()
                    throw e                        // signed out: reconnecting cannot help
                } catch {
                    stream?.cancel()
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

    /// Decodes one SSE frame into a typed event. A {data, fields} wrapper is a
    /// partial update. Unknown event names yield nil.
    private static func parseChatStreamEvent(_ eventName: String, _ dataString: String) -> ChatStreamEvent? {
        let data = Data(dataString.utf8)
        switch eventName {
        case "chats":
            if let update = fieldUpdate(data) { return .chatFields(update) }
            return (try? decoder.decode(ChatDTO.self, from: data)).map(ChatStreamEvent.chat)
        case "chat_messages":
            if let update = fieldUpdate(data) { return .messageFields(update) }
            return (try? decoder.decode(ChatMessageDTO.self, from: data)).map(ChatStreamEvent.message)
        case "agent_runs":
            if let update = fieldUpdate(data) { return .runFields(update) }
            return (try? decoder.decode(AgentRunDTO.self, from: data)).map(ChatStreamEvent.run)
        case "delta":
            // No resource id means the server could not attribute the delta.
            // Drop it rather than pass an unattributable token downstream —
            // the message snapshot still carries the authoritative text.
            guard let evt = decodeMaybeWrapped(DeltaEvent.self, data),
                  let obj = evt.delta.objectValue,
                  let messageId = evt.resourceId, !messageId.isEmpty else { return nil }
            return .delta(messageId: messageId, obj)
        default:
            return nil
        }
    }

    /// The partial update in a {data, fields} frame, nil for a bare object.
    private static func fieldUpdate(_ data: Data) -> FieldUpdate? {
        guard let w = try? decoder.decode(PartialDataWrapper<[String: JSONValue]>.self, from: data) else { return nil }
        return FieldUpdate(fields: w.fields, values: w.data)
    }

    /// Wrapper first ({data, fields}), then the bare value.
    private static func decodeMaybeWrapped<T: Decodable>(_ type: T.Type, _ data: Data) -> T? {
        if let w = try? decoder.decode(PartialDataWrapper<T>.self, from: data) { return w.data }
        return try? decoder.decode(T.self, from: data)
    }
}
