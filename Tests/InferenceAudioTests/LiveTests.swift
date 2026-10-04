import Foundation
import InferenceAudio
import InferenceSDK
import XCTest

final class LiveTranscriptTests: XCTestCase {
    func testGrowWordByWord() {
        var t = LiveTranscript()
        t.apply("")
        XCTAssertTrue(t.isEmpty)
        t.apply("Remind me")
        XCTAssertEqual(t.settled, "")
        XCTAssertEqual(t.tail, "Remind me")
        t.apply("Remind me to send Charles.")
        XCTAssertEqual(t.settled, "Remind me")
        XCTAssertEqual(t.tail, "to send Charles.")
        t.apply("Remind me to send Charles the revised timeline.")
        XCTAssertEqual(t.settled, "Remind me to send")
        XCTAssertEqual(t.tail, "Charles the revised timeline.")
        XCTAssertEqual(t.patches, 4)
    }

    func testFullLineAtOnce() {
        var t = LiveTranscript()
        t.apply("Hey, Chief. Please book the room for Thursday at 10:00.")
        XCTAssertEqual(t.settled, "")
        t.apply("Hey, Chief. Please book the room for Thursday at 10:00. And send Charles")
        XCTAssertEqual(t.settled, "Hey, Chief. Please book the room for Thursday at 10:00.")
        XCTAssertEqual(t.tail, "And send Charles")
    }

    func testRevisedTail() {
        var t = LiveTranscript()
        t.apply("Please book the route")
        t.apply("Please book the room for Thursday")
        XCTAssertEqual(t.settled, "Please book the")
        XCTAssertEqual(t.tail, "room for Thursday")
        t.settle()
        XCTAssertEqual(t.settled, t.text)
        XCTAssertEqual(t.tail, "")
    }

    func testClear() {
        var t = LiveTranscript()
        t.apply("talked over")
        t.clear()
        XCTAssertTrue(t.isEmpty)
        t.apply("again")
        XCTAssertEqual(t.tail, "again")
    }

    func testFinalText() {
        var patch = LiveTranscript()
        patch.apply("Book the small room.")
        let xai: JSONValue = ["text": "Book the small room for the board prep.", "utterances": [["text": "x"]]]
        XCTAssertEqual(LiveTranscript.finalText(result: xai, lastPatch: patch), "Book the small room for the board prep.")
        let turns: JSONValue = ["text": "", "turns": [["text": "Hey chief."], ["text": " Book the room. "]]]
        XCTAssertEqual(LiveTranscript.finalText(result: turns, lastPatch: patch), "Hey chief. Book the room.")
        let segments: JSONValue = ["segments": [["text": "One."], ["text": "Two."]]]
        XCTAssertEqual(LiveTranscript.finalText(result: segments, lastPatch: patch), "One. Two.")
        let utterances: JSONValue = ["utterances": [["text": "Only this."]]]
        XCTAssertEqual(LiveTranscript.finalText(result: utterances, lastPatch: patch), "Only this.")
        XCTAssertEqual(LiveTranscript.finalText(result: nil, lastPatch: patch), "Book the small room.")
        XCTAssertEqual(LiveTranscript.finalText(result: ["text": ""], lastPatch: patch), "Book the small room.")
        XCTAssertNil(LiveTranscript.finalText(result: nil, lastPatch: LiveTranscript()))
    }
}

enum Fixtures {
    static func streamFunction(rate: Int) -> AppFunction {
        let props: [String: JSONValue] = [
            "audio": ["format": "stream", "type": "array",
                      "items": ["format": "binary", "type": "string",
                                "contentMediaType": .string("audio/pcm;format=s16le;rate=\(rate);channels=1")]],
            "silence_ms": ["type": "integer", "default": 700],
        ]
        return AppFunction(name: "realtime", inputSchema: ["type": "object", "properties": .object(props)],
                           outputSchema: ["type": "object", "properties": ["text": ["type": "string"], "end_reason": ["type": "string"]]],
                           kind: .stream)
    }

    static let runFunction = AppFunction(
        name: "run", inputSchema: ["type": "object", "properties": ["audio": ["type": "string", "format": "file"], "model": ["type": "string"]]],
        outputSchema: ["type": "object", "properties": ["text": ["type": "string"]]], kind: .run)

