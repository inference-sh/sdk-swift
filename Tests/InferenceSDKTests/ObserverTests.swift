import Foundation
import XCTest
@testable import InferenceSDK

/// InferenceClient.onFailure, AgentChatSession.changes(), the MCP params
/// decoded once, and AgentDTO naming.
final class ObserverTests: XCTestCase {
    private static let deactivated = #"{"type":"https://inference.sh/problems/account_deactivated","title":"Forbidden","status":403}"#

    private func codes(_ failures: Recorder<InferenceError>) -> [String] {
        failures.values.map { e in
            guard case .http(let status, _) = e else { return "?" }
            return "\(status) \(e.problem?.code ?? "")"
        }
    }

    // MARK: onFailure

    func testFailureReportsAnErrorResponse() async {
        let failures = Recorder<InferenceError>()
        var client = InferenceClient(apiKey: "k")
        client.onFailure = { failures.append($0) }
        client.transport = StubProtocol.start { _, _ in .json(Self.deactivated, status: 403) }
        do {
            try await client.tasks.cancel("t1")
            XCTFail("expected 403")
        } catch InferenceError.http(let status, _) {
            XCTAssertEqual(status, 403)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(codes(failures), ["403 account_deactivated"])
    }

    func testFailureSkipsA401TheRefreshCures() async throws {
        let failures = Recorder<InferenceError>()
        let provider = RefreshingAuthProvider(
            tokens: OAuthTokens(accessToken: "old", refreshToken: "infrt-1", expiresAt: Date().addingTimeInterval(600)),
            refresh: { _ in OAuthTokens(accessToken: "new", refreshToken: "infrt-2", expiresAt: Date().addingTimeInterval(600)) })
        var client = InferenceClient(auth: provider)
        client.onFailure = { failures.append($0) }
        client.transport = StubProtocol.start { req, _ in
            req.value(forHTTPHeaderField: "Authorization") == "Bearer new"
                ? .json(#"{"data":null}"#)
                : .json(#"{"title":"unauthorized"}"#, status: 401)
        }
        try await client.files.delete("f1")
        XCTAssertEqual(StubProtocol.recorded.count, 2)
        XCTAssertTrue(failures.values.isEmpty)
    }

    func testFailureReportsALasting401Once() async {
        let failures = Recorder<InferenceError>()
        let provider = RefreshingAuthProvider(
            tokens: OAuthTokens(accessToken: "old", refreshToken: "infrt-1", expiresAt: Date().addingTimeInterval(600)),
            refresh: { _ in OAuthTokens(accessToken: "new", refreshToken: "infrt-2", expiresAt: Date().addingTimeInterval(600)) })
        var client = InferenceClient(auth: provider)
        client.onFailure = { failures.append($0) }
        client.transport = StubProtocol.start { _, _ in .json(#"{"title":"unauthorized"}"#, status: 401) }
        do { try await client.files.delete("f1"); XCTFail("expected 401") } catch {}
        XCTAssertEqual(StubProtocol.recorded.map(\.authorization), ["Bearer old", "Bearer new"])
        XCTAssertEqual(codes(failures), ["401 "])

        // A key cannot refresh: its 401 is reported straight away.
        let keyFailures = Recorder<InferenceError>()
        var keyed = InferenceClient(apiKey: "k")
        keyed.onFailure = { keyFailures.append($0) }
        keyed.transport = StubProtocol.start { _, _ in .json(#"{"title":"unauthorized"}"#, status: 401) }
        do { try await keyed.files.delete("f1"); XCTFail("expected 401") } catch {}
        XCTAssertEqual(codes(keyFailures), ["401 "])
    }

    func testFailureIgnoresOtherHosts() async {
        let failures = Recorder<InferenceError>()
        var client = InferenceClient(apiKey: "k")
        client.onFailure = { failures.append($0) }
        client.transport = StubProtocol.start { _, _ in .json("denied", status: 403) }
        do { _ = try await client.download(URL(string: "https://cdn.example.com/a.wav")!); XCTFail("expected 403") } catch {}
        XCTAssertTrue(failures.values.isEmpty)
    }

    func testFailureReportsStreamConnects() async {
        let failures = Recorder<InferenceError>()
        var client = InferenceClient(apiKey: "k")
        client.onFailure = { failures.append($0) }
        client.transport = StubProtocol.start { _, _ in .json(Self.deactivated, status: 403) }

        do {
            for try await _ in client.runAgentStream(ApiAgentRunRequest(agent: "a/b", input: LLMInput(text: "hi"))) {}
            XCTFail("expected 403")
        } catch InferenceError.http(let status, let body) {
            XCTAssertEqual(status, 403)
            XCTAssertTrue(body.contains("account_deactivated"))
        } catch { XCTFail("\(error)") }

        do {
            for try await _ in client.chats.stream("c1") {}
            XCTFail("expected 403")
        } catch InferenceError.http(let status, _) {
            XCTAssertEqual(status, 403)
        } catch { XCTFail("\(error)") }
        // Not reconnected: one connect, one report.
        XCTAssertEqual(StubProtocol.recorded.filter { $0.path == "/chats/c1/stream" }.count, 1)
        XCTAssertEqual(codes(failures), ["403 account_deactivated", "403 account_deactivated"])
    }

    private static func refreshing() -> RefreshingAuthProvider {
        RefreshingAuthProvider(
            tokens: OAuthTokens(accessToken: "old", refreshToken: "infrt-1", expiresAt: Date().addingTimeInterval(600)),
            refresh: { _ in OAuthTokens(accessToken: "new", refreshToken: "infrt-2", expiresAt: Date().addingTimeInterval(600)) })
    }

    private static let sse = StubProtocol.Response(
        headers: ["Content-Type": "text/event-stream"],
        body: Data("event: delta\ndata: {\"delta\":{\"content\":\"hi\"},\"seq\":1,\"resource_id\":\"m1\"}\n\n".utf8))

    func testStreamConnectGivesBackTheRetriedStreamWhenTheRefreshCures401() async throws {
        let failures = Recorder<InferenceError>()
        var client = InferenceClient(auth: Self.refreshing())
        client.onFailure = { failures.append($0) }
        client.transport = StubProtocol.start { req, _ in
            req.value(forHTTPHeaderField: "Authorization") == "Bearer new"
                ? Self.sse
                : .json(#"{"title":"unauthorized"}"#, status: 401)
        }
        var messageIds: [String] = []
        for try await event in client.chats.stream("c1") {
            if case .delta(let id, _) = event { messageIds.append(id) }
            break
        }
        XCTAssertEqual(messageIds, ["m1"])
        XCTAssertEqual(StubProtocol.recorded.filter { $0.path == "/chats/c1/stream" }.map(\.authorization),
                       ["Bearer old", "Bearer new"])
        XCTAssertTrue(failures.values.isEmpty)
    }

    func testStreamConnectReportsALasting401Once() async {
        let failures = Recorder<InferenceError>()
        var client = InferenceClient(auth: Self.refreshing())
        client.onFailure = { failures.append($0) }
        client.transport = StubProtocol.start { _, _ in .json(#"{"title":"unauthorized"}"#, status: 401) }
        do {
            for try await _ in client.chats.stream("c1") {}
            XCTFail("expected 401")
        } catch InferenceError.http(let status, _) {
            XCTAssertEqual(status, 401)
        } catch { XCTFail("\(error)") }
        // Retried once with the refreshed token, never reconnected.
        XCTAssertEqual(StubProtocol.recorded.filter { $0.path == "/chats/c1/stream" }.map(\.authorization),
                       ["Bearer old", "Bearer new"])
        XCTAssertEqual(codes(failures), ["401 "])
    }

    // MARK: changes()

    @MainActor
    func testChangesMulticast() async {
        var session: AgentChatSession? = AgentChatSession(client: InferenceClient(apiKey: "k"), agent: "a/b")
        var owner: [ConnectionStatus] = []
        session?.onChange = { owner.append($0.connectionStatus) }
        let first = session!.changes()
        let second = session!.changes()

        session?.clearError()   // setError(nil), setConnectionStatus(.idle)
        session?.onChange = nil // a second owner taking onChange leaves the streams alone
        session?.reset()        // stopStream's setConnection(.idle), then reset
        session = nil           // finishes both streams

        var a: [Bool] = [], b: [Bool] = []
        for await s in first { a.append(s.error == nil) }
        for await s in second { b.append(s.error == nil) }
        // The current state, then one per transition.
        XCTAssertEqual(a.count, 5)
        XCTAssertEqual(b.count, 5)
        XCTAssertEqual(owner, [.idle, .idle])
    }

    @MainActor
    func testChangesStopsYieldingToAReaderThatLeft() async {
        let session = AgentChatSession(client: InferenceClient(apiKey: "k"), agent: "a/b")
        let task = Task { for await _ in session.changes() {} }
        while session.observerCount == 0 { await Task.yield() }
        task.cancel()
        await task.value
        XCTAssertEqual(session.observerCount, 0)  // removed, not kept for the session's lifetime
        session.clearError() // nothing left to yield to; must not trap

        // A reader that breaks out drops its iterator, which ends the stream too.
        var count = 0
        for await _ in session.changes() { count += 1; break }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(session.observerCount, 0)
    }

    // MARK: MCP input

    func testElicitationsDecodedOnce() throws {
        let data: JSONValue = [
            "input_required": true,
            "input_requests": [
                "login": ["method": "elicitation/create", "params": ["message": "sign in", "url": "https://example.com/auth"]],
                "sample": ["method": "sampling/createMessage", "params": [:]],
            ],
        ]
        var state = try XCTUnwrap(MCPInputState(data: data))
        XCTAssertEqual(state.elicitations.keys.sorted(), ["login"])
        XCTAssertEqual(state.elicitations["login"], state.inputRequests["login"]?.elicitParams)
        XCTAssertEqual(state.elicitations["login"]?.isURL, true)

        // Kept in step with the requests.
        state.inputRequests["form"] = InputRequest(method: "elicitation/create", params: ["message": "name?"])
        XCTAssertEqual(state.elicitations["form"]?.message, "name?")
        XCTAssertEqual(MCPInputState(inputRequests: state.inputRequests).elicitations.count, 2)
    }

    func testParsingJSONString() {
        XCTAssertEqual(JSONValue.string(#"{"a":1}"#).parsingJSONString, ["a": 1])
        XCTAssertEqual(JSONValue.string("[true]").parsingJSONString, [true])
        XCTAssertNil(JSONValue.string("not json").parsingJSONString)
        XCTAssertEqual(JSONValue.object(["a": "b"]).parsingJSONString, ["a": "b"])
        XCTAssertEqual(JSONValue.number(2).parsingJSONString, 2)
    }

    // MARK: AgentDTO naming

    func testAgentDisplayTitleAndRef() {
        func agent(_ namespace: String, _ name: String, _ title: String) -> AgentDTO {
            AgentDTO(visibility: .private, namespace: namespace, name: name, title: title, images: AgentImages())
        }
        XCTAssertEqual(agent("okaris", "chief", "Chief").displayTitle, "Chief")
        XCTAssertEqual(agent("okaris", "chief", "").displayTitle, "chief")
        XCTAssertEqual(agent("okaris", "chief", "  ").displayTitle, "chief")
        XCTAssertEqual(agent("okaris", "chief", "").ref, "okaris/chief")
        XCTAssertEqual(agent("", "chief", "").ref, "chief")
    }
}
