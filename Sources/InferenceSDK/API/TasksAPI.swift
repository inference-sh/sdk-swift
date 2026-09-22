// Mirrors js/sdk-js/src/api/tasks.ts. Access as `client.tasks`.
//
// Divergences from JS, beyond the Response<T> unwrap shared by every API
// struct here (see ChatsAPI.swift):
// - `run` takes the input inside ApiAppRunRequest instead of the JS
//   (params, processedInput) pair — that split exists for the JS SDK's file
//   preprocessing, which this SDK does explicitly via `uploadFile`.
// - `stripTask` is not ported: in JS it spreads the task and re-assigns the
//   same fields, a no-op, and TaskDTO is a value type anyway.
// - The JS `stream(taskId)` EventSource factory is not ported; `run` consumes
//   GET /tasks/{id}/stream as NDJSON directly (HTTPLineStream), the same
//   transport streamable.ts uses.
// - Unparseable stream lines are skipped (codebase convention, see
//   parseStreamLine); JS lets JSON.parse kill the stream.
// - A stream that ends before a terminal status throws; the JS promise never
//   settles in that case.
// - In polling mode maxReconnects is honored as documented ("maximum retry
//   attempts"); the JS pollUntilTerminal rejects on the first poll error,
//   which makes its maxRetries dead code.
//
// The existing `InferenceClient.runApp` (POST /run with wait: true) predates
// this file and stays.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Options for `TasksAPI.run` (js: RunOptions).
public struct TaskRunOptions: Sendable {
    /// Callback for real-time status updates.
    public var onUpdate: (@Sendable (TaskDTO) -> Void)?
    /// Callback for partial updates with the list of changed fields.
    public var onPartialUpdate: (@Sendable (TaskDTO, [String]) -> Void)?
    /// Wait for task completion (default true).
    public var wait: Bool
    /// Maximum retry attempts when using polling mode (stream: false).
    public var maxReconnects: Int
    /// NDJSON streaming (true) or status polling (false).
    public var stream: Bool
    /// Polling interval in ms when stream is false.
    public var pollIntervalMs: Int
    /// Callback for streaming delta events (token-by-token updates).
    public var onDelta: (@Sendable ([String: JSONValue], Int) -> Void)?

    public init(
        onUpdate: (@Sendable (TaskDTO) -> Void)? = nil,
        onPartialUpdate: (@Sendable (TaskDTO, [String]) -> Void)? = nil,
        wait: Bool = true,
        maxReconnects: Int = 5,
        stream: Bool = true,
        pollIntervalMs: Int = 2000,
        onDelta: (@Sendable ([String: JSONValue], Int) -> Void)? = nil
    ) {
        self.onUpdate = onUpdate
        self.onPartialUpdate = onPartialUpdate
        self.wait = wait
        self.maxReconnects = maxReconnects
        self.stream = stream
        self.pollIntervalMs = pollIntervalMs
        self.onDelta = onDelta
    }
}

/// `run` failure states, mirroring the JS `new Error(...)` rejections.
public enum TaskRunError: Error, LocalizedError, Sendable {
    case failed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        case .cancelled: return "task cancelled"
        }
    }
}

public struct TasksAPI: Sendable {
    let client: InferenceClient
    init(_ client: InferenceClient) { self.client = client }

    /// POST /tasks/list: cursor-paginated tasks.
    public func list(_ params: CursorListRequest? = nil) async throws -> CursorListResponse<TaskDTO> {
        try await client.cursorList("tasks/list", params)
    }

    /// GET /tasks/featured with the list request as query parameters.
    public func listFeatured(_ params: CursorListRequest? = nil) async throws -> CursorListResponse<TaskDTO> {
        let req = client.request("tasks/featured", method: "GET",
                                 query: params.map(Self.queryItems) ?? [])
        return try await client.decode(client.send(req))
    }

    /// GET /tasks/{id}.
    public func get(_ taskId: String) async throws -> TaskDTO {
        try await client.decode(client.send(client.request("tasks/\(taskId)", method: "GET")))
    }

    /// POST /apps/run: create and run a task.
    public func create(_ data: ApiAppRunRequest) async throws -> TaskDTO {
        try await client.decode(client.send(client.request("apps/run", body: data)))
    }

    /// DELETE /tasks/{id}.
    public func delete(_ taskId: String) async throws {
        _ = try await client.send(client.request("tasks/\(taskId)", method: "DELETE"))
    }

    /// POST /tasks/{id}/cancel.
    public func cancel(_ taskId: String) async throws {
        _ = try await client.send(client.request("tasks/\(taskId)/cancel"))
    }

