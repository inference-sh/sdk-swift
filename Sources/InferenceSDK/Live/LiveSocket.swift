// The WebSocket under a LiveSession (js: WebSocketLike / WebSocketConstructor
// in src/live/session.ts). The session needs frames out, and frames in with
// how the connection opened and ended, so that is the whole protocol. The
// default is URLSessionWebSocketTask; pass a LiveDialer to use another
// WebSocket, or a fake one in tests.
//
// Linux: URLSessionWebSocketTask needs a libcurl built with WebSockets, which
// the one in the swift:5.10 jammy and noble images is not: the dial fails and
// the session ends with 1006. With one, Foundation there still reports the
// close codes it has no name for (1012, 1013) as 1003, so a waiting session
// does not redial, and it can drop a frame that arrives together with the
// close. A server that needs those passes its own LiveDialer.

@preconcurrency import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One frame on the socket.
public enum LiveFrame: Sendable, Equatable {
    case binary(Data)
    case text(String)
}

/// What a socket tells its session, in order.
public enum LiveSocketEvent: Sendable, Equatable {
    /// The relay accepted the connection.
    case opened
    case frame(LiveFrame)
    /// The connection is over; nothing follows. `code` is the close frame's,
    /// or 1006 when there was none (the dial failed, the network dropped).
    case closed(code: Int, reason: String)
}

public protocol LiveSocket: AnyObject, Sendable {
    /// Ends after `.closed`.
    var events: AsyncStream<LiveSocketEvent> { get }
    /// Queues one frame. Frames go out in the order they were sent; a frame
    /// that cannot be sent shows as the socket closing.
    func send(_ frame: LiveFrame)
    /// Sends what is queued, then a close frame. Events may stop here.
    func close(code: Int, reason: String)
}

/// Starts dialing the request (the relay URL with the credential as a bearer
/// header) and returns the socket at once; `.opened` or `.closed` follows.
public typealias LiveDialer = @Sendable (URLRequest) -> any LiveSocket

/// LiveSocket over URLSessionWebSocketTask.
final class URLSessionLiveSocket: LiveSocket, @unchecked Sendable {
    /// How long the relay gets to accept the connection.
    static let openTimeout: Duration = .seconds(30)
    /// The relay pings every 25s and drops an end that stops answering. The
    /// same from this side keeps URLSession's idle timer from closing a quiet
    /// socket and notices a connection that died without a close.
    static let pingInterval: Duration = .seconds(25)
    /// How long queued frames get to leave once the caller closes.
    static let flushTimeout: Duration = .seconds(5)

    let events: AsyncStream<LiveSocketEvent>
    private let sink: AsyncStream<LiveSocketEvent>.Continuation
    private let outbound: AsyncStream<LiveFrame>.Continuation
    private let task: URLSessionWebSocketTask

    private let lock = NSLock()
    private var opened = false
    private var finished = false
    private var closing: (code: URLSessionWebSocketTask.CloseCode, reason: Data)?
    /// The close frame as the delegate reported it.
    private var closeFrame: (code: Int, reason: String)?
    private var awaitingPong = false
    private var timers: [Task<Void, Never>] = []

    init(_ request: URLRequest, router: WebSocketRouter = .shared) {
        (events, sink) = AsyncStream.makeStream(of: LiveSocketEvent.self)
        let (frames, outbound) = AsyncStream.makeStream(of: LiveFrame.self)
        self.outbound = outbound
        var request = request
        // The handshake is bounded by openTimeout and a dead connection by the
        // pings; URLSession's own timer would close a socket that is only quiet.
        request.timeoutInterval = 24 * 60 * 60
        task = router.session.webSocketTask(with: request)
        router.register(self, for: task)
        task.resume()
        Task { await self.receiveLoop() }
        Task { await self.sendLoop(frames) }
        let timers = [Task { await self.openDeadline() }, Task { await self.keepAlive() }]
        lock.lock()
        self.timers = timers
        let over = finished
        lock.unlock()
        if over { timers.forEach { $0.cancel() } }
    }

    func send(_ frame: LiveFrame) {
        outbound.yield(frame)
    }

    func close(code: Int, reason: String) {
        lock.lock()
        let already = closing != nil || finished
        if !already {
            closing = (URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, Data(reason.utf8))
        }
        lock.unlock()
        guard !already else { return }
        outbound.finish()  // the send loop flushes what is queued, then closes
        Task {
            // A send stuck on a dead connection must not keep the socket open.
            try? await Task.sleep(for: Self.flushTimeout)
            self.sendClose()
        }
    }

    // MARK: - Loops

