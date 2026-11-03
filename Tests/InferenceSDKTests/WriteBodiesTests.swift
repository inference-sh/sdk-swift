import Foundation
import XCTest
@testable import InferenceSDK

/// Update request shapes (sdk-js write-bodies.ts). The API refuses a write
/// body's unknown keys, relations and changed read-only fields in enforce
/// mode, so each update sends only the fields set.
final class WriteBodiesTests: XCTestCase {
    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testUpdatesSendOnlyTheFieldsSet() async throws {
        var client = InferenceClient(apiKey: "k")
        client.transport = StubProtocol.start { req, _ in
            let path = req.url?.path ?? ""
            if path.hasPrefix("/agents/") {
                return .json(#"{"data":{"id":"a1","visibility":"private","name":"a","harness":"native"}}"#)
            }
            return .json(#"{"data":null}"#)
        }

        _ = try? await client.agents.update("a1", AgentUpdateBody(images: ResourceImages(card: "c")))
        _ = try? await client.chats.update("c1", ChatUpdateBody(name: "renamed"))
        _ = try? await client.apps.patch("app1", AppPatchBody(title: "T", agentDescription: "for agents"))
        _ = try? await client.apps.update("app1", AppUpdateBody(AppPatchBody(tags: ["x"]), versionId: "v1"))
        _ = try? await client.teams.update("t1", TeamUpdateBody(avatarUrl: "https://a/b.png"))

        let r = StubProtocol.recorded
        XCTAssertEqual(r.map(\.path), ["/agents/a1", "/chats/c1", "/apps/app1", "/apps/app1", "/teams/t1"])
        XCTAssertEqual(r.map { $0.request.httpMethod }, ["POST", "PATCH", "PATCH", "POST", "PATCH"])

        let agent = try json(r[0].body)
        XCTAssertEqual(Set(agent.keys), ["images"])
        XCTAssertEqual(try json(r[1].body) as NSDictionary, ["name": "renamed"])
        XCTAssertEqual(try json(r[2].body) as NSDictionary, ["title": "T", "agent_description": "for agents"])
        XCTAssertEqual(try json(r[3].body) as NSDictionary, ["tags": ["x"], "version_id": "v1"])
        XCTAssertEqual(try json(r[4].body) as NSDictionary, ["avatar_url": "https://a/b.png"])

        for rec in r {
            let keys = Set(try json(rec.body).keys)
            for refused in ["id", "user", "team", "user_id", "team_id", "visibility", "namespace", "username"] {
                XCTAssertFalse(keys.contains(refused), "\(rec.path) sent \(refused)")
            }
        }
    }
}
