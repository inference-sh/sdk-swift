import Foundation
import XCTest
@testable import InferenceSDK

/// Chat settings and the approval's always-allow options: request shapes
/// (sdk-js agent/api.ts) and the reducer's MERGE_CHAT_SETTINGS.
final class ChatSettingsTests: XCTestCase {
    private func chat(_ id: String) -> ChatDTO {
        ChatDTO(id: id, visibility: .private, status: .idle, name: "old",
                agentData: ChatData(memory: ["k": "v"], allowAllTools: false))
    }

    func testMergeChatSettings() {
        var state = AgentChatState.initial
        state.chat = chat("c1")
        let dto = ChatSettingsDTO(chatId: "c1", name: "renamed", visibility: .team,
                                  allowAllTools: true, disableHooks: true, memory: [:])
        let next = chatReducer(state, .mergeChatSettings(dto))
        XCTAssertEqual(next.chat?.name, "renamed")
        XCTAssertEqual(next.chat?.visibility, .team)
        XCTAssertEqual(next.chat?.agentData.allowAllTools, true)
        XCTAssertEqual(next.chat?.agentData.disableHooks, true)
        XCTAssertEqual(next.chat?.agentData.memory?.isEmpty, true)

        // Another chat's answer is ignored.
        let other = chatReducer(state, .mergeChatSettings(ChatSettingsDTO(chatId: "c2", visibility: .team, allowAllTools: true)))
        XCTAssertEqual(other.chat?.agentData.allowAllTools, false)
        XCTAssertEqual(other.chat?.name, "old")
    }

    func testEndpoints() async throws {
        var client = InferenceClient(apiKey: "k")
        client.transport = StubProtocol.start { req, _ in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/settings") {
                return .json(#"{"data":{"chat_id":"c1","name":"n","visibility":"private","allow_all_tools":true,"disable_hooks":false}}"#)
            }
            if path.hasSuffix("/always-allow/options") {
                return .json(#"{"data":{"options":[{"key":"o1","scope":"exact","label":"npm test on laptop","rules":[{"id":"","effect":"allow","enforcement":"default","kind":"RemoteExec","selector":"r1","specifier":"npm test","label":"npm test on laptop","created_by":""}]}],"default":"o1"}}"#)
            }
            if path.hasSuffix("/always-allow") {
                return .json(#"{"data":{"rules":[]}}"#)
            }
            if path.hasSuffix("/explain") {
                return .json(#"{"data":{"risk_level":"low","explanation":"runs the tests","reasoning":"","risk":"none"}}"#)
            }
            return .json(#"{"data":null}"#)
        }

        let settings = try await client.updateChatSettings(chatId: "c1", ChatSettingsRequest(allowAllTools: true))
        XCTAssertTrue(settings.allowAllTools)
        let options = try await client.getAlwaysAllowOptions(chatId: "c1", toolInvocationId: "t1")
        XCTAssertEqual(options.options?.first?.label, "npm test on laptop")
        XCTAssertEqual(options.default, "o1")
        try await client.alwaysAllowTool(chatId: "c1", toolInvocationId: "t1", option: "o1")
        try await client.alwaysAllowTool(chatId: "c1", toolInvocationId: "t1")
        let explained = try await client.explainTool(chatId: "c1", toolInvocationId: "t1")
        XCTAssertEqual(explained.riskLevel, .toolRiskLow)

        let r = StubProtocol.recorded
        XCTAssertEqual(r.map(\.path), ["/chats/c1/settings", "/chats/c1/tools/t1/always-allow/options",
                                       "/chats/c1/tools/t1/always-allow", "/chats/c1/tools/t1/always-allow",
                                       "/chats/c1/tools/t1/explain"])
        XCTAssertEqual(r.map { $0.request.httpMethod }, ["POST", "GET", "POST", "POST", "POST"])
        XCTAssertEqual(String(decoding: r[0].body, as: UTF8.self), #"{"allow_all_tools":true}"#)
        XCTAssertEqual(String(decoding: r[2].body, as: UTF8.self), #"{"option":"o1"}"#)
        XCTAssertEqual(String(decoding: r[3].body, as: UTF8.self), "{}")
    }

    /// A stale option (409) is thrown to the caller without marking the
    /// connection failed: the card reads the options again.
    @MainActor
    func testStaleOptionLeavesStateAlone() async throws {
        var client = InferenceClient(apiKey: "k")
        client.transport = StubProtocol.start { req, _ in
            if req.url?.path.hasSuffix("/always-allow") == true {
                return .init(status: 409, body: Data(#"{"title":"Conflict","detail":"the options changed"}"#.utf8))
            }
            return .init(status: 404, body: Data())
        }
        let session = AgentChatSession(client: client, agent: "a/b")
        session.setChatId("c1")
        do {
            try await session.alwaysAllowTool("t1", option: "stale")
            XCTFail("expected 409")
        } catch InferenceError.http(let status, _) {
            XCTAssertEqual(status, 409)
        }
        XCTAssertNil(session.state.error)
        session.reset()
    }
}
