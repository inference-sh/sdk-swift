// Hand-written transport. Types.swift next to it is generated; see README.

@preconcurrency import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum InferenceError: Error, LocalizedError, Sendable {
    case http(status: Int, body: String)
    case noAssistantMessage
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            // RFC 9457 problem details when the API sent them.
            if let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
               let detail = (obj["detail"] ?? obj["title"]) as? String {
                return "HTTP \(status): \(detail)"
            }
            return "HTTP \(status): \(body)"
        case .noAssistantMessage: return "No assistant message in response (message was queued?)"
        case .transport(let s): return s
        }
    }
}

/// The API has one response format: JSON responses are
/// `{"data": <dto>, "messages": [...]}`, errors are RFC 9457 problem details,
/// streams carry bare DTOs. Send no version header; the JS and Python SDKs and
/// the CLIs send none either (see js/sdk-js/src/http/client.ts).
public struct InferenceClient: Sendable {
    public var baseURL: URL
    public var apiKey: String
    /// Called with any warnings or notices the server attached to a response.
    public var onMessage: (@Sendable ([ResponseMessage]) -> Void)?

    public init(baseURL: URL = URL(string: "https://api.inference.sh")!, apiKey: String,
                onMessage: (@Sendable ([ResponseMessage]) -> Void)? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.onMessage = onMessage
    }

    // MARK: - Agents

    /// POST /agents/run without streaming. Returns immediately; the assistant
    /// message is usually still `pending`.
    public func runAgent(_ body: ApiAgentRunRequest) async throws -> CreateAgentMessageResponse {
        var body = body
        body.stream = false
        return try await decode(send(request("agents/run", body: body)))
    }

    /// POST /agents/run with `stream: true`. Yields assistant message snapshots
    /// (full DTO each time, not deltas) until the message reaches a terminal
    /// status. Uses NDJSON: one object per line, `{"type":"heartbeat"}` every
    /// 10s, aux events wrapped as `{"event":..,"data":..}`.
    public func runAgentStream(_ body: ApiAgentRunRequest) -> AsyncThrowingStream<ChatMessageDTO, Error> {
        producerStream { continuation in
            var body = body
            body.stream = true
            let stream = HTTPLineStream()
            defer { stream.cancel() }
            let (status, contentType) = try await stream.start(request("agents/run", accept: "application/x-ndjson", body: body))

            if !(200..<300).contains(status) || !contentType.contains("ndjson") {
                let text = try await stream.drain()
                guard (200..<300).contains(status) else { throw InferenceError.http(status: status, body: text) }
                // Plain JSON answer: message queued on a busy chat.
                let resp: CreateAgentMessageResponse = try decode(Data(text.utf8))
                guard let msg = resp.assistantMessage else { throw InferenceError.noAssistantMessage }
                continuation.yield(msg)
                return
            }

            for try await line in stream.lines {
                guard let msg = Self.parseStreamLine(line), msg.role == .assistant else { continue }
                continuation.yield(msg)
                if msg.status.isTerminal { return }
            }
        }
    }

    /// One NDJSON line → ChatMessageDTO, or nil for heartbeats, aux events and
    /// partial-field wrappers. Single parse: the envelope check and the DTO
    /// decode share one decoder pass.
    public static func parseStreamLine(_ line: Data) -> ChatMessageDTO? {
        guard line.first == UInt8(ascii: "{") else { return nil }
        return (try? decoder.decode(StreamLine.self, from: line))?.message
    }

    /// POST /chats/{id}/stop: cancel the active agent run and pending tool
    /// invocations. The stream then ends with a `cancelled` message.
    public func stopChat(_ chatId: String) async throws {
        _ = try await send(request("chats/\(chatId)/stop"))
    }

    // MARK: - Apps

    /// GET /apps/{namespace}/{name}. Includes the active version with its schemas.
    public func getApp(_ ref: String) async throws -> AppDTO {
        let bare = ref.split(separator: "@").first.map(String.init) ?? ref
        return try await decode(send(request("apps/\(bare)", method: "GET"), retries: 1))
    }

    /// POST /run with `wait: true`. Blocks until the task is terminal and
    /// returns the result. Failed and cancelled tasks come back as HTTP 422,
    /// surfaced as `InferenceError.http`.
    public func runApp(_ body: ApiAppRunRequest) async throws -> TaskResultDTO {
        var body = body
        body.wait = true
        return try await decode(send(request("run", body: body)))
    }

    /// GET an output file (unauthenticated CDN URL as returned in task output).
    public func download(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 120
        return try await send(req)
    }

    // MARK: - Files

