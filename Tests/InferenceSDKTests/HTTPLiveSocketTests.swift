import XCTest
@testable import InferenceSDK

/// The relay's HTTP framing (relay README, "Client end over HTTP").
final class HTTPLiveSocketTests: XCTestCase {
    func testEncodesRecordsAsKindLengthPayload() {
        XCTAssertEqual([UInt8](RelayRecord.text("hi").encoded), [1, 0, 0, 0, 2, 0x68, 0x69])
        XCTAssertEqual([UInt8](RelayRecord.binary(Data([7, 8, 9])).encoded), [2, 0, 0, 0, 3, 7, 8, 9])
        XCTAssertEqual([UInt8](RelayRecord.close(code: 1000, reason: "ok").encoded), [8, 0, 0, 0, 4, 0x03, 0xE8, 0x6F, 0x6B])
        XCTAssertEqual([UInt8](RelayRecord.keepalive.encoded), [9, 0, 0, 0, 0])
    }

    func testParsesWholeRecordsAndKeepsAPartialOne() {
        let all = RelayRecord.text("hello").encoded + RelayRecord.keepalive.encoded
            + RelayRecord.binary(Data(repeating: 1, count: 300)).encoded + RelayRecord.close(code: 4000, reason: "app finished").encoded
        var buffer = Data()
        var got: [RelayRecord] = []
        // Arrives in awkward pieces, as a stream does.
        for chunk in stride(from: 0, to: all.count, by: 7) {
            buffer.append(all[chunk..<min(chunk + 7, all.count)])
            got += RelayRecord.parse(&buffer)
        }
        XCTAssertEqual(got, [.text("hello"), .keepalive, .binary(Data(repeating: 1, count: 300)),
                             .close(code: 4000, reason: "app finished")])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testAPartialHeaderWaits() {
        var buffer = Data([1, 0, 0])
        XCTAssertEqual(RelayRecord.parse(&buffer), [])
        XCTAssertEqual(buffer.count, 3)
        buffer.append(contentsOf: [0, 1, 0x41])
        XCTAssertEqual(RelayRecord.parse(&buffer), [.text("A")])
    }

    func testUnknownKindsAreSkipped() {
        var buffer = Data([42, 0, 0, 0, 1, 0xFF]) + RelayRecord.text("after").encoded
        XCTAssertEqual(RelayRecord.parse(&buffer), [.unknown(42), .text("after")])
    }

    func testEndpointsFromTheSocketURL() {
        let wss = HTTPLiveSocket.endpoints(URL(string: "wss://relay.inference.sh/sockets/abc")!)
        XCTAssertEqual(wss?.stream.absoluteString, "https://relay.inference.sh/sockets/abc/stream")
        XCTAssertEqual(wss?.frames.absoluteString, "https://relay.inference.sh/sockets/abc/frames")

        let ws = HTTPLiveSocket.endpoints(URL(string: "ws://localhost:4500/sockets/abc/?access_token=t")!)
        XCTAssertEqual(ws?.stream.absoluteString, "http://localhost:4500/sockets/abc/stream?access_token=t")

        XCTAssertNil(HTTPLiveSocket.endpoints(URL(string: "ftp://relay/sockets/abc")!))
    }

    func testABadURLClosesWith1006() async {
        var request = URLRequest(url: URL(string: "ftp://relay/sockets/abc")!)
        request.setValue("Bearer t", forHTTPHeaderField: "Authorization")
        let socket = HTTPLiveSocket(request)
        var events: [LiveSocketEvent] = []
        for await event in socket.events { events.append(event) }
        guard case .closed(1006, let reason)? = events.last else { return XCTFail("got \(events)") }
        XCTAssertTrue(reason.contains("no valid url"), reason)
    }

    /// Against a running relay with an echo worker on the other end
    /// (go/relay: `go run ./cmd/echoworker`, which prints these two):
    ///
    ///     RELAY_E2E_URL=ws://localhost:4500/sockets/e2e RELAY_E2E_TOKEN=… swift test --filter HTTPLiveSocketTests
    func testRelayRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["RELAY_E2E_URL"].flatMap(URL.init(string:)), let token = env["RELAY_E2E_TOKEN"] else {
            throw XCTSkip("set RELAY_E2E_URL and RELAY_E2E_TOKEN")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = LiveTransport.http(request)
        // Queued before the stream opens: goes out in the first POST.
        socket.send(.text("hi"))
        var events: [LiveSocketEvent] = []
        for await event in socket.events {
            events.append(event)
            switch event {
            case .frame(.text("echo:hi")):
                socket.send(.binary(Data([1, 2, 3])))
            case .frame(.binary(Data([3, 2, 1]))):
                socket.send(.text("bye"))
            default:
                break
            }
        }
        XCTAssertEqual(events, [.opened, .frame(.text("echo:hi")), .frame(.binary(Data([3, 2, 1]))),
                                .frame(.text("echo:bye")), .closed(code: 4000, reason: "app finished")])
    }

    func testARefusedStreamClosesWith1006AndTheStatus() async throws {
        // A real server that refuses: the relay's 401 for a bad token.
        let base = ProcessInfo.processInfo.environment["RELAY_URL"] ?? "wss://relay.inference.sh"
        guard ProcessInfo.processInfo.environment["LIVE_E2E"] == "1" else { throw XCTSkip("set LIVE_E2E=1") }
        var request = URLRequest(url: URL(string: base + "/sockets/nope")!)
        request.setValue("Bearer nope", forHTTPHeaderField: "Authorization")
        let socket = HTTPLiveSocket(request)
        var events: [LiveSocketEvent] = []
        for await event in socket.events { events.append(event) }
        XCTAssertEqual(events, [.closed(code: 1006, reason: "the relay refused the connection: HTTP 401")])
    }
}
