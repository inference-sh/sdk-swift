import XCTest
@testable import InferenceSDK

/// Port of js/sdk-js/src/api/sockets.test.ts: the api stubbed, the socket fake.
final class SocketsAPITests: XCTestCase {
    private let access = #"{"id":"sock-1","url":"wss://relay.test/sockets/sock-1","token":"tok","expires_at":"2030-01-01T00:00:00Z"}"#
    private let socket = #"{"id":"sock-1","short_id":"s","created_at":"x","updated_at":"x","user_id":"u","team_id":"t","visibility":"private","task_id":"task-1","relay":"wss://relay.test","status":"pending","client_frames":0,"client_bytes":0,"worker_frames":0,"worker_bytes":0}"#

    private func page(_ items: String) -> String {
        #"{"data":{"items":[\#(items)],"next_cursor":"","prev_cursor":"","has_next":false,"has_previous":false,"items_per_page":1,"total_items":1}}"#
    }

    private func created(socket: String?) -> String {
        let field = socket.map { #","socket":\#($0)"# } ?? ""
        return #"{"data":{"id":"task-1","short_id":"s","status":1,"status_text":"","output":null,"created_at":"x","updated_at":"x"\#(field)}}"#
    }

    private func task(status: Int, error: String? = nil) throws -> StubProtocol.Response {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "task", withExtension: "json", subdirectory: "Fixtures"))
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        obj["id"] = "task-1"
        obj["status"] = status
        if let error { obj["error"] = error }
        return StubProtocol.Response(body: try JSONSerialization.data(withJSONObject: ["data": obj]))
    }

    private func requests() -> [String] {
        StubProtocol.recorded.map { "\($0.request.httpMethod ?? "") \($0.path)" }
    }

    /// A client whose api answers like one with a single stream task.
    private func client(task taskResponse: StubProtocol.Response? = nil, sockets: Bool = true) -> InferenceClient {
        var client = InferenceClient(apiKey: "k")
        client.transport = StubProtocol.start { req, _ in
            switch (req.httpMethod ?? "", req.url?.path ?? "") {
            case ("GET", "/sockets/sock-1"): return .json(#"{"data":\#(self.socket)}"#)
            case ("POST", "/sockets/list"): return .json(self.page(sockets ? self.socket : ""))
            case ("POST", "/sockets/sock-1/access"): return .json(#"{"data":\#(self.access)}"#)
            case ("DELETE", "/sockets/sock-1"): return .json(#"{"data":null}"#)
            case ("POST", "/apps/run"): return .json(self.created(socket: self.access))
            case ("GET", "/tasks/task-1"): return taskResponse ?? .json(#"{"title":"not found"}"#, status: 404)
            default: return .json(#"{"title":"unexpected"}"#, status: 404)
            }
        }
        return client
    }

    func testReadsListsAndRenewsSockets() async throws {
        let api = client().sockets
        let read = try await api.get("sock-1")
        XCTAssertEqual(read.taskId, "task-1")
        XCTAssertEqual(read.status, .pending)
        let found = try await api.forTask("task-1")
        XCTAssertEqual(found?.id, "sock-1")
        let fresh = try await api.access("sock-1")
        XCTAssertEqual(fresh.token, "tok")
        try await api.delete("sock-1")

        XCTAssertEqual(requests(), ["GET /sockets/sock-1", "POST /sockets/list", "POST /sockets/sock-1/access", "DELETE /sockets/sock-1"])
        let list = try JSONDecoder().decode(JSONValue.self, from: StubProtocol.recorded[1].body)
        XCTAssertEqual(list["limit"], 1)
        XCTAssertEqual(list["filters"], [["field": "task_id", "operator": "eq", "value": "task-1"]])
    }

    func testForTaskIsNilWithoutASocket() async throws {
        let found = try await client(sockets: false).sockets.forTask("task-1")
        XCTAssertNil(found)
    }

    func testDialsTheAccessTheRunResponseCarriesWithoutAskingForAnything() async throws {
        let relay = FakeRelay()
        let api = client()
        let run: TaskResultDTO = try api.decode(Data(created(socket: access).utf8))
        let session = try await api.sockets.open(run, options: OpenSocketOptions(watchTask: false, dial: relay.dial))
        XCTAssertEqual(requests(), [])
        XCTAssertEqual(relay.last.url, "wss://relay.test/sockets/sock-1")
        XCTAssertEqual(relay.last.authorization, "Bearer tok")
        XCTAssertEqual(session.state, .connecting)
        session.close()
    }

    func testForwardsTheSchemas() async throws {
        let pcm: JSONValue = [
            "type": "array", "format": "stream",
            "items": ["type": "string", "format": "binary", "contentMediaType": "audio/pcm;rate=24000"],
        ]
        let relay = FakeRelay()
        let api = client()
        let run: TaskResultDTO = try api.decode(Data(created(socket: access).utf8))
        let session = try await api.sockets.open(run, options: OpenSocketOptions(
            watchTask: false, dial: relay.dial,
            inputSchema: ["type": "object", "properties": ["audio": pcm, "voice": ["type": "string"]]],
            outputSchema: ["type": "object", "properties": ["audio": pcm, "line": ["type": "string"]]]))
        relay.last.open()
        await eventually("open") { session.isOpen }
        let frame = Data([7])
        try session.sendField("audio", .binary(frame))
        try session.sendField("voice", .json("ara"))
        XCTAssertEqual(relay.last.sent, [.binary(frame), .text(#"{"voice":"ara"}"#)])
        XCTAssertEqual(session.updates(for: .binary(frame)), [LiveUpdate(field: "audio", value: .binary(frame))])
        session.close()
    }

    func testFindsTheSocketOfATaskIdAndIssuesACredentialForIt() async throws {
        let relay = FakeRelay()
        let session = try await client().sockets.open("task-1", options: OpenSocketOptions(watchTask: false, dial: relay.dial))
        XCTAssertEqual(requests(), ["POST /sockets/list", "POST /sockets/sock-1/access"])
        XCTAssertEqual(relay.dialed.count, 1)
        XCTAssertEqual(relay.last.authorization, "Bearer tok")
        session.close()
    }

    func testRenewsThroughTheCredentialIdWhenTheRelayRestartsEarly() async throws {
        let first = #"{"id":"sock-1","url":"wss://relay.test/sockets/sock-1","token":"tok-a","expires_at":"2030-01-01T00:00:00Z"}"#
        let relay = FakeRelay()
        let api = client()
        let run: TaskResultDTO = try api.decode(Data(created(socket: first).utf8))
        let session = try await api.sockets.open(run, options: OpenSocketOptions(watchTask: false, dial: relay.dial))
        XCTAssertEqual(relay.last.authorization, "Bearer tok-a")
        relay.last.open()
        relay.last.serverClose(1012, "restarting")
        await eventually("second dial") { relay.dialed.count == 2 }

        XCTAssertEqual(requests(), ["POST /sockets/sock-1/access"])
        XCTAssertEqual(relay.last.authorization, "Bearer tok")
        session.close()
    }

    func testRefusesATaskWithoutASocket() async throws {
        let relay = FakeRelay()
        let api = client(sockets: false)
        let run: TaskResultDTO = try api.decode(Data(created(socket: nil).utf8))
        do {
            _ = try await api.sockets.open(run, options: OpenSocketOptions(dial: relay.dial))
            XCTFail("opened a socket the task does not have")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("has no socket"), error.localizedDescription)
        }
        XCTAssertEqual(relay.dialed.count, 0)
    }

    func testEndsTheSessionWhenTheTaskFailsWhileWaiting() async throws {
        let relay = FakeRelay()
        let api = client(task: try task(status: 11, error: "no module named x"))
        let run: TaskResultDTO = try api.decode(Data(created(socket: access).utf8))
        let session = try await api.sockets.open(run, options: OpenSocketOptions(dial: relay.dial))
        relay.last.open()
        let end = await session.ended
        XCTAssertEqual(end, LiveEnd(code: 1000, reason: "no module named x", byCaller: false, taskEnded: true))
        XCTAssertEqual(requests(), ["GET /tasks/task-1"])
        XCTAssertEqual(relay.last.closedWith, ["1000 task ended"])
    }

    func testLiveRunsTheFunctionAndDialsTheSocketOfTheRunResponse() async throws {
        let relay = FakeRelay()
        let (task, session) = try await client().live(
            ApiAppRunRequest(app: "infsh/voice-loop", input: ["effect": "robot"], function: "stream"),
            options: OpenSocketOptions(watchTask: false, dial: relay.dial))
        XCTAssertEqual(task.id, "task-1")
        XCTAssertEqual(task.socket?.id, "sock-1")
        XCTAssertEqual(requests(), ["POST /apps/run"])
        let body = try JSONDecoder().decode(JSONValue.self, from: StubProtocol.recorded[0].body)
        XCTAssertEqual(body["function"], "stream")
        XCTAssertEqual(body["input"], ["effect": "robot"])
        XCTAssertEqual(relay.last.authorization, "Bearer tok")

        relay.last.open()
        relay.last.message("{}")
        await eventually("live") { session.state == .live }
        session.close()
        XCTAssertEqual(relay.last.closedWith, ["1000 done"])
    }

    // MARK: - tasks.watch

    func testWatchSettlesAtOnceForATaskThatHasEnded() async throws {
        let updates = Recorder<Int>()
        let done = try await client(task: try task(status: 10)).tasks.watch(
            "task-1", options: TaskRunOptions(onUpdate: { updates.append($0.status.rawValue) }))
        XCTAssertEqual(done.status, .completed)
        XCTAssertEqual(updates.values, [10])
        XCTAssertEqual(requests(), ["GET /tasks/task-1"])

        do {
            _ = try await client(task: try task(status: 12)).tasks.watch("task-1")
            XCTFail("a cancelled task must throw")
        } catch let error as TaskRunError {
            XCTAssertEqual(error.localizedDescription, "task cancelled")
        }
    }
}
