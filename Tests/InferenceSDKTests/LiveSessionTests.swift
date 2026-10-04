import XCTest
@testable import InferenceSDK

/// Port of js/sdk-js/src/live/session.test.ts, on a fake socket.
final class LiveSessionTests: XCTestCase {
    private func start(renew: LiveSession.Renew? = nil, task: LiveSession.TaskWatch? = nil,
                       inputSchema: JSONValue? = nil, outputSchema: JSONValue? = nil)
        -> (session: LiveSession, log: EventLog, relay: FakeRelay) {
        let relay = FakeRelay()
        let session = LiveSession(access: socketAccess(), renew: renew, task: task, dial: relay.dial,
                                  inputSchema: inputSchema, outputSchema: outputSchema)
        let log = EventLog(session)
        session.connect()
        return (session, log, relay)
    }

    /// A session whose socket the relay has accepted.
    private func open(inputSchema: JSONValue? = nil, outputSchema: JSONValue? = nil) async
        -> (session: LiveSession, log: EventLog, ws: FakeSocket) {
        let (session, log, relay) = start(inputSchema: inputSchema, outputSchema: outputSchema)
        relay.last.open()
        await eventually("waiting") { session.state == .waiting }
        return (session, log, relay.last)
    }

    func testDialsWithABearerCredentialAndGoesWaitingThenLiveOnTheFirstFrame() async {
        let (session, log, relay) = start()
        let ws = relay.last
        XCTAssertEqual(ws.url, "wss://relay.test/sockets/sock-1")
        XCTAssertEqual(ws.authorization, "Bearer tok-1")
        XCTAssertEqual(session.state, .connecting)
        XCTAssertFalse(session.isOpen)

        ws.open()
        await eventually("waiting") { session.state == .waiting }
        XCTAssertTrue(session.isOpen)

        ws.message(#"{"effect":"robot"}"#)
        let pcm = Data(count: 8)
        ws.message(pcm)
        ws.message("not json")
        await eventually("three frames") { log.frames.count == 3 }
        XCTAssertEqual(session.state, .live)
        XCTAssertEqual(log.frames, [.patch(["effect": "robot"]), .binary(pcm), .text("not json")])
        XCTAssertEqual(log.states, [.connecting, .waiting, .live])
    }

    func testSendsOnlyWhileOpen() async {
        let (session, _, relay) = start()
        let ws = relay.last
        XCTAssertFalse(session.sendPatch(["voice": "eve"]))
        XCTAssertEqual(ws.sent, [])

        ws.open()
        await eventually("waiting") { session.isOpen }
        let frame = Data([1, 2, 3])
        XCTAssertTrue(session.sendBinary(frame))
        XCTAssertTrue(session.sendPatch(["voice": "eve"]))
        XCTAssertTrue(session.sendText("hello"))
        XCTAssertEqual(ws.sent, [.binary(frame), .text(#"{"voice":"eve"}"#), .text("hello")])
    }

    func testDialsAgainWithAFreshCredentialWhenTheRelayDropsItBeforeTheAppCame() async {
        let renewals = Recorder<Int>()
        let (session, log, relay) = start(renew: {
            renewals.append(1)
            return socketAccess(2)
        })
        relay.last.open()
        relay.last.serverClose(1012, "restarting")
        await eventually("second dial") { relay.dialed.count == 2 }
        XCTAssertEqual(renewals.values.count, 1)
        XCTAssertEqual(relay.last.authorization, "Bearer tok-2")
        XCTAssertEqual(session.state, .connecting)

        relay.last.open()
        relay.last.message("{}")
        await eventually("live") { session.state == .live }
        XCTAssertEqual(log.ends, [])
        XCTAssertEqual(log.states, [.connecting, .waiting, .connecting, .waiting, .live])
    }

    func testRedialsWithTheSameCredentialWithoutRenew() async {
        let (session, log, relay) = start()
        relay.last.open()
        relay.last.serverClose(1012, "restarting")
        await eventually("second dial") { relay.dialed.count == 2 }
        XCTAssertEqual(relay.dialed[0].url, relay.dialed[1].url)
        XCTAssertEqual(relay.last.authorization, "Bearer tok-1")

        relay.last.open()
        relay.last.message("{}")
        await eventually("live") { session.state == .live }
        XCTAssertEqual(log.ends, [])
    }

    func testDoesNotDialAgainOnceFramesHaveFlowed() async {
        let (session, log, relay) = start(renew: { socketAccess(2) })
        relay.last.open()
        relay.last.message("{}")
        relay.last.serverClose(1012, "restarting")
        let end = await session.ended
        XCTAssertEqual(end, LiveEnd(code: 1012, reason: "restarting", byCaller: false, taskEnded: false))
        XCTAssertEqual(session.state, .ended(end))
        await settle()
        XCTAssertEqual(relay.dialed.count, 1)
        XCTAssertEqual(log.ends, [end])
    }

    func testGivesUpAfterFiveRedials() async {
        let (session, _, relay) = start(renew: { socketAccess() })
        for i in 0..<6 {
            await eventually("dial \(i + 1)") { relay.dialed.count == i + 1 }
            relay.dialed[i].open()
            relay.dialed[i].serverClose(1013, "peer did not come")
        }
        let end = await session.ended
        XCTAssertEqual(end.code, 1013)
        XCTAssertEqual(relay.dialed.count, 6)
    }

    func testEndsWhenARedialCannotRenew() async {
        let (session, _, relay) = start(renew: { throw InferenceError.http(status: 404, body: #"{"detail":"socket not found"}"#) })
        relay.last.open()
        relay.last.serverClose(1012, "restarting")
        let end = await session.ended
        XCTAssertEqual(end, LiveEnd(code: 1006, reason: "HTTP 404: socket not found", byCaller: false, taskEnded: false))
        XCTAssertEqual(relay.dialed.count, 1)
    }

    func testEndsWhenTheCallerClosesAndReportsItAsSuch() async {
        let (session, log, ws) = await open()
        session.close()
        XCTAssertEqual(ws.closedWith, ["1000 done"])
        let end = LiveEnd(code: 1000, reason: "done", byCaller: true, taskEnded: false)
        XCTAssertEqual(session.state, .ended(end))
        XCTAssertFalse(session.isOpen)
        XCTAssertFalse(session.sendBinary(Data([1])))

        // The socket's own close report must not end the session a second time.
        ws.serverClose(1000, "done")
        await eventually("events end") { log.isFinished }
        XCTAssertEqual(log.ends, [end])
        session.close()
        XCTAssertEqual(ws.closedWith, ["1000 done"])
    }

    func testEndsWithoutARedialWhenTheCallerClosesBeforeTheSocketOpened() async {
        let (session, _, relay) = start(renew: { socketAccess(2) })
        session.close()
        relay.last.serverClose(1012, "")
        await settle()
        let end = await session.ended
        XCTAssertTrue(end.byCaller)
        XCTAssertEqual(relay.dialed.count, 1)
        XCTAssertEqual(relay.last.closedWith, ["1000 done"])
    }

    func testEndsWith1006WhenTheDialFails() async {
        let (session, log, relay) = start()
        relay.last.serverClose(1006, "the relay refused the connection: HTTP 401")
        let end = await session.ended
        XCTAssertEqual(end, LiveEnd(code: 1006, reason: "the relay refused the connection: HTTP 401", byCaller: false, taskEnded: false))
        await eventually("events end") { log.isFinished }
        XCTAssertEqual(log.states, [.connecting, .ended(end)])
    }

    func testEndsWhenTheAccessHasNoURL() async {
        let relay = FakeRelay()
        let session = LiveSession(access: SocketAccess(id: "s", url: "", token: "t"), dial: relay.dial)
        session.connect()
        let end = await session.ended
        XCTAssertEqual(end.code, 1006)
        XCTAssertEqual(relay.dialed.count, 0)
    }

    func testGivesUpWaitingWhenTheTaskFailsBeforeTheAppConnected() async {
        let (fail, failed) = AsyncStream.makeStream(of: Void.self)
        let (session, log, relay) = start(task: {
            for await _ in fail { break }
            throw TaskRunError.failed(#"function "stream" failed: no module named x"#)
        })
        let ws = relay.last
        ws.open()
        await eventually("waiting") { session.state == .waiting }
        failed.yield()
        let end = await session.ended
        XCTAssertEqual(end, LiveEnd(code: 1000, reason: #"function "stream" failed: no module named x"#, byCaller: false, taskEnded: true))
        XCTAssertEqual(ws.closedWith, ["1000 task ended"])

        // The socket's own close report must not end the session a second time.
        ws.serverClose(1000, "task ended")
        await eventually("events end") { log.isFinished }
        XCTAssertEqual(log.ends, [end])
    }

    func testGivesUpWaitingWhenTheTaskCompletesBeforeTheAppConnected() async {
        let (session, _, relay) = start(task: {})
        relay.last.open()
        let end = await session.ended
        XCTAssertEqual(end, LiveEnd(code: 1000, reason: "the task ended before the app connected", byCaller: false, taskEnded: true))
    }

    func testStopsFollowingTheTaskOnceTheAppIsThere() async {
        let watch = Recorder<String>()
        let (session, _, relay) = start(task: {
            watch.append("started")
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                watch.append("cancelled")
                throw error
            }
        })
        relay.last.open()
        await eventually("watch started") { watch.values == ["started"] }
        relay.last.message("{}")
        await eventually("watch cancelled") { watch.values == ["started", "cancelled"] }
        await settle()
        XCTAssertEqual(session.state, .live)
    }

    func testKeepsWaitingWhenTheWatchItselfBreaks() async {
        let watch = Recorder<String>()
        let (session, _, relay) = start(task: {
            watch.append("broke")
            throw InferenceError.transport("network connection lost")
        })
        relay.last.open()
        await eventually("watch ran") { watch.values == ["broke"] }
        await settle()
        XCTAssertEqual(session.state, .waiting)
        session.close()
    }

    func testWatchesTheTaskOnceAcrossRedials() async {
        let watches = Recorder<Int>()
        let (session, _, relay) = start(task: {
            watches.append(1)
            try await Task.sleep(for: .seconds(60))
        })
        relay.last.open()
        relay.last.serverClose(1012, "restarting")
        await eventually("second dial") { relay.dialed.count == 2 }
        await settle()
        XCTAssertEqual(watches.values.count, 1)
        session.close()
    }

    func testReleasingTheSessionClosesItsSocket() async {
        let relay = FakeRelay()
        var session: LiveSession? = LiveSession(access: socketAccess(), dial: relay.dial)
        let log = EventLog(session!)
        session?.connect()
        let ws = relay.last
        ws.open()
        await eventually("waiting") { log.states.last == .waiting }
        session = nil
        await eventually("socket closed") { ws.closedWith == ["1000 done"] }
        await eventually("events end") { log.isFinished }
    }

    // MARK: - The clear control frame

    func testClearIsItsOwnEventAndTheRestOfThePatchFollows() async {
        let (session, log, ws) = await open()
        ws.message(#"{"$clear":"audio"}"#)
        ws.message(#"{"$clear":"audio","assistant_text":""}"#)
        await eventually("three frames") { log.frames.count == 3 }
        XCTAssertEqual(log.frames, [.clear(field: "audio"), .clear(field: "audio"), .patch(["assistant_text": ""])])
        session.close()
    }

    func testANonStringClearStaysInThePatch() async {
        let (session, log, ws) = await open()
        ws.message(#"{"$clear":["audio"]}"#)
        await eventually("one frame") { log.frames.count == 1 }
        XCTAssertEqual(log.frames, [.patch(["$clear": ["audio"]])])
        session.close()
    }

    // MARK: - Text, errors and fields

    func testTextThatIsNotAPatchArrivesAsTheAppSentIt() async {
        let (session, log, ws) = await open()
        ws.message("hello")
        ws.message("[1, 2]")
        await eventually("two frames") { log.frames.count == 2 }
        XCTAssertEqual(log.frames, [.text("hello"), .text("[1, 2]")])
        session.close()
    }

    func testErrorsAreTheirOwnEventAndTheRestOfThePatchFollows() async {
        let (session, log, ws) = await open()
        ws.message(#"{"$error":{"field":"speed","message":"too fast"},"voice":"eve"}"#)
        ws.message(#"{"error":{"field":null,"message":"from an older app"}}"#)
        ws.message(#"{"$error":"plain"}"#)
        await eventually("four frames") { log.frames.count == 4 }
        XCTAssertEqual(log.frames, [
            .error(field: "speed", message: "too fast"),
            .patch(["voice": "eve"]),
            .error(field: nil, message: "from an older app"),
            .error(field: nil, message: "plain"),
        ])
        session.close()
    }

    func testLeavesAnOutputFieldNamedErrorAlone() async {
        let (session, log, ws) = await open(outputSchema: ["type": "object", "properties": ["error": ["type": "object"]]])
        ws.message(#"{"error":{"message":"a value"}}"#)
        await eventually("one frame") { log.frames.count == 1 }
        XCTAssertEqual(log.frames, [.patch(["error": ["message": "a value"]])])
        session.close()
    }

    func testALegacyErrorObjectWithoutAMessageIsAPatch() async {
        let (session, log, ws) = await open()
        ws.message(#"{"error":{"field":"speed"}}"#)
        await eventually("one frame") { log.frames.count == 1 }
        XCTAssertEqual(log.frames, [.patch(["error": ["field": "speed"]])])
        session.close()
    }

    func testStringifiesNonStringErrorMessages() async {
        let (session, log, ws) = await open()
        ws.message(#"{"$error":{"message":{"code":1}}}"#)
        ws.message(#"{"error":{"message":42}}"#)
        await eventually("two frames") { log.frames.count == 2 }
        XCTAssertEqual(log.frames, [
            .error(field: nil, message: #"{"message":{"code":1}}"#),
            .error(field: nil, message: #"{"message":42}"#),
        ])
        session.close()
    }

    func testACanonicalErrorLeavesACoexistingErrorKeyOnThePatch() async {
        let (session, log, ws) = await open()
        ws.message(#"{"$error":{"message":"canonical"},"error":{"message":"legacy"}}"#)
        await eventually("two frames") { log.frames.count == 2 }
        XCTAssertEqual(log.frames, [.error(field: nil, message: "canonical"), .patch(["error": ["message": "legacy"]])])
        session.close()
    }

    func testDeliversAnEmptyPatchItIsStillTheAppSayingItIsThere() async {
        let (session, log, ws) = await open()
        ws.message("{}")
        ws.message(#"{"$clear":"audio"}"#)
        await eventually("two frames") { log.frames.count == 2 }
        XCTAssertEqual(log.frames, [.patch([:]), .clear(field: "audio")])
        XCTAssertEqual(session.state, .live)
    }

    private let pcm: JSONValue = [
        "type": "array", "format": "stream",
        "items": ["type": "string", "format": "binary", "contentMediaType": "audio/pcm;rate=24000"],
    ]

    func testWithTheOutputSchemaMapsEventsToFields() async {
        let (session, _, _) = await open(outputSchema: ["type": "object", "properties": ["audio": pcm, "user_text": ["type": "string"]]])
        let frame = Data(count: 2)
        XCTAssertEqual(session.updates(for: .binary(frame)), [LiveUpdate(field: "audio", value: .binary(frame))])
        XCTAssertEqual(session.updates(for: .patch(["user_text": "hi", "done": true])), [
            LiveUpdate(field: "done", value: .json(true)),
            LiveUpdate(field: "user_text", value: .json("hi")),
        ])
        XCTAssertEqual(session.updates(for: .clear(field: "audio")), [])

        // Without the schema a binary frame has no field to belong to.
        let (bare, _, _) = await open()
        XCTAssertEqual(bare.updates(for: .binary(frame)), [])
    }

    func testWithTheInputSchemaSendFieldSendsBinaryOrJSONAsTheFieldRequires() async throws {
        let (session, _, ws) = await open(inputSchema: ["type": "object", "properties": ["audio": pcm, "voice": ["type": "string"]]])
        let frame = Data([9])
        try session.sendField("audio", .binary(frame))
        try session.sendField("voice", .json("ara"))
        XCTAssertEqual(ws.sent, [.binary(frame), .text(#"{"voice":"ara"}"#)])

        XCTAssertThrowsError(try session.sendField("voice", .binary(frame))) {
            XCTAssertEqual($0 as? LiveSessionError, .notBinary(field: "voice"))
        }
        XCTAssertThrowsError(try session.sendField("audio", .json("x"))) {
            XCTAssertEqual($0 as? LiveSessionError, .binaryOnly(field: "audio"))
        }
        let (bare, _, _) = await open()
        XCTAssertThrowsError(try bare.sendField("voice", .json("ara"))) {
            XCTAssertEqual($0 as? LiveSessionError, .inputSchemaRequired)
        }
    }

    func testPatchesEncodeNestedValues() async {
        let (session, _, ws) = await open()
        session.sendPatch(["events": ["type": "text", "text": "a/b \"q\""], "speed": 1.5, "rate": 24000, "on": true, "none": nil])
        XCTAssertEqual(ws.sent, [.text(#"{"events":{"text":"a/b \"q\"","type":"text"},"none":null,"on":true,"rate":24000,"speed":1.5}"#)])
    }
}