    /// Two-step upload, same as the JS SDK: POST /files creates the record
    /// and returns a presigned `upload_url`; the bytes are PUT there. The
    /// returned `uri` goes into task inputs.
    public func uploadFile(_ data: Data, filename: String, contentType: String) async throws -> FileDTO {
        let create = FileCreateRequest(files: [PartialFile(uri: "", contentType: contentType, size: data.count, filename: filename)])
        let files: [FileDTO] = try await decode(send(request("files", body: create)))
        guard let file = files.first, let uploadURL = URL(string: file.uploadUrl) else {
            throw InferenceError.transport("POST /files returned no upload_url")
        }
        var put = URLRequest(url: uploadURL)
        put.httpMethod = "PUT"
        put.setValue(contentType, forHTTPHeaderField: "Content-Type")
        put.setValue("", forHTTPHeaderField: "Expect") // R2 resets on 100-continue
        put.timeoutInterval = 300
        _ = try await send(put, upload: data, retries: 2)
        return file
    }

    // MARK: - Plumbing

    public static let decoder = JSONDecoder()
    public static let encoder = JSONEncoder()

    func request(_ path: String, method: String = "POST", accept: String = "application/json") -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        // One connection per call. A reused keep-alive connection that the
        // server has already closed surfaces as "connection reset" on the next
        // POST, and a POST is not safe to retry blindly.
        req.setValue("close", forHTTPHeaderField: "Connection")
        req.timeoutInterval = 300
        return req
    }

    func request<B: Encodable>(_ path: String, accept: String = "application/json", body: B) throws -> URLRequest {
        var req = request(path, accept: accept)
        req.httpBody = try Self.encoder.encode(body)
        return req
    }

    /// Unwraps the V3 envelope and forwards its messages. Internal so the chat
    /// endpoint extensions (ChatAPI.swift) share the same path.
    func decode<T: Decodable>(_ data: Data) throws -> T {
        let envelope = try Self.decoder.decode(Envelope<T>.self, from: Self.patchNullMemory(data))
        if let onMessage, let messages = envelope.messages, !messages.isEmpty { onMessage(messages) }
        return envelope.data
    }

    /// The generated `ChatData.memory` is a non-optional map, but the API sends
    /// `"agent_data": {"memory": null}`, which makes every ChatDTO decode fail
    /// with "data missing". Types.swift is generated (the real fix is Go-side +
    /// `make types`), so as a transport-layer shim we coerce any null `memory`
    /// to `{}` before decoding. No-op for payloads without it.
    static func patchNullMemory(_ data: Data) -> Data {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return data }
        func fix(_ any: Any) -> Any {
            if let dict = any as? [String: Any] {
                var out = dict
                for (k, v) in dict {
                    if k == "memory", v is NSNull { out[k] = [String: Any]() }
                    else { out[k] = fix(v) }
                }
                return out
            }
            if let arr = any as? [Any] { return arr.map(fix) }
            return any
        }
        return (try? JSONSerialization.data(withJSONObject: fix(obj))) ?? data
    }

    /// One-shot request. Throws `InferenceError.http` on non-2xx. Honors Swift
    /// task cancellation by cancelling the URL task. A raw body goes through an
    /// upload task (Content-Length, no chunking), which presigned storage
    /// URLs require. `retries` re-sends on transport errors only; pass it for
    /// idempotent calls (GET, presigned PUT). Linux's libcurl 7.81 resets the
    /// first connection to some hosts and succeeds on the next.
    func send(_ req: URLRequest, upload: Data? = nil, retries: Int = 0) async throws -> Data {
        var attempt = 0
        while true {
            do {
                return try await sendOnce(req, upload: upload)
            } catch InferenceError.transport(let msg) where attempt < retries && !Task.isCancelled {
                attempt += 1
                if ProcessInfo.processInfo.environment["INFERENCE_DEBUG"] != nil {
                    FileHandle.standardError.write(Data("retry \(attempt) after: \(msg)\n".utf8))
                }
            }
        }
    }

    private func sendOnce(_ req: URLRequest, upload: Data?) async throws -> Data {
        if ProcessInfo.processInfo.environment["INFERENCE_DEBUG"] != nil {
            FileHandle.standardError.write(Data("→ \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "") \(upload?.count ?? req.httpBody?.count ?? 0)B\n".utf8))
        }
        let box = TaskBox()
        let (data, status): (Data, Int) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                let handler: @Sendable (Data?, URLResponse?, Error?) -> Void = { data, resp, err in
                    if let err { c.resume(throwing: InferenceError.transport(err.localizedDescription)); return }
                    c.resume(returning: (data ?? Data(), (resp as? HTTPURLResponse)?.statusCode ?? 0))
                }
                let task: URLSessionTask = upload.map { URLSession.shared.uploadTask(with: req, from: $0, completionHandler: handler) }
                    ?? URLSession.shared.dataTask(with: req, completionHandler: handler)
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
        guard (200..<300).contains(status) else {
            throw InferenceError.http(status: status, body: String(decoding: data.prefix(2000), as: UTF8.self))
        }
        return data
    }
}

