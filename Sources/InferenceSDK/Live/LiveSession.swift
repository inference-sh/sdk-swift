// Mirrors js/sdk-js/src/live/session.ts: one end of a stream task's socket,
// as the caller holds it.
//
// The task's run response carries where to dial and a short-lived credential
// (SocketAccess). The relay pairs this connection with the worker's. Until the
// app's first frame arrives nobody may be on the other end yet (the worker can
// still be pulling an image), so the session is `waiting`, not `live`.
//
// Frames follow the function's schemas (see LiveSchema.swift): a binary frame
// is one item of the binary live field, a text frame is a JSON object keyed by
// field name.
//
// Divergences from JS:
// - What arrives is one `events` AsyncStream of LiveEvent instead of a set of
//   optional handlers. Control frames therefore always have a consumer:
//   `$clear` and `$error` come out as `.clear` and `.error`, never inside a
//   patch.
// - `LiveState.ended` carries the LiveEnd; there is no separate argument.
// - `onUpdate` is `updates(for:)`, which maps an event to output fields.
// - The credential goes in an `Authorization: Bearer` header, as the relay
//   asks of everything that is not a browser, so it stays out of the URL.
// - `close()` ends the session at once, like sdk-py; JS waits for the
//   runtime's close event.
// - Only a TaskRunError from the task watch ends a waiting session. JS ends
//   it on any error, including the watch's own connection failing.
// - `sendText` sends a text frame that is not a patch. JS can receive one
//   (`onText`) and cannot send one.

@preconcurrency import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum LiveState: Sendable, Equatable {
    /// Dialing the relay.
    case connecting
    /// The relay accepted the connection; the app has not sent a frame yet.
    case waiting
    /// The app's first frame arrived.
    case live
    case ended(LiveEnd)
}

public struct LiveEnd: Sendable, Equatable {
    /// The WebSocket close code, or 1006 when the session ended without one.
    public var code: Int
    public var reason: String
    /// The caller asked for it.
    public var byCaller: Bool
    /// The task ended before the app connected, so the session gave up waiting.
    public var taskEnded: Bool

    public init(code: Int, reason: String, byCaller: Bool, taskEnded: Bool) {
        self.code = code
        self.reason = reason
        self.byCaller = byCaller
        self.taskEnded = taskEnded
    }
}

/// One thing the session reports, in order.
public enum LiveEvent: Sendable, Equatable {
    case state(LiveState)
    /// An item of the output's binary live field.
    case binary(Data)
    /// A partial output object keyed by field name.
    case patch([String: JSONValue])
    /// Drop what you have buffered of this live output field: the app sends it
    /// when an answer is cut short, e.g. the user talked over it.
    case clear(field: String)
    /// The app refused a frame, or has something to report, and goes on:
    /// `{"$error": {field, message}}`. Apps on older SDKs (inferencesh before
    /// 0.10.1, @inferencesh/app before 0.1.16) send it as `{"error": ...}`,
    /// which counts too unless the output has an `error` field.
    case error(field: String?, message: String)
    /// A text frame that is not a JSON object: text the app sent as text.
    case text(String)
}

/// An item of a live field (`binary` for the binary one) or a new value of an
/// ordinary field.
public enum LiveValue: Sendable, Equatable {
    case binary(Data)
    case json(JSONValue)
}

/// One thing the app sent, mapped to its output field.
public struct LiveUpdate: Sendable, Equatable {
    public var field: String
    public var value: LiveValue

    public init(field: String, value: LiveValue) {
        self.field = field
        self.value = value
    }
}

/// Why `sendField` could not route a value.
public enum LiveSessionError: Error, LocalizedError, Sendable, Equatable {
    case inputSchemaRequired
    /// Bytes for a field that is not the input's binary live field.
    case notBinary(field: String)
    /// JSON for the input's binary live field.
    case binaryOnly(field: String)

