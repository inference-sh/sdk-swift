import XCTest
@testable import InferenceSDK

/// tasks.run against a stubbed api: POST /apps/run answers with a
/// TaskResultDTO, GET /tasks/{id} with a TaskDTO (Fixtures/task.json, a real
/// response with the values replaced), GET /tasks/{id}/stream with NDJSON.
final class TaskRunTests: XCTestCase {
    private func fixture(status: Int) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "task", withExtension: "json", subdirectory: "Fixtures"))
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        obj["status"] = status
        return try JSONSerialization.data(withJSONObject: ["data": obj])
    }

    private let created = #"{"data":{"id":"t1","short_id":"s","status":1,"status_text":"","output":null,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}}"#

    /// The stream drops before a terminal status (a dead connection, the
    /// server restarting): run resyncs with GET /tasks/{id} and returns the
    /// task the server finished meanwhile, instead of hanging or failing.
    func testStreamDropResyncsFromServer() async throws {
        let dispatched = try fixture(status: 3)
        let completed = try fixture(status: 10)
        var client = InferenceClient(apiKey: "k")
        client.transport = StubProtocol.start { req, _ in
            switch (req.httpMethod ?? "", req.url?.path ?? "") {
            case ("POST", "/apps/run"):
                return .json(self.created)
            case ("GET", "/tasks/t1/stream"):
                let partial = #"{"data":{"id":"t1","status":7},"fields":["status"]}"#
                return StubProtocol.Response(headers: ["Content-Type": "application/x-ndjson"],
                                             body: Data((partial + "\n").utf8))  // then ends: no terminal line
            case ("GET", "/tasks/t1"):
                let gets = StubProtocol.recorded.filter { $0.path == "/tasks/t1" }.count
                return StubProtocol.Response(body: gets <= 1 ? dispatched : completed)
            default:
                return .json(#"{"title":"unexpected"}"#, status: 404)
            }
        }
        let statuses = Recorder<Int>()
        let task = try await client.tasks.run(
            ApiAppRunRequest(app: "a/b", input: ["prompt": "x"]),
            options: TaskRunOptions(onUpdate: { statuses.append($0.status.rawValue) },
                                    onPartialUpdate: { t, _ in statuses.append(t.status.rawValue) }))
        XCTAssertEqual(task.status, .completed)
        XCTAssertEqual(statuses.values, [7, 10])
        XCTAssertEqual(StubProtocol.recorded.map(\.path), ["/apps/run", "/tasks/t1", "/tasks/t1/stream", "/tasks/t1"])
    }

    /// The stream connect is refused: thrown as the API's error with the
    /// body cut to 2000 bytes, not reconnected, and reported once.
    func testStreamRefusalIsThrownCutAndReported() async throws {
        let dispatched = try fixture(status: 3)
        let failures = Recorder<InferenceError>()
        var client = InferenceClient(apiKey: "k")
        client.onFailure = { failures.append($0) }
        let long = String(repeating: "x", count: 3000)
        client.transport = StubProtocol.start { req, _ in
            switch (req.httpMethod ?? "", req.url?.path ?? "") {
            case ("POST", "/apps/run"): return .json(self.created)
            case ("GET", "/tasks/t1"): return StubProtocol.Response(body: dispatched)
            case ("GET", "/tasks/t1/stream"): return .json(long, status: 403)
            default: return .json(#"{"title":"unexpected"}"#, status: 404)
            }
        }
        do {
            _ = try await client.tasks.run(ApiAppRunRequest(app: "a/b", input: ["prompt": "x"]))
            XCTFail("expected 403")
        } catch InferenceError.http(let status, let body) {
            XCTAssertEqual(status, 403)
            XCTAssertEqual(body.count, 2000)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(StubProtocol.recorded.filter { $0.path == "/tasks/t1/stream" }.count, 1)
        XCTAssertEqual(failures.values.map { e -> Int in
            guard case .http(let status, _) = e else { return 0 }
            return status
        }, [403])
    }
}