    /// POST /tasks/{id}/visibility.
    public func updateVisibility(_ taskId: String, visibility: String) async throws -> TaskDTO {
        try await client.decode(client.send(client.request("tasks/\(taskId)/visibility", body: VisibilityBody(visibility: visibility))))
    }

    /// POST /tasks/{id}/featured.
    public func feature(_ taskId: String, featured: Bool) async throws -> TaskDTO {
        try await client.decode(client.send(client.request("tasks/\(taskId)/featured", body: FeaturedBody(isFeatured: featured))))
    }

    /// GET /tasks/{id}/logs.
    public func getLogs(_ taskId: String) async throws -> TaskLogsDTO {
        try await client.decode(client.send(client.request("tasks/\(taskId)/logs", method: "GET")))
    }

    /// GET /tasks/{id}/timings.
    public func getTimings(_ taskId: String) async throws -> TaskTimingsDTO {
        try await client.decode(client.send(client.request("tasks/\(taskId)/timings", method: "GET")))
    }

    /// GET /tasks/{id}/telemetry.
    public func getTelemetry(_ taskId: String) async throws -> [[String: JSONValue]] {
        try await client.decode(client.send(client.request("tasks/\(taskId)/telemetry", method: "GET")))
    }

    /// POST /apps/run, then wait for the task to reach a terminal status:
    /// completed returns the task, failed throws `TaskRunError.failed` with the
    /// task's error, cancelled throws `TaskRunError.cancelled`. `wait: false`
    /// returns the created task immediately. `stream: true` (default) follows
    /// GET /tasks/{id}/stream as NDJSON; `stream: false` polls
    /// GET /tasks/{id}/status and fetches the full task on each change.
    public func run(_ params: ApiAppRunRequest, options: TaskRunOptions = TaskRunOptions()) async throws -> TaskDTO {
        let task = try await create(params)
        if !options.wait { return task }
        if !options.stream { return try await pollUntilTerminal(task, options: options) }
        return try await streamUntilTerminal(task, options: options)
    }

    // MARK: - run internals

    /// Follows GET /tasks/{id}/stream (NDJSON). Line shapes, per streamable.ts:
    /// bare task objects, `{"data": {...}}` wrapped tasks, `{"data": {...},
    /// "fields": [...]}` partial updates, `{"event": "delta", "data":
    /// {"delta": {...}, "seq": n}}` deltas, `{"type": "heartbeat"}`.
    ///
    /// Updates accumulate in a `[String: JSONValue]` and re-decode to TaskDTO —
    /// the Swift equivalent of the JS `{...accumulated, ...data}` spread:
    /// every line overwrites its top-level keys and everything else is kept,
    /// so fields like session_id survive partial updates. (Per-field structs
    /// can't spread; the dictionary round-trip is the faithful shape.)
    private func streamUntilTerminal(_ task: TaskDTO, options: TaskRunOptions) async throws -> TaskDTO {
        var accumulated = try Self.jsonObject(task)

        let stream = HTTPLineStream()
        defer { stream.cancel() }
        let (status, _) = try await stream.start(
            client.request("tasks/\(task.id)/stream", method: "GET", accept: "application/x-ndjson"))
        guard (200..<300).contains(status) else {
            throw InferenceError.http(status: status, body: try await stream.drain())
        }

        for try await line in stream.lines {
            guard line.first == UInt8(ascii: "{"),
                  let obj = try? InferenceClient.decoder.decode([String: JSONValue].self, from: line)
            else { continue }

            if obj["type"]?.stringValue == "heartbeat" { continue }

            // Delta events: the streamable.ts wrapper form, plus bare
            // {"delta": ..., "seq": n} lines.
            let deltaPayload = obj["event"]?.stringValue == "delta" ? obj["data"]
                : (obj["data"] == nil && obj["delta"] != nil && obj["seq"] != nil ? .object(obj) : nil)
            if let deltaPayload {
                if let delta = deltaPayload["delta"]?.objectValue {
                    options.onDelta?(delta, deltaPayload["seq"]?.doubleValue.map(Int.init) ?? 0)
                }
                continue
            }

            // {data, fields} partial, {data} wrapped, or bare task object.
            let fields = obj["fields"]?.arrayValue.map { $0.compactMap(\.stringValue) }
            let data: [String: JSONValue]
            if let wrapped = obj["data"]?.objectValue { data = wrapped }
            else if obj["data"] != nil { continue } // non-object payload: nothing to merge
            else { data = obj }

            accumulated.merge(data) { _, new in new }

            // Terminal status is read off the incoming line (js: data.status),
            // so partial lines that don't touch `status` never terminate.
            // Materializing the DTO costs a full encode/decode round-trip;
            // do it only when someone will see it (a callback, or completion).
            let status = Self.parseStatus(data["status"])
            if let error = Self.terminalError(status, data["error"]?.stringValue) { throw error }
            let wantsTask = options.onUpdate != nil || options.onPartialUpdate != nil
            if wantsTask || status == .completed {
                let current = try Self.task(from: accumulated)
                if let fields, obj["data"] != nil { options.onPartialUpdate?(current, fields) }
                else { options.onUpdate?(current) }
                if status == .completed { return current }
            }
        }
        throw InferenceError.transport("task stream ended before a terminal status")
    }

