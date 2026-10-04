// LiveSocket over plain HTTP, for where a WebSocket cannot open: watchOS
// allows URLSessionWebSocketTask only while streaming audio or in a call
// (TN3135), and some networks drop the upgrade. The relay's client end over
// HTTP (relay README, "Client end over HTTP"):
//
//   GET  {socket url}/stream  holds the end; the response streams records:
//                             the worker's frames, keepalives, the close.
//   POST {socket url}/frames  our frames as records, one request at a time.
//
// A record is kind (1 byte), length (4 bytes, big endian), payload. Kinds: 1
// text, 2 binary, 8 close (code, 2 bytes big endian, then the reason), 9
// keepalive. Frames queued while a POST is out go together in the next one.

@preconcurrency import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The transports a LiveSession can dial with (`OpenSocketOptions.dial`).
public enum LiveTransport {
    /// URLSessionWebSocketTask; the default.
    public static let webSocket: LiveDialer = { URLSessionLiveSocket($0) }
    /// Plain HTTP requests; works where WebSockets are blocked (watchOS).
    public static let http: LiveDialer = { HTTPLiveSocket($0) }
}

/// One record of the relay's HTTP framing.
enum RelayRecord: Equatable {
    case text(String)
    case binary(Data)
    case close(code: Int, reason: String)
    case keepalive
    /// A kind this client does not know; skipped.
    case unknown(UInt8)

    static let headerSize = 5

    var encoded: Data {
        let (kind, payload): (UInt8, Data) = switch self {
        case .text(let s): (1, Data(s.utf8))
        case .binary(let d): (2, d)
        case .close(let code, let reason): (8, Data([UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)]) + Data(reason.utf8))
        case .keepalive: (9, Data())
        case .unknown(let k): (k, Data())
        }
        let n = UInt32(payload.count)
        return Data([kind, UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]) + payload
    }

    /// Takes every whole record off the front of `buffer`; a partial one stays.
    static func parse(_ buffer: inout Data) -> [RelayRecord] {
        var records: [RelayRecord] = []
        var at = buffer.startIndex
        while buffer.endIndex - at >= headerSize {
            let kind = buffer[at]
            let n = buffer[(at + 1)..<(at + 5)].reduce(0) { $0 << 8 | Int($1) }
            guard buffer.endIndex - at - headerSize >= n else { break }
            let payload = Data(buffer[(at + headerSize)..<(at + headerSize + n)])
            at += headerSize + n
            switch kind {
            case 1: records.append(.text(String(decoding: payload, as: UTF8.self)))
            case 2: records.append(.binary(payload))
            case 8:
                let code = payload.count >= 2 ? Int(payload[payload.startIndex]) << 8 | Int(payload[payload.startIndex + 1]) : 1000
                let reason = payload.count > 2 ? String(decoding: payload.dropFirst(2), as: UTF8.self) : ""
                records.append(.close(code: code, reason: reason))
            case 9: records.append(.keepalive)
            default: records.append(.unknown(kind))
            }
        }
        buffer = Data(buffer[at...])
        return records
    }
}

final class HTTPLiveSocket: LiveSocket, @unchecked Sendable {
    /// How long the relay gets to answer the stream request.
    static let openTimeout: Duration = .seconds(30)
    /// The relay sends a keepalive every 25s; this long without a record means
    /// the stream died without ending.
    static let silenceLimit: Duration = .seconds(80)
    /// How long queued frames and the close get to leave once the caller closes.
    static let flushTimeout: Duration = .seconds(5)
    static let postTimeout: TimeInterval = 15

    let events: AsyncStream<LiveSocketEvent>
    private let sink: AsyncStream<LiveSocketEvent>.Continuation
    private let wake: AsyncStream<Void>.Continuation
    private let endpoints: (stream: URL, frames: URL)?
    private let authorization: String?
    private let router: RecordSessionRouter
    private var stream: URLSessionDataTask?
    /// Only the router's delegate queue touches it.
    private var buffer = Data()

