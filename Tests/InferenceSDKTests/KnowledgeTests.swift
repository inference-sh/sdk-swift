import XCTest
@testable import InferenceSDK

final class KnowledgeTests: XCTestCase {
    func testCreateRequestEncodesMarkdownDocument() throws {
        let req = KnowledgeCreateRequest(
            name: "standup-2026-09-27",
            description: "Standup transcript",
            type: .observation,
            version: KnowledgeVersionInput(content: KnowledgeFile(content: "# Standup\n\n- shipped"),
                                           tags: ["transcript"]))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any])
        XCTAssertEqual(obj["name"] as? String, "standup-2026-09-27")
        XCTAssertEqual(obj["type"] as? String, "observation")
        XCTAssertNil(obj["repo_url"], "nil optionals must be omitted")
        XCTAssertNil(obj["lifecycle"])
        let version = try XCTUnwrap(obj["version"] as? [String: Any])
        XCTAssertEqual(version["tags"] as? [String], ["transcript"])
        let content = try XCTUnwrap(version["content"] as? [String: Any])
        XCTAssertEqual(content as? [String: String], ["content": "# Standup\n\n- shipped"])
    }

    func testEndpoints() async throws {
        var client = InferenceClient(apiKey: "k")
        client.transport = StubProtocol.start { req, _ in
            if req.url?.path.hasSuffix("/versions/list") == true {
                return .json(#"{"data":{"items":[],"next_cursor":"","prev_cursor":"","has_next":false,"has_previous":false,"items_per_page":0,"total_items":0}}"#)
            }
            return req.httpMethod == "DELETE" ? .json(#"{"data":null}"#) : .json(#"{"data":\#(Self.knowledgeJSON)}"#)
        }
        let created = try await client.knowledge.create(KnowledgeCreateRequest(
            name: "note", version: KnowledgeVersionInput(content: KnowledgeFile(content: "hi"))))
        XCTAssertEqual(created.namespace, "okaris")
        XCTAssertEqual(created.version?.content.path, "instructions.md")
        _ = try await client.knowledge.get("k1")
        _ = try await client.knowledge.getByName(namespace: "okaris", name: "note")
        _ = try await client.knowledge.update("k1", KnowledgeUpdateRequest(description: "new"))
        _ = try await client.knowledge.listVersions("k1")
        _ = try await client.knowledge.getVersion("k1", "v1")
        _ = try await client.knowledge.transferOwnership("k1", newTeamId: "team2")
        _ = try await client.knowledge.updateVisibility("k1", visibility: "public")
        try await client.knowledge.delete("k1")

        let calls = StubProtocol.recorded.map { "\($0.request.httpMethod ?? "") \($0.path)" }
        XCTAssertEqual(calls, [
            "POST /knowledge",
            "GET /knowledge/k1",
            "GET /knowledge/okaris/note",
            "POST /knowledge/k1",
            "POST /knowledge/k1/versions/list",
            "GET /knowledge/k1/versions/v1",
            "POST /knowledge/k1/transfer",
            "POST /knowledge/k1/visibility",
            "DELETE /knowledge/k1",
        ])
        func body(_ i: Int) -> [String: Any]? {
            try? JSONSerialization.jsonObject(with: StubProtocol.recorded[i].body) as? [String: Any]
        }
        XCTAssertEqual((body(0)?["version"] as? [String: Any])?["content"] as? [String: String], ["content": "hi"])
        XCTAssertEqual(body(3) as? [String: String], ["description": "new"])
        XCTAssertEqual(body(6) as? [String: String], ["team_id": "team2"])
        XCTAssertEqual(body(7) as? [String: String], ["visibility": "public"])
        XCTAssertTrue(StubProtocol.recorded.allSatisfy { $0.authorization == "Bearer k" })
    }

    static let knowledgeJSON = #"""
        {"id":"k1","short_id":"k1","created_at":"x","updated_at":"x","user_id":"u","team_id":"t","visibility":"private",
         "namespace":"okaris","name":"note","title":"","description":"","type":"observation","lifecycle":"permanent",
         "version_id":"v1","uses":0,"installs":0,
         "version":{"id":"v1","short_id":"v1","created_at":"x","updated_at":"x","knowledge_id":"k1",
                    "content":{"path":"instructions.md","uri":"https://cdn.example.com/k1","size":2,"hash":"h"},
                    "content_hash":"h","description":""}}
        """#
}
