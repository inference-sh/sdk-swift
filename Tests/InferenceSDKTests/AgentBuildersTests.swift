import Foundation
import XCTest
@testable import InferenceSDK

/// internalTools(), lifecycleHook() and learningHooks(): ports of sdk-js
/// src/tool-builder.test.ts (InternalToolsBuilder) and src/hook-builder.test.ts.
final class AgentBuildersTests: XCTestCase {
    /// The wire JSON, so unset fields are checked as absent (JS toEqual).
    private func json<T: Encodable>(_ value: T) throws -> NSDictionary {
        let data = try InferenceClient.encoder.encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    // MARK: InternalToolsBuilder

    func testInternalToolsEmptyByDefault() throws {
        XCTAssertEqual(try json(internalTools().build()), [:])
    }

    func testInternalToolsSingleCategories() throws {
        XCTAssertEqual(try json(internalTools().plan().build()), ["plan": true])
        XCTAssertEqual(try json(internalTools().memory().build()), ["memory": true])
        XCTAssertEqual(try json(internalTools().widget().build()), ["widget": true])
        XCTAssertEqual(try json(internalTools().finish().build()), ["finish": true])
        XCTAssertEqual(try json(internalTools().meta().build()), ["meta": true])
        XCTAssertEqual(try json(internalTools().remote().build()), ["remote": true])
        XCTAssertEqual(try json(internalTools().remote(false).build()), ["remote": false])
        XCTAssertEqual(try json(internalTools().knowledge().build()), ["knowledge": true])
    }

    func testAllLeavesOptInCategoriesUnset() {
        let config = internalTools().all().build()
        XCTAssertNil(config.remote)
        XCTAssertNil(config.knowledge)
    }

    func testRemainingOptInCategories() throws {
        let config = internalTools().skills(false).artifact().agent().build()
        XCTAssertEqual(try json(config), ["skills": false, "artifact": true, "agent": true])
    }

    func testChainsEnables() throws {
        XCTAssertEqual(try json(internalTools().plan().memory().widget().build()),
                       ["plan": true, "memory": true, "widget": true])
    }

    func testAllAndNone() throws {
        XCTAssertEqual(try json(internalTools().all().build()),
                       ["plan": true, "memory": true, "widget": true, "finish": true])
        XCTAssertEqual(try json(internalTools().none().build()),
                       ["plan": false, "memory": false, "widget": false, "finish": false])
    }

    func testExplicitDisable() throws {
        XCTAssertEqual(try json(internalTools().plan(false).memory(true).build()),
                       ["plan": false, "memory": true])
    }

    // MARK: LifecycleHookBuilder

    func testWebhookHook() throws {
        let hook = lifecycleHook(.agentStart).webhook("https://example.com/hook").build()
        XCTAssertEqual(try json(hook), ["event": "agent.start", "type": "webhook", "handler": "https://example.com/hook"])
    }

    func testTaskHook() {
        let hook = lifecycleHook(.turnComplete).task("acme/validator@v1").build()
        XCTAssertEqual(hook.type, .hookHandlerTask)
        XCTAssertEqual(hook.handler, "acme/validator@v1")
    }

    func testAsyncAndTimeout() {
        let hook = lifecycleHook(.agentStart).webhook("https://example.com/hook").async(true).timeout(30).build()
        XCTAssertEqual(hook.async, true)
        XCTAssertEqual(hook.timeout, 30)
    }

    func testDefaultsToWebhook() {
        XCTAssertEqual(lifecycleHook(.agentStart).build().type, .hookHandlerWebhook)
    }

    /// The JS builder returns itself from each setter; the Swift one is a
    /// value, so a base can be reused without the copies seeing each other.
    func testBuilderIsAValue() {
        let base = lifecycleHook(.agentStart).webhook("https://example.com")
        let task = base.task("acme/agent@v1")
        XCTAssertEqual(base.build().type, .hookHandlerWebhook)
        XCTAssertEqual(task.build().type, .hookHandlerTask)
    }

    func testBuiltinHook() throws {
        let hook = lifecycleHook(.turnStart).builtin(.beltSuggest).build()
        XCTAssertEqual(try json(hook), ["event": "agent.turn_start", "type": "builtin", "handler": "belt:suggest"])
    }

    // MARK: learningHooks

    func testLearningHooksNoneOn() {
        XCTAssertTrue(learningHooks().isEmpty)
    }

    func testLearningHooksAttachToTheirEvents() {
        let hooks = learningHooks(suggest: true, learn: true)
        XCTAssertEqual(hooks.map(\.event), [.turnStart, .agentComplete, .preCompact])
        XCTAssertEqual(hooks.map(\.type), [.hookHandlerBuiltin, .hookHandlerBuiltin, .hookHandlerBuiltin])
        XCTAssertEqual(hooks.map(\.handler), ["belt:suggest", "belt:extract", "belt:extract"])
    }
}