    private let lock = NSLock()
    private var opened = false
    private var finished = false
    private var closing = false
    /// Encoded records waiting for the next POST.
    private var pending = Data()
    /// The relay's close record, reported once the stream ends.
    private var closeRecord: (code: Int, reason: String)?
    private var lastHeard = ContinuousClock.now
    private var refusedStatus: Int?
    private var timers: [Task<Void, Never>] = []

    init(_ request: URLRequest, router: RecordSessionRouter = .shared) {
        (events, sink) = AsyncStream.makeStream(of: LiveSocketEvent.self)
        let (wakes, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.wake = wake
        self.router = router
        authorization = request.value(forHTTPHeaderField: "Authorization")
        endpoints = request.url.flatMap(Self.endpoints)
        guard let endpoints else {
            finish(reason: "the socket has no valid url: \(request.url?.absoluteString ?? "")")
            return
        }

        var get = URLRequest(url: endpoints.stream)
        get.setValue(authorization, forHTTPHeaderField: "Authorization")
        // Bounded by openTimeout and the silence limit; URLSession's own timer
        // would end a stream that is only quiet.
        get.timeoutInterval = 24 * 60 * 60
        let task = router.session.dataTask(with: get)
        lock.lock()
        stream = task
        lock.unlock()
        router.register(self, for: task)
        task.resume()
        Task { await self.sendLoop(wakes) }
        let timers = [Task { await self.openDeadline() }, Task { await self.watchdog() }]
        lock.lock()
        self.timers = timers
        let over = finished
        lock.unlock()
        if over { timers.forEach { $0.cancel() } }
    }

    /// The stream and frames URLs for a socket URL: wss → https, ws → http,
    /// the path gets /stream and /frames, the query is kept.
    static func endpoints(_ url: URL) -> (stream: URL, frames: URL)? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.host != nil else { return nil }
        switch parts.scheme?.lowercased() {
        case "wss", "https": parts.scheme = "https"
        case "ws", "http": parts.scheme = "http"
        default: return nil
        }
        let base = parts.path.hasSuffix("/") ? String(parts.path.dropLast()) : parts.path
        parts.path = base + "/stream"
        guard let stream = parts.url else { return nil }
        parts.path = base + "/frames"
        guard let frames = parts.url else { return nil }
        return (stream, frames)
    }

    func send(_ frame: LiveFrame) {
        let record: RelayRecord = switch frame {
        case .text(let s): .text(s)
        case .binary(let d): .binary(d)
        }
        lock.lock()
        let accepted = !closing && !finished
        if accepted { pending.append(record.encoded) }
        lock.unlock()
        if accepted { wake.yield() }
    }

    func close(code: Int, reason: String) {
        lock.lock()
        let already = closing || finished
        if !already {
            closing = true
            pending.append(RelayRecord.close(code: code, reason: reason).encoded)
        }
        lock.unlock()
        guard !already else { return }
        wake.yield()
        Task {
            // The relay answers our close by ending the stream; a dead
            // connection must not keep the socket open.
            try? await Task.sleep(for: Self.flushTimeout)
            self.cancelStream()
            self.finish(reason: "the relay did not confirm the close")
        }
    }

    // MARK: - Loops

    /// One POST at a time, carrying everything queued since the last one.
    private func sendLoop(_ wakes: AsyncStream<Void>) async {
        guard let frames = endpoints?.frames else { return }
        for await _ in wakes {
            while let body = takePending() {
                var post = URLRequest(url: frames)
                post.httpMethod = "POST"
                post.setValue(authorization, forHTTPHeaderField: "Authorization")
                post.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                post.timeoutInterval = Self.postTimeout
                let status = await Self.upload(post, body)
                switch status {
                case 204:
                    continue
                case 410:
                    return  // the socket ended; the stream brings the close
                default:
                    cancelStream()
                    finish(reason: status.map { "the relay refused frames: HTTP \($0)" } ?? "couldn't reach the relay")
                    return
                }
            }
        }
    }

    private static let posts = URLSession(configuration: .default)