    private func receiveLoop() async {
        while true {
            do {
                let message = try await task.receive()
                if case .data(let data) = message { sink.yield(.frame(.binary(data))) }
                else if case .string(let text) = message { sink.yield(.frame(.text(text))) }
            } catch {
                // Every frame before the close has been delivered by now. The
                // delegate reports the close frame; give it a moment to.
                try? await Task.sleep(for: .milliseconds(250))
                finish(error: error)
                return
            }
        }
    }

    private func sendLoop(_ frames: AsyncStream<LiveFrame>) async {
        for await frame in frames {
            do {
                switch frame {
                case .binary(let data): try await task.send(.data(data))
                case .text(let text): try await task.send(.string(text))
                }
            } catch {
                break  // the receive loop reports what happened to the connection
            }
        }
        sendClose()
    }

    private func sendClose() {
        lock.lock()
        let closing = self.closing
        lock.unlock()
        if let closing { task.cancel(with: closing.code, reason: closing.reason) }
    }

    private func openDeadline() async {
        try? await Task.sleep(for: Self.openTimeout)
        guard !Task.isCancelled, isLate() else { return }
        task.cancel()
        finish(reason: "timed out connecting to the relay")
    }

    private func keepAlive() async {
        while true {
            try? await Task.sleep(for: Self.pingInterval)
            if Task.isCancelled { return }
            switch nextPing() {
            case .stop:
                return
            case .notOpen:
                continue
            case .unanswered:
                task.cancel()
                finish(reason: "the relay stopped answering")
                return
            case .send:
                task.sendPing { [weak self] error in
                    if error == nil { self?.pongArrived() }
                }
            }
        }
    }

    // NSLock is not for async functions; the loops above take it through these.

    private func isLate() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !opened && !finished
    }

    private enum Ping { case stop, notOpen, unanswered, send }

    private func nextPing() -> Ping {
        lock.lock(); defer { lock.unlock() }
        if finished { return .stop }
        guard opened else { return .notOpen }
        if awaitingPong { return .unanswered }
        awaitingPong = true
        return .send
    }

    private func pongArrived() {
        lock.lock(); defer { lock.unlock() }
        awaitingPong = false
    }

    /// Reports the close, once: the close frame when there was one, else 1006
    /// with the best account of why.
    private func finish(error: Error? = nil, reason: String? = nil) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let frame = closeFrame
        let timers = self.timers
        lock.unlock()

        timers.forEach { $0.cancel() }
        outbound.finish()

        // The task knows the close frame on every platform; the delegate's
        // account is the fallback (on Linux it reports code 0).
        var code = task.closeCode.rawValue > 0 ? task.closeCode.rawValue : frame?.code ?? 0
        var text = task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? frame?.reason ?? ""
        if reason != nil || code <= 0 { code = 1006 }
        if let reason {
            text = reason
        } else if code == 1006, text.isEmpty {
            if let status = (task.response as? HTTPURLResponse)?.statusCode, status != 0, status != 101 {
                text = "the relay refused the connection: HTTP \(status)"
            } else {
                text = error?.localizedDescription ?? ""
            }
        }
        sink.yield(.closed(code: code, reason: text))
        sink.finish()
    }

    // MARK: - Delegate callbacks (via WebSocketRouter)

    fileprivate func didOpen() {
        // Linux reports an open for a handshake the relay refused.
        if let status = (task.response as? HTTPURLResponse)?.statusCode, status != 101 { return }
        lock.lock()
        opened = true
        lock.unlock()
        sink.yield(.opened)
    }

    fileprivate func didClose(code: Int, reason: Data?) {
        // Recorded, not reported: frames that arrived before the close may
        // still be on their way through the receive loop.
        lock.lock()
        closeFrame = (code, reason.map { String(decoding: $0, as: UTF8.self) } ?? "")
        lock.unlock()
    }
}

/// The URLSession every URLSessionLiveSocket runs on; hands each task's
/// delegate callbacks to the socket that owns it (see LineSessionRouter).
final class WebSocketRouter: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    static let shared = WebSocketRouter()

    private(set) lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private let lock = NSLock()
    private var sockets: [Int: URLSessionLiveSocket] = [:]

    func register(_ socket: URLSessionLiveSocket, for task: URLSessionTask) {
        lock.lock(); defer { lock.unlock() }
        sockets[task.taskIdentifier] = socket
    }

    private func socket(_ task: URLSessionTask, remove: Bool = false) -> URLSessionLiveSocket? {
        lock.lock(); defer { lock.unlock() }
        return remove ? sockets.removeValue(forKey: task.taskIdentifier) : sockets[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        socket(webSocketTask)?.didOpen()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        socket(webSocketTask)?.didClose(code: closeCode.rawValue, reason: reason)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // The receive loop fails when the task completes and reports the close.
        _ = socket(task, remove: true)
    }
}