    /// Polls GET /tasks/{id}/status; on every status change fetches the full
    /// task, reports it, and stops when it is terminal (js: pollUntilTerminal).
    private func pollUntilTerminal(_ task: TaskDTO, options: TaskRunOptions) async throws -> TaskDTO {
        var prevStatus = task.status
        let taskId = task.id
        return try await pollUntil(
            interval: .milliseconds(options.pollIntervalMs),
            maxRetries: options.maxReconnects,
            poll: { () async throws -> ResourceStatusDTO in
                try await client.decode(client.send(client.request("tasks/\(taskId)/status", method: "GET")))
            },
            onData: { statusData in
                let status = Self.parseStatus(statusData.status)
                guard status != prevStatus else { return nil }
                prevStatus = status

                let full = try await self.get(taskId)
                options.onUpdate?(full)
                if let error = Self.terminalError(full.status, full.error) { throw error }
                return full.status == .completed ? full : nil
            })
    }

    /// Port of parseStatus in js/sdk-js/src/utils.ts: numbers pass through,
    /// strings map by name, anything else is .unknown.
    static func parseStatus(_ value: JSONValue?) -> TaskStatus {
        switch value {
        case .number(let n):
            return TaskStatus(rawValue: Int(n))
        case .string(let s):
            let map: [String: TaskStatus] = [
                "unknown": .unknown, "received": .received, "queued": .queued,
                "dispatched": .dispatched, "preparing": .preparing, "serving": .serving,
                "setting_up": .settingUp, "running": .running, "cancelling": .cancelling,
                "uploading": .uploading, "completed": .completed, "failed": .failed,
                "cancelled": .cancelled,
            ]
            return map[s.lowercased()] ?? .unknown
        default:
            return .unknown
        }
    }

    /// failed/cancelled → the matching TaskRunError; anything else → nil.
    /// Shared by the stream and poll paths so the mapping cannot drift.
    private static func terminalError(_ status: TaskStatus, _ error: String?) -> TaskRunError? {
        switch status {
        case .failed: return .failed(error ?? "task failed")
        case .cancelled: return .cancelled
        default: return nil
        }
    }

    // MARK: - Helpers

    private static func jsonObject(_ task: TaskDTO) throws -> [String: JSONValue] {
        try InferenceClient.decoder.decode([String: JSONValue].self, from: InferenceClient.encoder.encode(task))
    }

    private static func task(from object: [String: JSONValue]) throws -> TaskDTO {
        let data = try InferenceClient.encoder.encode(object)
        return try InferenceClient.decoder.decode(TaskDTO.self, from: data)
    }

    /// The JS client turns `params` into query items: primitives via
    /// String(value), objects and arrays JSON-stringified, null skipped.
    /// CursorListRequest's non-optional fields always encode, so zero values
    /// (cursor=, limit=0, ...) are sent where JS's Partial<> would omit them;
    /// the API treats zero values as defaults.
    private static func queryItems(_ params: CursorListRequest) -> [URLQueryItem] {
        guard let encoded = try? InferenceClient.encoder.encode(params),
              let object = try? InferenceClient.decoder.decode([String: JSONValue].self, from: encoded)
        else { return [] }

        var items: [URLQueryItem] = []
        for (key, value) in object.sorted(by: { $0.key < $1.key }) {
            switch value {
            case .null:
                continue
            case .string(let s):
                items.append(URLQueryItem(name: key, value: s))
            case .bool(let b):
                items.append(URLQueryItem(name: key, value: b ? "true" : "false"))
            case .number(let n):
                let text = n == n.rounded() && n.magnitude < 1e15 ? String(Int(n)) : String(n)
                items.append(URLQueryItem(name: key, value: text))
            case .array, .object:
                if let json = try? InferenceClient.encoder.encode(value) {
                    items.append(URLQueryItem(name: key, value: String(decoding: json, as: UTF8.self)))
                }
            }
        }
        return items
    }
}

// VisibilityBody is shared — see Bodies.swift.

private struct FeaturedBody: Encodable {
    let isFeatured: Bool
    enum CodingKeys: String, CodingKey { case isFeatured = "is_featured" }
}

public extension InferenceClient {
    var tasks: TasksAPI { TasksAPI(self) }
}