    /// A voice app: 16 kHz in, 24 kHz out, transcripts as patches.
    static let voiceInput: JSONValue = ["type": "object", "properties": [
        "audio": ["type": "array", "format": "stream",
                  "items": ["type": "string", "format": "binary", "contentMediaType": "audio/pcm;format=s16le;rate=16000;channels=1"]],
        "voice": ["type": "string"],
    ]]
    static let voiceOutput: JSONValue = ["type": "object", "properties": [
        "audio": ["type": "array", "format": "stream",
                  "items": ["type": "string", "format": "binary", "contentMediaType": "audio/pcm;format=s16le;rate=24000;channels=1"]],
        "user_text": ["type": "string"],
    ]]

    static let offline = InferenceClient(baseURL: URL(string: "https://fixture.invalid")!, apiKey: "x")
}

final class LiveSpeechPlanTests: XCTestCase {
    func testPicksTheStreamFunctionAndItsRate() throws {
        let plan = try XCTUnwrap(LiveSpeechPlan.make(
            app: "openai/gpt-transcribe", functions: ["run": Fixtures.runFunction, "realtime": Fixtures.streamFunction(rate: 24_000)],
            extraInput: ["silence_ms": 500, "model": "scribe_v1"]))
        XCTAssertEqual(plan.function, "realtime")
        XCTAssertEqual(plan.audioField, "audio")
        XCTAssertEqual(plan.sampleRate, 24_000)
        XCTAssertEqual(plan.textField, "text")
        XCTAssertEqual(plan.input, ["silence_ms": 500], "inputs the stream function lacks are dropped")
    }

    func testNoStreamFunction() {
        XCTAssertNil(LiveSpeechPlan.make(app: "infsh/fast-whisper-large-v3", functions: ["run": Fixtures.runFunction]))
    }
}

/// The paths that need no server: a take too short or silent, an app
/// without a stream function, a session that cannot connect.
final class LiveTranscriberTests: XCTestCase {
    func testTooShortIsDroppedAtOnce() async throws {
        let plans = LiveSpeechPlans()
        await plans.remember(nil, for: "x/stt", client: Fixtures.offline)
        let t = LiveTranscriber(client: Fixtures.offline, app: "x/stt", plans: plans)
        t.start()
        t.append(pcm(sine(1600)), sampleRate: 16_000)  // 0.1 s: shorter than the HFP channel takes to open
        XCTAssertEqual(t.current.elapsed, 0.1, accuracy: 0.001)
        XCTAssertGreaterThan(t.current.level, 0.5)
        let text = try await t.finish()
        XCTAssertEqual(text, "")
        XCTAssertEqual(t.current.phase, .ended)
    }

    func testSilenceIsDropped() async throws {
        let plans = LiveSpeechPlans()
        await plans.remember(nil, for: "x/stt", client: Fixtures.offline)
        let t = LiveTranscriber(client: Fixtures.offline, app: "x/stt", plans: plans)
        t.start()
        t.append(Data(count: 32_000), sampleRate: 16_000)
        let text = try await t.finish()
        XCTAssertEqual(text, "")
    }

    func testNoStreamFunctionRecordsAndFallsBack() async throws {
        let plans = LiveSpeechPlans()
        await plans.remember(nil, for: "x/stt", client: Fixtures.offline)
        let t = LiveTranscriber(client: Fixtures.offline, app: "x/stt", plans: plans)
        t.start()
        await eventually("resolved") { t.current.phase == .recording }
        t.append(pcm(sine(16_000)), sampleRate: 16_000)
        // The fallback runs SpeechToText, which cannot reach the fixture host.
        do {
            _ = try await t.finish()
            XCTFail("expected the batch transcription to fail")
        } catch {
            if case .failed = t.current.phase {} else { XCTFail("phase \(t.current.phase)") }
        }
    }

    func testFailedSessionWithoutFallbackEndsQuickly() async throws {
        let plans = LiveSpeechPlans()
        let plan = LiveSpeechPlan.make(app: "x/stt", functions: ["realtime": Fixtures.streamFunction(rate: 24_000)])
        await plans.remember(plan, for: "x/stt", client: Fixtures.offline)
        let t = LiveTranscriber(client: Fixtures.offline, app: "x/stt", plans: plans)
        t.fallbackToBatch = false
        t.liveWait = 1
        let source = ManualSource()
        try await t.start(source: source)
        XCTAssertEqual(source.formats.value, [.speech], "capture starts at 16 kHz, before the app is known")
        for _ in 0..<25 { source.feed(pcm(sine(320))) }
        let started = Date()
        let text = try await t.finish()
        XCTAssertEqual(text, "")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(source.stops.value, 1)
        XCTAssertEqual(t.current.elapsed, 0.5, accuracy: 0.001)
    }