    private static func upload(_ request: URLRequest, _ body: Data) async -> Int? {
        await withCheckedContinuation { continuation in
            posts.uploadTask(with: request, from: body) { _, response, error in
                continuation.resume(returning: error == nil ? (response as? HTTPURLResponse)?.statusCode : nil)
            }.resume()
        }
    }

    private func openDeadline() async {
        try? await Task.sleep(for: Self.openTimeout)
        guard !Task.isCancelled, isLate() else { return }
        cancelStream()
        finish(reason: "timed out connecting to the relay")
    }

    private func watchdog() async {
        while true {
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled { return }
            switch silence() {
            case .over: return
            case .fine: continue
            case .silent:
                cancelStream()
                finish(reason: "the relay stopped answering")
                return
            }
        }
    }

    // NSLock is not for async functions; the loops above take it through these.

    private func takePending() -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard opened, !finished, !pending.isEmpty else { return nil }
        defer { pending = Data() }
        return pending
    }

    private func isLate() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !opened && !finished
    }

    private enum Silence { case over, fine, silent }

    private func silence() -> Silence {
        lock.lock(); defer { lock.unlock() }
        if finished { return .over }
        return opened && ContinuousClock.now - lastHeard > Self.silenceLimit ? .silent : .fine
    }

    private func cancelStream() {
        lock.lock()
        let task = stream
        lock.unlock()
        task?.cancel()
    }

    /// Reports the close, once: the relay's close record when there was one,
    /// else 1006 with the best account of why.
    private func finish(error: Error? = nil, reason: String? = nil) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let record = closeRecord
        let refused = refusedStatus
        let timers = self.timers
        lock.unlock()

        timers.forEach { $0.cancel() }
        wake.finish()

        let code: Int, text: String
        if let record, reason == nil {
            (code, text) = record
        } else if let refused {
            (code, text) = (1006, "the relay refused the connection: HTTP \(refused)")
        } else {
            (code, text) = (1006, reason ?? error?.localizedDescription ?? "the relay ended the stream")
        }
        sink.yield(.closed(code: code, reason: text))
        sink.finish()
    }

    // MARK: - Delegate callbacks (via RecordSessionRouter)

    fileprivate func didReceive(response: URLResponse) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            lock.lock()
            refusedStatus = status
            lock.unlock()
            cancelStream()
            return
        }
        lock.lock()
        let over = finished
        opened = !over
        lastHeard = .now
        lock.unlock()
        guard !over else { return }
        sink.yield(.opened)
        wake.yield()  // frames queued while dialing
    }

    fileprivate func didReceive(data: Data) {
        buffer.append(data)
        let records = RelayRecord.parse(&buffer)
        lock.lock()
        lastHeard = .now
        let over = finished
        for case .close(let code, let reason) in records { closeRecord = (code, reason) }
        lock.unlock()
        guard !over else { return }
        for record in records {
            switch record {
            case .text(let s): sink.yield(.frame(.text(s)))
            case .binary(let d): sink.yield(.frame(.binary(d)))
            case .close, .keepalive, .unknown: break
            }
        }
    }

    fileprivate func didComplete(error: Error?) {
        finish(error: error)
    }
}

/// The URLSession every HTTPLiveSocket streams on; hands each task's delegate
/// callbacks to the socket that owns it (see LineSessionRouter).
final class RecordSessionRouter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = RecordSessionRouter()

    private(set) lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private let lock = NSLock()
    private var sockets: [Int: HTTPLiveSocket] = [:]

    func register(_ socket: HTTPLiveSocket, for task: URLSessionTask) {
        lock.lock(); defer { lock.unlock() }
        sockets[task.taskIdentifier] = socket
    }

    private func socket(_ task: URLSessionTask, remove: Bool = false) -> HTTPLiveSocket? {
        lock.lock(); defer { lock.unlock() }
        return remove ? sockets.removeValue(forKey: task.taskIdentifier) : sockets[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        socket(dataTask)?.didReceive(response: response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        socket(dataTask)?.didReceive(data: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        socket(task, remove: true)?.didComplete(error: error)
    }
}