    public var errorDescription: String? {
        switch self {
        case .inputSchemaRequired: return "sendField needs the function's inputSchema"
        case .notBinary(let field): return "\(field) is not the input's binary live field"
        case .binaryOnly(let field): return "\(field) takes binary frames"
        }
    }
}

public final class LiveSession: @unchecked Sendable {
    /// Issues a fresh credential (POST /sockets/{id}/access) for a redial.
    public typealias Renew = @Sendable () async throws -> SocketAccess
    /// Follows the task the socket belongs to (`client.tasks.watch`): returns
    /// when it completed and throws a `TaskRunError` when it failed or was
    /// cancelled. Any other error means the watch broke, not the task, and is
    /// ignored.
    public typealias TaskWatch = @Sendable () async throws -> Void

    static let maxRedials = 5

    /// Everything the session reports, from `.state(.connecting)` to
    /// `.state(.ended)`, after which the stream ends. Events are kept until
    /// read; one consumer.
    public let events: AsyncStream<LiveEvent>
    private let sink: AsyncStream<LiveEvent>.Continuation

    private let renew: Renew?
    private let taskWatch: TaskWatch?
    private let dial: LiveDialer
    private let outputBinary: String?
    private let outputFields: Set<String>
    private let inputKnown: Bool
    private let inputBinary: String?

    private let lock = NSLock()
    private var access: SocketAccess
    private var current: LiveState = .connecting
    private var socket: (any LiveSocket)?
    private var socketOpen = false
    private var closedByCaller = false
    private var redials = 0
    private var watcher: Task<Void, Never>?
    private var endWaiters: [CheckedContinuation<LiveEnd, Never>] = []

    /// - Parameters:
    ///   - access: Where to dial and the credential (the run response's `socket`).
    ///   - renew: Issues a fresh credential for a redial.
    ///   - task: Ends the session when the task ends before the app connected.
    ///     Without it a task that fails before its worker dials leaves the
    ///     caller waiting on the relay until the pair timeout.
    ///   - dial: The transport; defaults to `LiveTransport.platformDefault`.
    ///   - inputSchema: The function's input schema: `sendField` routes by it.
    ///   - outputSchema: The function's output schema: `updates(for:)` maps
    ///     binary frames by it.
    public init(access: SocketAccess, renew: Renew? = nil, task: TaskWatch? = nil, dial: LiveDialer? = nil,
                inputSchema: JSONValue? = nil, outputSchema: JSONValue? = nil) {
        (events, sink) = AsyncStream.makeStream(of: LiveEvent.self)
        self.access = access
        self.renew = renew
        self.taskWatch = task
        self.dial = dial ?? LiveTransport.platformDefault
        outputBinary = binaryLiveField(splitLiveSchema(outputSchema).live)?.key
        outputFields = Set((outputSchema?["properties"]?.objectValue ?? [:]).keys)
        inputKnown = inputSchema?.objectValue != nil
        inputBinary = binaryLiveField(splitLiveSchema(inputSchema).live)?.key
    }

    /// Releasing the session closes its socket: keep it for as long as the
    /// stream should run.
    deinit {
        socket?.close(code: 1000, reason: "done")
        watcher?.cancel()
        sink.finish()
    }

    public var state: LiveState {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// The relay has accepted the connection, so frames can be sent.
    public var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return socketOpen
    }