    func testCancelIsFinal() async throws {
        let t = LiveTranscriber(client: Fixtures.offline, app: "")
        t.start()
        t.cancel()
        t.append(pcm(sine(16_000)), sampleRate: 16_000)
        XCTAssertEqual(t.current.elapsed, 0)
        var last: LiveTranscriber.Snapshot?
        for await s in t.updates { last = s }
        XCTAssertEqual(last?.phase, .ended)
    }
}

final class LiveVoiceCallTests: XCTestCase {
    func testWiresSourceAndSinkToTheSession() async throws {
        let socket = FakeSocket()
        let session = LiveSession(access: SocketAccess(id: "s", url: "wss://relay.test/s", token: "t", expiresAt: ""),
                                  dial: { _ in socket })
        let source = ManualSource()
        let speaker = CollectingSink()
        let call = LiveVoiceCall(session: session, input: source, output: speaker,
                                 inputSchema: Fixtures.voiceInput, outputSchema: Fixtures.voiceOutput)
        XCTAssertEqual(call.inputFormat, PCMFormat(sampleRate: 16_000, channels: 1))
        XCTAssertEqual(call.outputFormat, PCMFormat(sampleRate: 24_000, channels: 1))
        let seen = Locked<[LiveEvent]>([])
        let reader = Task { for await event in call.events { seen.mutate { $0.append(event) } } }
        session.connect()
        socket.open()
        await eventually("waiting") { session.state == .waiting }
        XCTAssertTrue(source.formats.value.isEmpty, "the microphone waits for the app")

        socket.message(Data([1, 0, 2, 0]))  // the app's first frame: live
        await eventually("mic started") { source.formats.value == [PCMFormat(sampleRate: 16_000, channels: 1)] }
        XCTAssertEqual(speaker.log.value, ["start 24000"])
        XCTAssertEqual(speaker.played.value, [Data([1, 0, 2, 0])])

        source.feed(pcm(sine(320)))  // speech: sent
        source.feed(Data(count: 640))  // the pause after it: sent too
        await eventually("frames sent") { socket.sent.count == 2 }
        call.isMuted = true
        source.feed(pcm(sine(320)))
        try await Task.sleep(nanoseconds: 100_000_000)
        call.isMuted = false

        socket.message(#"{"$clear":"audio"}"#)
        socket.message(#"{"user_text":"hi"}"#)
        await eventually("flushed") { speaker.log.value.contains("flush") }
        await eventually("patch passed on") { seen.value.contains(.patch(["user_text": "hi"])) }
        XCTAssertEqual(socket.sent.count, 2, "nothing sent while muted")
        XCTAssertEqual(call.counts.sent.frames, 2)
        XCTAssertEqual(call.counts.received.frames, 1)

        call.hangUp()
        let end = await call.ended
        XCTAssertTrue(end.byCaller)
        await eventually("audio stopped") { speaker.log.value.last == "stop" && source.stops.value == 1 }
        _ = await reader.value
        XCTAssertEqual(seen.value.first, .state(.connecting))
        if case .state(.ended) = seen.value.last {} else { XCTFail("last event \(String(describing: seen.value.last))") }
    }

    func testGateHoldsBackSilence() async throws {
        let socket = FakeSocket()
        let session = LiveSession(access: SocketAccess(id: "s", url: "wss://relay.test/s", token: "t", expiresAt: ""),
                                  dial: { _ in socket })
        let source = ManualSource()
        let call = LiveVoiceCall(session: session, input: source, output: nil,
                                 inputSchema: Fixtures.voiceInput, outputSchema: Fixtures.voiceOutput)
        session.connect()
        socket.open()
        socket.message(#"{"user_text":""}"#)
        await eventually("mic started") { !source.formats.value.isEmpty }
        for _ in 0..<5 { source.feed(Data(count: 640)) }
        source.feed(pcm(sine(320)))
        await eventually("speech sent") { socket.sent.count == 1 }
        XCTAssertEqual(call.counts.sent.frames, 1, "silence before any sound stays home")
        call.hangUp()
    }
}
