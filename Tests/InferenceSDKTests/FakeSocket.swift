import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import InferenceSDK

/// A LiveSocket the test drives: it opens, feeds and closes it, and reads
/// what the session sent.
final class FakeSocket: LiveSocket, @unchecked Sendable {
    let request: URLRequest
    let events: AsyncStream<LiveSocketEvent>
    private let sink: AsyncStream<LiveSocketEvent>.Continuation
    private let lock = NSLock()
    private var frames: [LiveFrame] = []
    private var closes: [String] = []

    init(_ request: URLRequest) {
        self.request = request
        (events, sink) = AsyncStream.makeStream(of: LiveSocketEvent.self)
    }

    var url: String { request.url?.absoluteString ?? "" }
    var authorization: String? { request.value(forHTTPHeaderField: "Authorization") }
    var sent: [LiveFrame] { lock.lock(); defer { lock.unlock() }; return frames }
    /// Each close as "code reason".
    var closedWith: [String] { lock.lock(); defer { lock.unlock() }; return closes }

    func send(_ frame: LiveFrame) { lock.lock(); frames.append(frame); lock.unlock() }
    func close(code: Int, reason: String) { lock.lock(); closes.append("\(code) \(reason)"); lock.unlock() }

    func open() { sink.yield(.opened) }
    func message(_ text: String) { sink.yield(.frame(.text(text))) }
    func message(_ data: Data) { sink.yield(.frame(.binary(data))) }
    func serverClose(_ code: Int, _ reason: String = "") {
        sink.yield(.closed(code: code, reason: reason))
        sink.finish()
    }
}

/// Records every dial.
final class FakeRelay: @unchecked Sendable {
    private let sockets = Recorder<FakeSocket>()

    var dialed: [FakeSocket] { sockets.values }
    var last: FakeSocket { sockets.values[sockets.values.count - 1] }

    var dial: LiveDialer {
        { request in
            let socket = FakeSocket(request)
            self.sockets.append(socket)
            return socket
        }
    }
}

/// Everything a session has reported so far.
final class EventLog: @unchecked Sendable {
    private let log = Recorder<LiveEvent>()
    private let finished = Recorder<Bool>()

    init(_ session: LiveSession) {
        let events = session.events
        Task {
            for await event in events { log.append(event) }
            finished.append(true)
        }
    }

    var events: [LiveEvent] { log.values }
    /// The events stream has ended.
    var isFinished: Bool { !finished.values.isEmpty }

    var states: [LiveState] {
        events.compactMap { if case .state(let state) = $0 { return state } else { return nil } }
    }
    /// Everything but the state changes.
    var frames: [LiveEvent] {
        events.filter { if case .state = $0 { return false } else { return true } }
    }
    var ends: [LiveEnd] {
        states.compactMap { if case .ended(let end) = $0 { return end } else { return nil } }
    }
}

/// Waits for something that happens on another task. Fails the test after 5s.
func eventually(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                _ condition: @escaping () -> Bool) async {
    for _ in 0..<1000 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("timed out waiting for: \(what)", file: file, line: line)
}

/// Lets tasks that are already runnable run, for asserting that nothing happened.
func settle() async {
    try? await Task.sleep(for: .milliseconds(50))
}

func socketAccess(_ n: Int = 1) -> SocketAccess {
    SocketAccess(id: "sock-1", url: "wss://relay.test/sockets/sock-1", token: "tok-\(n)", expiresAt: "2030-01-01T00:00:00Z")
}
