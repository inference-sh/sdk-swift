import Foundation
import XCTest
@testable import InferenceSDK

/// X-Client-Source names the app the requests come from (go/api
/// httputils.ClientName): the SDK's own name until the app sets its own.
final class ClientSourceTests: XCTestCase {
    func testSentOnEveryRequest() async throws {
        var client = InferenceClient(apiKey: "k")
        client.transport = StubProtocol.start { _, _ in
            .json(#"{"data":{"chat_id":"c1","name":"n","visibility":"private","allow_all_tools":true,"disable_hooks":false}}"#)
        }
        _ = try await client.updateChatSettings(chatId: "c1", ChatSettingsRequest(allowAllTools: true))
        client.clientSource = "mac/1.4.0"
        _ = try await client.updateChatSettings(chatId: "c1", ChatSettingsRequest(allowAllTools: true))

        XCTAssertEqual(StubProtocol.recorded.map { $0.request.value(forHTTPHeaderField: "X-Client-Source") },
                       ["inference-sdk-swift", "mac/1.4.0"])
    }
}
