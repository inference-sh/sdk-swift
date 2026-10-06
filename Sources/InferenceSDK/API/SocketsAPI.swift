// Mirrors js/sdk-js/src/api/sockets.ts. Access as `client.sockets`.
//
// The duplex connection of a stream task. A stream function keeps a socket
// open with its caller for the life of the task. The run response carries the
// caller's end (`TaskResultDTO.socket`); `open` dials it and gives back a
// LiveSession.
//
// Divergences from JS, beyond the Response<T> unwrap shared by every API
// struct here (see ChatsAPI.swift):
// - `open` is two overloads (the run response, or a task id) for the JS
//   SocketTarget union, and takes no handlers: the session's `events` stream
//   carries what they would.
// - `client.live` dials the socket the run response carries. JS goes through
//   `run(..., {wait: false})`, which returns the task without it, and so asks
//   for the socket and a credential again.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Options for `SocketsAPI.open` and `InferenceClient.live` (js: OpenSocketOptions).
public struct OpenSocketOptions: Sendable {
    /// Follow the task while waiting for the app, and end the session if the
    /// task ends first (default true). Off, a task that fails before its
    /// worker dials leaves the session waiting until the relay's pair timeout.
    public var watchTask: Bool
    /// The transport; defaults to `LiveTransport.platformDefault` (HTTP on watchOS).
    public var dial: LiveDialer?
    /// The function's input schema: `session.sendField` routes by it.
    public var inputSchema: JSONValue?
    /// The function's output schema: `session.updates(for:)` maps binary frames by it.
    public var outputSchema: JSONValue?

    public init(watchTask: Bool = true, dial: LiveDialer? = nil,
                inputSchema: JSONValue? = nil, outputSchema: JSONValue? = nil) {
        self.watchTask = watchTask
        self.dial = dial
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
    }
}

public struct SocketsAPI: Sendable {
    let client: InferenceClient
    init(_ client: InferenceClient) { self.client = client }

    /// GET /sockets/{id}: the socket and what is known of its life.
    public func get(_ socketId: String) async throws -> SocketDTO {
        try await client.decode(client.send(client.request("sockets/\(socketId)", method: "GET")))
    }

    /// POST /sockets/list: cursor-paginated sockets.
    public func list(_ params: CursorListRequest? = nil) async throws -> CursorListResponse<SocketDTO> {
        try await client.cursorList("sockets/list", params)
    }

    /// The task's socket, or nil when it has none (not a stream function).
    public func forTask(_ taskId: String) async throws -> SocketDTO? {
        let filter = Filter(field: "task_id", operator: .opEqual, value: .string(taskId))
        return try await list(CursorListRequest(limit: 1, filters: [filter])).items?.first
    }

    /// POST /sockets/{id}/access: a fresh credential for the caller's end,
    /// e.g. after a relaunch or to redial.
    public func access(_ socketId: String) async throws -> SocketAccess {
        try await client.decode(client.send(client.request("sockets/\(socketId)/access")))
    }

    /// DELETE /sockets/{id}: delete the record.
    public func delete(_ socketId: String) async throws {
        _ = try await client.send(client.request("sockets/\(socketId)", method: "DELETE"))
    }

    /// Dials the caller's end of the socket a run response carries
    /// (`tasks.create`). The session is `waiting` until the app's first
    /// frame, then `live`; see LiveSession.
    public func open(_ task: TaskResultDTO, options: OpenSocketOptions = OpenSocketOptions()) async throws -> LiveSession {
        try await open(taskId: task.id, access: task.socket, options: options)
    }

    /// Dials the socket of a running task, e.g. after the app relaunched:
    /// looks the socket up and issues a credential for it.
    public func open(_ taskId: String, options: OpenSocketOptions = OpenSocketOptions()) async throws -> LiveSession {
        try await open(taskId: taskId, access: nil, options: options)
    }

    private func open(taskId: String, access: SocketAccess?, options: OpenSocketOptions) async throws -> LiveSession {
        let access = if let access { access } else { try await credential(for: taskId) }
        let socketId = access.id
        let tasks = client.tasks
        let watch: LiveSession.TaskWatch = { _ = try await tasks.watch(taskId) }
        let session = LiveSession(
            access: access,
            renew: { try await self.access(socketId) },
            task: options.watchTask ? watch : nil,
            dial: options.dial,
            inputSchema: options.inputSchema,
            outputSchema: options.outputSchema
        )
        session.connect()
        return session
    }

    private func credential(for taskId: String) async throws -> SocketAccess {
        guard let socket = try await forTask(taskId) else {
            throw InferenceError.transport("task \(taskId) has no socket: is it a stream function?")
        }
        return try await access(socket.id)
    }
}

// MARK: - Namespace (js: client.sockets, client.live)

public extension InferenceClient {
    var sockets: SocketsAPI { SocketsAPI(self) }

    /// Starts a stream function and opens its socket. The task runs until the
    /// session is closed (or the app returns); `session.ended` settles then,
    /// and `tasks.watch(task.id)` gives the task's result.
    ///
    ///     let (task, session) = try await client.live(ApiAppRunRequest(
    ///         app: "infsh/voice-loop", function: "stream", input: ["effect": "robot"]))
    ///     for await event in session.events {
    ///         if case .binary(let pcm) = event { speaker.play(pcm) }
    ///     }
    func live(_ params: ApiAppRunRequest, options: OpenSocketOptions = OpenSocketOptions()) async throws
        -> (task: TaskResultDTO, session: LiveSession) {
        let task = try await tasks.create(params)
        return (task, try await sockets.open(task, options: options))
    }
}