    /// How the session ended; waits until it has, however it ends.
    public var ended: LiveEnd {
        get async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if case .ended(let end) = current {
                    lock.unlock()
                    continuation.resume(returning: end)
                } else {
                    endWaiters.append(continuation)
                    lock.unlock()
                }
            }
        }
    }

    /// The request a LiveDialer gets: the relay URL with the credential as a
    /// bearer token. Nil when the access carries no usable URL.
    static func request(for access: SocketAccess) -> URLRequest? {
        guard let url = URL(string: access.url), url.scheme != nil else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(access.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Dials the relay. The session reports its progress through `events`.
    /// Does nothing while a socket is up, or once the session has ended.
    public func connect() {
        lock.lock()
        if case .ended = current { lock.unlock(); return }
        if socket != nil { lock.unlock(); return }
        setState(.connecting)
        let access = self.access
        lock.unlock()
        watchTask()

        guard let request = Self.request(for: access) else {
            finish(LiveEnd(code: 1006, reason: "the socket has no valid url: \(access.url)", byCaller: false, taskEnded: false))
            return
        }
        let socket = dial(request)
        lock.lock()
        if case .ended = current {
            // Closed, or the task ended, while dialing.
            lock.unlock()
            socket.close(code: 1000, reason: "done")
            return
        }
        self.socket = socket
        socketOpen = false
        lock.unlock()

        Task { [weak self] in
            for await event in socket.events {
                guard let self else { return }
                self.handle(event, from: socket)
            }
        }
    }

    // MARK: - Receiving

    private func handle(_ event: LiveSocketEvent, from socket: any LiveSocket) {
        lock.lock()
        // A socket the session let go of (closed, or the task ended) must not
        // end it a second time.
        guard self.socket === socket else { lock.unlock(); return }
        switch event {
        case .opened:
            socketOpen = true
            setState(.waiting)
            lock.unlock()

        case .frame(let frame):
            if current != .live {
                setState(.live)
                watcher?.cancel()  // the app is there; the task's fate now shows on the socket
            }
            switch frame {
            case .binary(let data): sink.yield(.binary(data))
            case .text(let text): deliverText(text)
            }
            lock.unlock()

        case .closed(let code, let reason):
            self.socket = nil
            socketOpen = false
            let waiting = current != .live
            if !closedByCaller, waiting, LiveProtocol.redialCodes.contains(code), redials < Self.maxRedials {
                redials += 1
                lock.unlock()
                Task { await self.redial() }
                return
            }
            end(LiveEnd(code: code, reason: reason, byCaller: closedByCaller, taskEnded: false))
            lock.unlock()
        }
    }

    /// Called with the lock held.
    private func deliverText(_ text: String) {
        guard var record = (try? InferenceClient.decoder.decode(JSONValue.self, from: Data(text.utf8)))?.objectValue else {
            sink.yield(.text(text))  // text the app sent as text
            return
        }
        let arrivedEmpty = record.isEmpty
        if let field = record[LiveProtocol.clearKey]?.stringValue {
            record[LiveProtocol.clearKey] = nil
            sink.yield(.clear(field: field))
        }
        let errorKey = record[LiveProtocol.errorKey] != nil ? LiveProtocol.errorKey : isLegacyError(record) ? "error" : nil
        if let errorKey, let error = record.removeValue(forKey: errorKey) {
            let message = error.objectValue != nil ? error["message"]?.stringValue : error.stringValue
            sink.yield(.error(field: error["field"]?.stringValue, message: message ?? Self.json(error)))
        }
        if !arrivedEmpty, record.isEmpty { return }  // it was only control frames
        sink.yield(.patch(record))
    }

    /// `{"error": {"message": ...}}` from an app on an older SDK, unless the output has an `error` field.
    private func isLegacyError(_ record: [String: JSONValue]) -> Bool {
        record["error"]?["message"] != nil && !outputFields.contains("error")
    }

    /// The event as output fields: a binary frame is an item of the output's
    /// binary live field (needs `outputSchema`), a patch is one update per key,
    /// sorted by key. Other events map to nothing.
    public func updates(for event: LiveEvent) -> [LiveUpdate] {
        switch event {
        case .binary(let data):
            return outputBinary.map { [LiveUpdate(field: $0, value: .binary(data))] } ?? []
        case .patch(let patch):
            return patch.sorted { $0.key < $1.key }.map { LiveUpdate(field: $0.key, value: .json($0.value)) }
        default:
            return []
        }
    }

    // MARK: - Task watch, redial, ending

    private func watchTask() {
        guard let taskWatch else { return }
        lock.lock()
        defer { lock.unlock() }
        guard watcher == nil else { return }
        watcher = Task { [weak self] in
            let reason: String
            do {
                try await taskWatch()
                reason = "the task ended before the app connected"
            } catch let error as TaskRunError {
                reason = error.localizedDescription
            } catch {
                return  // cancelled, or the watch itself broke: the relay's pair timeout is the backstop
            }
            if Task.isCancelled { return }
            self?.taskEnded(reason)
        }
    }

    private func taskEnded(_ reason: String) {
        lock.lock()
        if current == .live { lock.unlock(); return }
        if case .ended = current { lock.unlock(); return }
        let socket = self.socket
        self.socket = nil
        socketOpen = false
        end(LiveEnd(code: 1000, reason: reason, byCaller: false, taskEnded: true))
        lock.unlock()
        socket?.close(code: 1000, reason: "task ended")
    }

    private func redial() async {
        do {
            if let renew { setAccess(try await renew()) }
            connect()  // not when it ended meanwhile
        } catch {
            finish(LiveEnd(code: 1006, reason: error.localizedDescription, byCaller: false, taskEnded: false))
        }
    }

    private func setAccess(_ access: SocketAccess) {
        lock.lock(); defer { lock.unlock() }
        self.access = access
    }

    private func finish(_ end: LiveEnd) {
        lock.lock(); defer { lock.unlock() }
        self.end(end)
    }

    /// Called with the lock held.
    private func setState(_ state: LiveState) {
        current = state
        sink.yield(.state(state))
    }

    /// Called with the lock held.
    private func end(_ end: LiveEnd) {
        if case .ended = current { return }
        watcher?.cancel()
        setState(.ended(end))
        sink.finish()
        endWaiters.forEach { $0.resume(returning: end) }
        endWaiters = []
    }

    // MARK: - Sending

    /// One item of the input's binary live field. False when the socket is
    /// not open: the frame was dropped.
    @discardableResult
    public func sendBinary(_ data: Data) -> Bool {
        send(.binary(data))
    }

    /// A partial input object keyed by field name: an item of a JSON live
    /// field, or a new value of an ordinary one.
    @discardableResult
    public func sendPatch(_ patch: [String: JSONValue]) -> Bool {
        send(.text(Self.json(.object(patch))))
    }

    /// One item of an input live field, or a new value of an ordinary one: a
    /// binary frame for the binary live field, a JSON frame otherwise. Needs
    /// `inputSchema`.
    @discardableResult
    public func sendField(_ field: String, _ value: LiveValue) throws -> Bool {
        guard inputKnown else { throw LiveSessionError.inputSchemaRequired }
        switch value {
        case .binary(let data):
            guard field == inputBinary else { throw LiveSessionError.notBinary(field: field) }
            return sendBinary(data)
        case .json(let json):
            guard field != inputBinary else { throw LiveSessionError.binaryOnly(field: field) }
            return sendPatch([field: json])
        }
    }

    /// A text frame that is not a patch, for an app that reads its socket raw.
    @discardableResult
    public func sendText(_ text: String) -> Bool {
        send(.text(text))
    }

    private func send(_ frame: LiveFrame) -> Bool {
        lock.lock()
        let socket = socketOpen ? self.socket : nil
        lock.unlock()
        socket?.send(frame)
        return socket != nil
    }

    /// Ends the stream; the function returns and the task completes. Frames
    /// already sent go out first.
    public func close() {
        lock.lock()
        closedByCaller = true
        let socket = self.socket
        self.socket = nil
        socketOpen = false
        end(LiveEnd(code: 1000, reason: "done", byCaller: true, taskEnded: false))
        lock.unlock()
        socket?.close(code: 1000, reason: "done")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static func json(_ value: JSONValue) -> String {
        (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
}
