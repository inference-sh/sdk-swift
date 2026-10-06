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
//
// The relay treats this end as it treats a WebSocket, and three things a
// WebSocket's connection does are done here:
//
//   - Pongs. Each keepalive on the stream is answered with a POST: the frames
//     that are queued, or one keepalive record. The relay drops an end that
//     posts nothing for three keepalives.
//   - Backpressure. The relay holds 64 frames for a worker that is not there
//     yet or reads slowly. A POST that finds them taken is held for one
//     keepalive interval, then answered 429 with how many records it took;
//     the rest are sent again, in order.
//   - The close. When the relay refuses frames the socket has ended there,
//     and the stream's last record says how; that is what the caller is told.

@preconcurrency import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The transports a LiveSession can dial with (`OpenSocketOptions.dial`).
public enum LiveTransport {
    /// URLSessionWebSocketTask; the default except on watchOS.
    public static let webSocket: LiveDialer = { URLSessionLiveSocket($0) }
    /// Plain HTTP requests; works where WebSockets are blocked (watchOS).
    public static let http: LiveDialer = { HTTPLiveSocket($0) }
    /// What a session dials when none is given: HTTP on watchOS, which allows
    /// URLSessionWebSocketTask only while streaming audio or in a call
    /// (TN3135); the WebSocket everywhere else.
    #if os(watchOS)
    public static let platformDefault: LiveDialer = http
    #else
    public static let platformDefault: LiveDialer = webSocket
    #endif
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
    /// What fits a close frame next to its code (RFC 6455 5.5).
    static let maxCloseReasonBytes = 123

    /// A close the relay can pass to the worker's WebSocket: a code a
    /// WebSocket may send (1000 otherwise, as URLSessionLiveSocket does for a
    /// code it has no name for) and the reason cut to what a close frame
    /// holds. The relay ends the socket as broken on anything else.
    static func close(sending code: Int, reason: String) -> RelayRecord {
        let sendable = (1000...1003).contains(code) || (1007...1013).contains(code) || (3000...4999).contains(code)
        // A character is at least a byte, so the prefix bounds the loop.
        var reason = String(reason.prefix(maxCloseReasonBytes))
        while reason.utf8.count > maxCloseReasonBytes { reason.removeLast() }
        return .close(code: sendable ? code : 1000, reason: reason)
    }

    /// Takes the records of the next POST off the front of `queue`: as many
    /// as fit `maxBytes`, and always one.
    static func batch(from queue: inout [Data], maxBytes: Int) -> [Data] {
        var count = 0, size = 0
        while count < queue.count, count == 0 || size + queue[count].count <= maxBytes {
            size += queue[count].count
            count += 1
        }
        let batch = Array(queue[..<count])
        queue.removeFirst(count)
        return batch
    }

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
    /// How long queued frames and the close get to leave once the caller
    /// closes, and how long the stream gets to bring the close once the relay
    /// refuses frames.
    static let flushTimeout: Duration = .seconds(5)
    /// The relay holds a POST for one keepalive interval (25s) when its
    /// buffer is full; giving up sooner would end a socket that is only
    /// waiting for its worker.
    static let postTimeout: TimeInterval = 40
    /// One POST's worth of records: small enough to leave a slow link soon,
    /// large enough that audio queued behind a slow POST catches up.
    static let maxBatchBytes = 256 * 1024
    static let acceptedHeader = "X-Accepted-Records"

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
    /// The relay refused frames; no more are sent.
    private var sendingOver = false
    /// Encoded records waiting for a POST, oldest first.
    private var pending: [Data] = []
    /// A keepalive from the relay is waiting for its answer.
    private var keepaliveDue = false
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
        let accepted = !closing && !finished && !sendingOver
        if accepted { pending.append(record.encoded) }
        lock.unlock()
        if accepted { wake.yield() }
    }

    func close(code: Int, reason: String) {
        lock.lock()
        let already = closing || finished
        if !already {
            closing = true
            pending.append(RelayRecord.close(sending: code, reason: reason).encoded)
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

    /// One POST at a time, carrying what was queued since the last one.
    private func sendLoop(_ wakes: AsyncStream<Void>) async {
        guard let frames = endpoints?.frames else { return }
        var post = URLRequest(url: frames)
        post.httpMethod = "POST"
        post.setValue(authorization, forHTTPHeaderField: "Authorization")
        post.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        post.timeoutInterval = Self.postTimeout
        for await _ in wakes {
            while var batch = takeBatch() {
                // Until the relay has taken every record of the batch.
                while !batch.isEmpty {
                    guard let answer = await Self.upload(post, Data(batch.joined())) else {
                        cancelStream()
                        finish(reason: "couldn't reach the relay")
                        return
                    }
                    switch (answer.status, answer.accepted) {
                    case (204, _):
                        batch = []
                    case (429, let accepted?) where (0...batch.count).contains(accepted):
                        // The relay's buffer stayed full: it kept the first
                        // records and has already made us wait.
                        batch.removeFirst(accepted)
                        if isOver() { return }
                    default:
                        framesRefused(answer.status)
                        return
                    }
                }
            }
        }
    }

    /// The relay takes no frames once the socket has ended there: the worker
    /// closed it, or a frame of ours broke it. The stream's last record says
    /// which, so the stream gets a moment to bring it.
    private func framesRefused(_ status: Int) {
        lock.lock()
        sendingOver = true
        pending = []
        lock.unlock()
        Task {
            try? await Task.sleep(for: Self.flushTimeout)
            self.cancelStream()
            self.finish(reason: "the relay refused frames: HTTP \(status)")
        }
    }

    private static let posts = URLSession(configuration: .default)

    /// The status and the relay's count of accepted records; nil when the
    /// request did not get an answer.
    private static func upload(_ request: URLRequest, _ body: Data) async -> (status: Int, accepted: Int?)? {
        await withCheckedContinuation { continuation in
            posts.uploadTask(with: request, from: body) { _, response, error in
                guard error == nil, let http = response as? HTTPURLResponse else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: (http.statusCode, http.value(forHTTPHeaderField: acceptedHeader).flatMap { Int($0) }))
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

    /// The next POST's records. Any POST answers a keepalive; one goes out
    /// on its own only when nothing else is queued.
    private func takeBatch() -> [Data]? {
        lock.lock(); defer { lock.unlock() }
        guard opened, !finished, !sendingOver else { return nil }
        let due = keepaliveDue
        keepaliveDue = false
        if pending.isEmpty { return due ? [RelayRecord.keepalive.encoded] : nil }
        return RelayRecord.batch(from: &pending, maxBytes: Self.maxBatchBytes)
    }

    private func isOver() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
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

        // The relay's own account of the end outranks ours of how we noticed.
        let code: Int, text: String
        if let record {
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
        let keepalive = records.contains(.keepalive) && !over
        if keepalive { keepaliveDue = true }
        lock.unlock()
        guard !over else { return }
        if keepalive { wake.yield() }
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
