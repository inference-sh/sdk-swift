import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import InferenceSDK

/// URLProtocol stub for the request tests. Install with `StubProtocol.start`,
/// which returns an HTTPTransport whose sessions (one-shot and stream) route
/// every request through `handler`. Requests are recorded with their bodies.
final class StubProtocol: URLProtocol {
    struct Response {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: Data = Data()
    }

    struct Recorded {
        let request: URLRequest
        let body: Data
        var authorization: String? { request.value(forHTTPHeaderField: "Authorization") }
        var path: String { request.url?.path ?? "" }
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: ((URLRequest, Data) -> Response)?
        var recorded: [Recorded] = []
    }
    private static let state = State()

    static func start(_ handler: @escaping (URLRequest, Data) -> Response) -> HTTPTransport {
        state.lock.lock(); defer { state.lock.unlock() }
        state.handler = handler
        state.recorded = []
        return HTTPTransport(protocolClasses: [StubProtocol.self])
    }

    static var recorded: [Recorded] {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        Self.state.lock.lock()
        Self.state.recorded.append(Recorded(request: request, body: body))
        let handler = Self.state.handler
        Self.state.lock.unlock()

        let r = handler?(request, body) ?? Response(status: 599)
        let http = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: r.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

extension StubProtocol.Response {
    static func json(_ text: String, status: Int = 200) -> Self {
        Self(status: status, body: Data(text.utf8))
    }
}

/// Parses a form body into a dictionary (last value wins).
func formFields(_ body: Data) -> [String: String] {
    var comps = URLComponents()
    comps.percentEncodedQuery = String(decoding: body, as: UTF8.self)
    var out: [String: String] = [:]
    for item in comps.queryItems ?? [] { out[item.name] = item.value ?? "" }
    return out
}
