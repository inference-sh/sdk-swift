import XCTest
@testable import InferenceSDK

final class DecodeTests: XCTestCase {
    func testRequestEncodesWireNames() throws {
        let req = ApiAgentRunRequest(chatId: "chat_1", agent: "ns/agent@latest", input: LLMInput(text: "hi"), stream: true)
        let data = try JSONEncoder().encode(req)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["chat_id"] as? String, "chat_1")
        XCTAssertEqual(obj["agent"] as? String, "ns/agent@latest")
        XCTAssertEqual(obj["stream"] as? Bool, true)
        let input = try XCTUnwrap(obj["input"] as? [String: Any])
        XCTAssertEqual(input["text"] as? String, "hi")
        XCTAssertNil(input["context"], "nil optionals must be omitted")
        XCTAssertNil(obj["agent_config"])
    }

    func testDecodesPendingMessageWithNullContent() throws {
        let json = """
        {"id":"msg_1","short_id":"m1","created_at":"2026-09-15T00:00:00Z","updated_at":"2026-09-15T00:00:00Z",
         "user_id":"u","team_id":"t","visibility":"private","chat_id":"chat_1","order":1,
         "status":"pending","role":"assistant","content":null}
        """
        let msg = try JSONDecoder().decode(ChatMessageDTO.self, from: Data(json.utf8))
        XCTAssertEqual(msg.status, .pending)
        XCTAssertFalse(msg.status.isTerminal)
        XCTAssertEqual(msg.text, "")
    }

    func testStreamLineParsing() throws {
        XCTAssertNil(InferenceClient.parseStreamLine(#"{"type":"heartbeat"}"#))
        XCTAssertNil(InferenceClient.parseStreamLine(#"{"event":"agent_runs","data":{"id":"r"}}"#))
        XCTAssertNil(InferenceClient.parseStreamLine(""))
        let line = """
        {"id":"msg_2","short_id":"m2","created_at":"x","updated_at":"x","user_id":"u","team_id":"t",
         "visibility":"private","chat_id":"chat_1","order":2,"status":"ready","role":"assistant",
         "content":[{"type":"reasoning","text":"thinking"},{"type":"text","text":"Hello "},{"type":"text","text":"there"}],
         "tool_invocations":[]}
        """
        let msg = try XCTUnwrap(InferenceClient.parseStreamLine(line))
        XCTAssertTrue(msg.status.isTerminal)
        XCTAssertEqual(msg.text, "Hello there")
        XCTAssertEqual(msg.role, .assistant)
    }

    /// Real capture of POST /agents/run (stream: true, NDJSON) against api.inference.sh.
    func testRealStreamCaptureDecodes() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "agents-run-stream", withExtension: "ndjson", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url)
        var messages: [ChatMessageDTO] = []
        var skipped = 0
        for line in text.split(separator: "\n") {
            if let m = InferenceClient.parseStreamLine(String(line)) { messages.append(m) } else { skipped += 1 }
        }
        XCTAssertEqual(skipped, 1, "one heartbeat")
        XCTAssertEqual(messages.count, 10)
        XCTAssertTrue(messages.dropLast().allSatisfy { !$0.status.isTerminal })
        let last = try XCTUnwrap(messages.last)
        XCTAssertEqual(last.status, .ready)
        XCTAssertEqual(last.text, "PTT e2e ok")
        XCTAssertFalse(last.chatId.isEmpty)
    }

    func testUnknownEnumValueStillDecodes() throws {
        let s = try JSONDecoder().decode(ChatMessageStatus.self, from: Data(#""brand_new_status""#.utf8))
        XCTAssertEqual(s.rawValue, "brand_new_status")
        XCTAssertFalse(s.isTerminal)
    }

    func testJSONValueRoundTrip() throws {
        let v: JSONValue = ["a": 1, "b": [true, nil, "x"], "c": ["d": 2.5]]
        let data = try JSONEncoder().encode(v)
        let back = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(v, back)
        XCTAssertEqual(back["b"]?[2]?.stringValue, "x")
    }
}