/// V3 response envelope.
struct Envelope<T: Decodable>: Decodable {
    let data: T
    let messages: [ResponseMessage]?
}

final class TaskBox: @unchecked Sendable {
    var task: URLSessionTask?
}

/// Envelope for one NDJSON line of a chat stream: bare ChatMessageDTOs are the
/// payload; `{"type":"heartbeat"}`, `{"event":..}` and `{"data":..,"fields":..}`
/// are skipped without a second parse.
struct StreamLine: Decodable {
    let message: ChatMessageDTO?
    private enum Keys: String, CodingKey { case type, event, fields }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if c.contains(.type) || c.contains(.event) || c.contains(.fields) {
            message = nil
        } else {
            message = try ChatMessageDTO(from: decoder)
        }
    }
}

/// Runs `body` in a task feeding the stream; cancels the task when the
/// consumer stops iterating.
func producerStream<T>(_ body: @escaping @Sendable (AsyncThrowingStream<T, Error>.Continuation) async throws -> Void) -> AsyncThrowingStream<T, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                try await body(continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

// MARK: - Convenience on generated types

public extension ChatMessageStatus {
    /// Mirrors ChatMessageStatus.IsTerminal() in Go.
    var isTerminal: Bool { self == .ready || self == .failed || self == .cancelled }
}

public extension TaskStatus {
    /// completed, failed or cancelled.
    var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
}

public extension TaskResultDTO {
    /// URL of a file output. Apps return either a bare URL string or `{"uri": ...}`.
    func fileURL(_ key: String) -> URL? {
        guard let v = output[key] else { return nil }
        if let s = v.stringValue { return URL(string: s) }
        if let s = v["uri"]?.stringValue { return URL(string: s) }
        return nil
    }
}

public extension ChatMessageDTO {
    /// Concatenated text blocks.
    var text: String {
        (content ?? []).filter { $0.type == .text }.compactMap(\.text).joined()
    }
    var errorText: String? {
        (content ?? []).compactMap(\.error).first
    }
}

// MARK: - Text to speech over any TTS app

/// Runs a text-to-speech app and hands back audio. Input key, output key and
/// text limit are read from the app's schemas once (or passed explicitly), so
/// inworld/*, infsh/kokoro-tts and others work without per-app code.
public actor TextToSpeech {
    public struct Spec: Sendable {
        public var inputKey: String
        public var outputKey: String
        public var maxChars: Int
    }

    public let client: InferenceClient
    public let app: String
    /// Extra app inputs sent with every chunk (voice, language, speed, …).
    public let extraInput: [String: JSONValue]
    private var spec: Spec?
    private let overrides: (inputKey: String?, outputKey: String?, maxChars: Int?)

    public init(client: InferenceClient, app: String, extraInput: [String: JSONValue] = [:],
                inputKey: String? = nil, outputKey: String? = nil, maxChars: Int? = nil) {
        self.client = client
        self.app = app
        self.extraInput = extraInput
        overrides = (inputKey, outputKey, maxChars)
    }

    /// Yields one audio file per chunk, in order. The next chunk is submitted
    /// while the current one downloads, so playback of long replies is not
    /// bounded by synthesis latency per chunk.
    public nonisolated func synthesize(_ text: String) -> AsyncThrowingStream<Data, Error> {
        producerStream { continuation in
            let spec = try await self.resolveSpec()
            let chunks = TextToSpeech.chunk(text, max: spec.maxChars)
            var next = chunks.first.map { c in Task { try await self.synthesizeChunk(c, spec: spec) } }
            defer { next?.cancel() }
            for i in chunks.indices {
                guard let current = next else { break }
                next = i + 1 < chunks.count ? Task { try await self.synthesizeChunk(chunks[i + 1], spec: spec) } : nil
                continuation.yield(try await current.value)
            }
        }
    }

    private func synthesizeChunk(_ chunk: String, spec: Spec) async throws -> Data {
        let input = extraInput.merging([spec.inputKey: .string(chunk)]) { _, chunk in chunk }
        let result = try await client.runApp(ApiAppRunRequest(app: app, input: .object(input)))
        guard let url = result.fileURL(spec.outputKey) else {
            throw InferenceError.transport("\(app) returned no '\(spec.outputKey)' output: \(result.output)")
        }
        return try await client.download(url)
    }

    public func resolveSpec() async throws -> Spec {
        if let spec { return spec }
        var resolved = Spec(inputKey: overrides.inputKey ?? "", outputKey: overrides.outputKey ?? "", maxChars: overrides.maxChars ?? 0)
        if resolved.inputKey.isEmpty || resolved.outputKey.isEmpty || resolved.maxChars == 0 {
            let version = try await client.getApp(app).version
            let input = version?.inputSchema ?? .null
            if resolved.inputKey.isEmpty { resolved.inputKey = TextToSpeech.inputKey(fromSchema: input) }
            if resolved.outputKey.isEmpty { resolved.outputKey = TextToSpeech.outputKey(fromSchema: version?.outputSchema ?? .null) }
            if resolved.maxChars == 0 {
                let limit = input["properties"]?[resolved.inputKey]?["maxLength"]?.doubleValue
                resolved.maxChars = limit.map(Int.init) ?? TextToSpeech.defaultMaxChars
            }
        }
        spec = resolved
        return resolved
    }

    /// Used when the input schema declares no maxLength.
    public static let defaultMaxChars = 1800

    /// `text`, then `prompt`, then `input`, then the first required string
    /// property, then `text`.
    public static func inputKey(fromSchema schema: JSONValue) -> String {
        let props = schema["properties"]?.objectValue ?? [:]
        for candidate in ["text", "prompt", "input"] where props[candidate] != nil {
            return candidate
        }
        for req in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            if props[req]?["type"]?.stringValue == "string" { return req }
        }
        return "text"
    }

    /// `audio` when present, else the first file-typed property, else `audio`.
    public static func outputKey(fromSchema schema: JSONValue) -> String {
        let props = schema["properties"]?.objectValue ?? [:]
        if props["audio"] != nil { return "audio" }
        for (key, prop) in props.sorted(by: { $0.key < $1.key }) where prop["format"]?.stringValue == "file" {
            return key
        }
        return "audio"
    }

    /// Splits on sentence ends, then on whitespace, so no chunk exceeds `max`.
    public static func chunk(_ text: String, max: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > max else { return trimmed.isEmpty ? [] : [trimmed] }
        var pieces: [String] = []
        for s in trimmed.split(omittingEmptySubsequences: true, whereSeparator: { ".!?\n".contains($0) }) {
            let str = String(s).trimmingCharacters(in: .whitespaces)
            if str.count <= max {
                pieces.append(str + ".")
            } else {
                pieces.append(contentsOf: str.split(separator: " ").map(String.init))
            }
        }
        var chunks: [String] = []
        var current = ""
        for piece in pieces {
            if current.count + piece.count + 1 > max, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += current.isEmpty ? piece : " " + piece
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

// MARK: - Speech to text over any transcription app

/// Uploads audio and runs a transcription app (inworld/speech-to-text,
/// infsh/fast-whisper-large-v3, …). Input key is the first file-typed property
/// of the input schema, output key is `text`; both overridable.
public actor SpeechToText {
    public struct Spec: Sendable {
        public var inputKey: String
        public var outputKey: String
    }

    public let client: InferenceClient
    public let app: String
    /// Extra app inputs (language hint, diarize, …). Formats are per app:
    /// elevenlabs/stt `language_code: "eng"`, inworld `language: "en-US"`,
    /// whisper `language: "english"`.
    public let extraInput: [String: JSONValue]
    private var spec: Spec?
    private let overrides: (inputKey: String?, outputKey: String?)

    public init(client: InferenceClient, app: String, extraInput: [String: JSONValue] = [:],
                inputKey: String? = nil, outputKey: String? = nil) {
        self.client = client
        self.app = app
        self.extraInput = extraInput
        overrides = (inputKey, outputKey)
    }

    /// Upload, run with wait, return the transcript.
    public func transcribe(_ audio: Data, filename: String = "audio.wav", contentType: String = "audio/wav") async throws -> String {
        let spec = try await resolveSpec()
        let file = try await client.uploadFile(audio, filename: filename, contentType: contentType)
        let input = extraInput.merging([spec.inputKey: .string(file.uri)]) { _, uri in uri }
        let result = try await client.runApp(ApiAppRunRequest(app: app, input: .object(input)))
        guard let text = result.output[spec.outputKey]?.stringValue else {
            throw InferenceError.transport("\(app) returned no '\(spec.outputKey)' output: \(result.output)")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func resolveSpec() async throws -> Spec {
        if let spec { return spec }
        var resolved = Spec(inputKey: overrides.inputKey ?? "", outputKey: overrides.outputKey ?? "text")
        if resolved.inputKey.isEmpty {
            let version = try await client.getApp(app).version
            resolved.inputKey = SpeechToText.inputKey(fromSchema: version?.inputSchema ?? .null)
        }
        spec = resolved
        return resolved
    }

    /// `audio` when present, else the first file-typed property, else `audio`.
    public static func inputKey(fromSchema schema: JSONValue) -> String {
        let props = schema["properties"]?.objectValue ?? [:]
        if props["audio"] != nil { return "audio" }
        for (key, prop) in props.sorted(by: { $0.key < $1.key }) where prop["format"]?.stringValue == "file" {
            return key
        }
        return "audio"
    }
}

/// Parses "namespace/name key=value key=value" as typed by a user into an app
/// ref plus extra inputs. Values that parse as numbers or booleans are typed.
public func parseAppSpec(_ text: String) -> (app: String, extraInput: [String: JSONValue]) {
    var parts = text.split(separator: " ").map(String.init)
    guard !parts.isEmpty else { return ("", [:]) }
    let app = parts.removeFirst()
    var extra: [String: JSONValue] = [:]
    for part in parts {
        guard let eq = part.firstIndex(of: "=") else { continue }
        let key = String(part[..<eq]), raw = String(part[part.index(after: eq)...])
        if let b = Bool(raw) { extra[key] = .bool(b) }
        else if let d = Double(raw) { extra[key] = .number(d) }
        else { extra[key] = .string(raw) }
    }
    return (app, extra)
}

// MARK: - Line-oriented HTTP body stream
//
// Delegate based so it works on Linux (no URLSession.bytes there). One shared
// session keeps the connection pool warm across turns; the router hands each
// task's callbacks to the HTTPLineStream that owns it.

final class HTTPLineStream: @unchecked Sendable {
    let lines: AsyncThrowingStream<Data, Error>
    private let lineContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private var buffer = Data()
    private var headerContinuation: CheckedContinuation<(Int, String), Error>?
    private var task: URLSessionDataTask?

    init() {
        (lines, lineContinuation) = AsyncThrowingStream.makeStream(of: Data.self)
    }

    /// Starts the request and resolves with (status, content-type) once headers arrive.
    func start(_ request: URLRequest) async throws -> (Int, String) {
        let router = LineSessionRouter.shared
        let task = router.session.dataTask(with: request)
        self.task = task
        router.register(self, for: task)
        return try await withCheckedThrowingContinuation { c in
            headerContinuation = c
            task.resume()
        }
    }

    func cancel() { task?.cancel() }

    /// Reads the remaining body as text (error bodies, non-stream answers).
    func drain() async throws -> String {
        var all = Data()
        for try await line in lines { all.append(line) }
        return String(decoding: all, as: UTF8.self)
    }

    fileprivate func didReceive(response: URLResponse) {
        let http = response as? HTTPURLResponse
        let ct = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        headerContinuation?.resume(returning: (http?.statusCode ?? 0, ct))
        headerContinuation = nil
    }

    fileprivate func didReceive(data: Data) {
        buffer.append(data)
        var start = buffer.startIndex
        while let nl = buffer[start...].firstIndex(of: 0x0A) {
            var end = nl
            if end > start, buffer[end - 1] == 0x0D { end -= 1 }
            lineContinuation.yield(Data(buffer[start..<end]))
            start = nl + 1
        }
        buffer.removeSubrange(buffer.startIndex..<start)
    }

    fileprivate func didComplete(error: Error?) {
        if let error {
            let err = InferenceError.transport(error.localizedDescription)
            headerContinuation?.resume(throwing: err)
            headerContinuation = nil
            lineContinuation.finish(throwing: err)
        } else {
            if !buffer.isEmpty { lineContinuation.yield(buffer) }
            lineContinuation.finish()
        }
    }
}

final class LineSessionRouter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = LineSessionRouter()

    private(set) lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private let lock = NSLock()
    private var sinks: [Int: HTTPLineStream] = [:]

    func register(_ sink: HTTPLineStream, for task: URLSessionTask) {
        lock.lock(); defer { lock.unlock() }
        sinks[task.taskIdentifier] = sink
    }

    private func sink(_ task: URLSessionTask, remove: Bool = false) -> HTTPLineStream? {
        lock.lock(); defer { lock.unlock() }
        return remove ? sinks.removeValue(forKey: task.taskIdentifier) : sinks[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        sink(dataTask)?.didReceive(response: response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        sink(dataTask)?.didReceive(data: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        sink(task, remove: true)?.didComplete(error: error)
    }
}
