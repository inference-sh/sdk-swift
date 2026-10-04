import XCTest
@testable import InferenceSDK

/// Port of js/sdk-js/src/live/schema.test.ts. Property order is by key here
/// (JSONValue keeps none), so expectations that list fields are sorted.
final class LiveSchemaTests: XCTestCase {
    // What pydantic emits for voice-loop-like models (inferencesh >= 0.8.1).
    private let talkInput: JSONValue = [
        "type": "object",
        "$defs": [
            "Interrupt": ["type": "object", "title": "Interrupt", "properties": ["type": ["const": "interrupt", "type": "string"]]],
            "UserText": [
                "type": "object",
                "title": "UserText",
                "required": ["text"],
                "properties": ["type": ["const": "text", "type": "string"], "text": ["type": "string"]],
            ],
        ],
        "required": ["voice"],
        "properties": [
            "voice": ["type": "string", "default": "ara"],
            "audio": [
                "type": "array",
                "format": "stream",
                "title": "Audio",
                "description": "Microphone audio",
                "items": ["type": "string", "format": "binary", "contentMediaType": "audio/pcm;format=s16le;rate=16000;channels=1"],
            ],
            "events": [
                "type": "array",
                "format": "stream",
                "items": ["anyOf": [["$ref": "#/$defs/Interrupt"], ["$ref": "#/$defs/UserText"]]],
            ],
        ],
    ]

    func testProtocolConstants() {
        XCTAssertEqual(LiveProtocol.clearKey, "$clear")
        XCTAssertEqual(LiveProtocol.errorKey, "$error")
        XCTAssertEqual(LiveProtocol.streamFormat, "stream")
        XCTAssertEqual(LiveProtocol.redialCodes, [1012, 1013])
    }

    func testSeparatesWhatAFormRendersFromWhatTheSocketCarries() throws {
        let (ordinary, live) = splitLiveSchema(talkInput)
        XCTAssertEqual(ordinary?["properties"]?.objectValue.map { Array($0.keys) }, ["voice"])
        XCTAssertEqual(ordinary?["required"], ["voice"])
        XCTAssertEqual(live.map(\.key), ["audio", "events"])
    }

    func testDropsLiveFieldsFromRequired() {
        let schema: JSONValue = [
            "type": "object",
            "required": ["audio", "voice"],
            "properties": ["voice": ["type": "string"], "audio": ["type": "array", "format": "stream"]],
        ]
        XCTAssertEqual(splitLiveSchema(schema).ordinary?["required"], ["voice"])
    }

    func testDescribesABinaryFieldByItsMediaType() throws {
        let audio = try XCTUnwrap(binaryLiveField(splitLiveSchema(talkInput).live))
        XCTAssertEqual(audio.key, "audio")
        XCTAssertEqual(audio.title, "Audio")
        XCTAssertEqual(audio.description, "Microphone audio")
        XCTAssertTrue(audio.binary)
        XCTAssertEqual(pcmFormat(audio.media), PCMFormat(sampleRate: 16000, channels: 1))
        XCTAssertEqual(audio.alternatives, [])
    }

    func testResolvesTheAlternativesOfAJSONFieldThroughDefs() {
        let events = splitLiveSchema(talkInput).live[1]
        XCTAssertFalse(events.binary)
        XCTAssertEqual(events.title, "events")
        XCTAssertEqual(events.alternatives.enumerated().map { alternativeLabel($1, index: $0) }, ["interrupt", "text"])
        XCTAssertEqual(events.alternatives[1]["required"], ["text"])
        // No top-level $ref: a validator ignores its siblings.
        XCTAssertTrue(events.alternatives.allSatisfy { $0["$ref"] == nil })
        // Nested references still resolve: the root's $defs travel with each alternative.
        XCTAssertTrue(events.alternatives.allSatisfy { $0["$defs"] == talkInput["$defs"] })
    }

    func testKeepsNestedRefsOnAnAlternative() {
        let schema: JSONValue = [
            "type": "object",
            "$defs": [
                "Tag": ["type": "string", "const": "a"],
                "Message": ["type": "object", "properties": ["tag": ["$ref": "#/$defs/Tag"]]],
            ],
            "properties": [
                "events": ["type": "array", "format": "stream", "items": ["anyOf": [["$ref": "#/$defs/Message"]]]],
            ],
        ]
        let message = splitLiveSchema(schema).live[0].alternatives[0]
        XCTAssertEqual(message["$defs"], schema["$defs"])
        XCTAssertEqual(message["properties"]?["tag"], ["$ref": "#/$defs/Tag"])
        XCTAssertNil(message["$ref"])
    }

    func testLeavesASchemaWithoutLiveFieldsAlone() {
        let plain: JSONValue = ["type": "object", "properties": ["prompt": ["type": "string"]], "required": ["prompt"]]
        let (ordinary, live) = splitLiveSchema(plain)
        XCTAssertEqual(live, [])
        XCTAssertEqual(ordinary, plain)

        XCTAssertNil(splitLiveSchema(nil).ordinary)
        XCTAssertEqual(splitLiveSchema(nil).live, [])
        XCTAssertNil(splitLiveSchema(.null).ordinary)
        // No properties: handed back as it came.
        XCTAssertEqual(splitLiveSchema(["type": "object"]).ordinary, ["type": "object"])
    }

    func testLabelsAnAlternativeByItsConstElseTitleElsePosition() {
        XCTAssertEqual(alternativeLabel(["title": "Word"], index: 0), "Word")
        XCTAssertEqual(alternativeLabel([:], index: 2), "option 3")
        XCTAssertFalse(isLiveField(["format": "file"]))
        XCTAssertTrue(isLiveField(["format": "stream"]))
        XCTAssertFalse(isLiveField(nil))
    }

    func testResolvesOneOfRefAlternatives() {
        let schema: JSONValue = [
            "type": "object",
            "$defs": [
                "Ping": ["type": "object", "title": "Ping", "properties": ["type": ["const": "ping", "type": "string"]]],
                "Pong": ["type": "object", "title": "Pong", "properties": ["type": ["const": "pong", "type": "string"]]],
            ],
            "properties": [
                "events": ["type": "array", "format": "stream", "items": ["oneOf": [["$ref": "#/$defs/Ping"], ["$ref": "#/$defs/Pong"]]]],
            ],
        ]
        let events = splitLiveSchema(schema).live[0]
        XCTAssertEqual(events.alternatives.enumerated().map { alternativeLabel($1, index: $0) }, ["ping", "pong"])
        XCTAssertTrue(events.alternatives.allSatisfy { $0["$ref"] == nil })
    }

    func testFieldsOnARefOverrideTheTarget() {
        let schema: JSONValue = [
            "type": "object",
            "$defs": ["Base": ["type": "object", "title": "FromDef", "description": "from def"]],
            "properties": [
                "events": [
                    "type": "array",
                    "format": "stream",
                    "items": ["anyOf": [["$ref": "#/$defs/Base", "title": "Overlay", "description": "from ref"]]],
                ],
            ],
        ]
        let alternative = splitLiveSchema(schema).live[0].alternatives[0]
        XCTAssertEqual(alternative["title"], "Overlay")
        XCTAssertEqual(alternative["description"], "from ref")
        XCTAssertEqual(alternative["type"], "object")
        XCTAssertNil(alternative["$ref"])
    }

    func testFollowsNestedDefsReferences() {
        let schema: JSONValue = [
            "type": "object",
            "$defs": [
                "Outer": ["$ref": "#/$defs/Inner", "title": "Outer"],
                "Inner": ["type": "object", "properties": ["value": ["type": "string"]]],
            ],
            "properties": ["payload": ["type": "array", "format": "stream", "items": ["$ref": "#/$defs/Outer"]]],
        ]
        let alternative = splitLiveSchema(schema).live[0].alternatives[0]
        XCTAssertEqual(alternative["title"], "Outer")
        XCTAssertEqual(alternative["properties"]?["value"], ["type": "string"])
        XCTAssertNil(alternative["$ref"])
    }

    func testAReferenceToItselfStopsResolving() {
        let schema: JSONValue = [
            "type": "object",
            "$defs": ["Loop": ["$ref": "#/$defs/Loop"]],
            "properties": ["payload": ["type": "array", "format": "stream", "items": ["$ref": "#/$defs/Loop"]]],
        ]
        XCTAssertEqual(splitLiveSchema(schema).live.map(\.key), ["payload"])
    }

    func testABinaryFieldBehindARef() throws {
        let schema: JSONValue = [
            "type": "object",
            "$defs": ["PCM": ["type": "string", "format": "binary", "contentMediaType": "audio/pcm;rate=24000"]],
            "properties": ["audio": ["type": "array", "format": "stream", "items": ["$ref": "#/$defs/PCM"]]],
        ]
        let audio = try XCTUnwrap(binaryLiveField(splitLiveSchema(schema).live))
        XCTAssertEqual(pcmFormat(audio.media), PCMFormat(sampleRate: 24000, channels: 1))
    }

    // MARK: - Media types

    func testParsesMediaTypeParameters() {
        XCTAssertEqual(parseMediaType("audio/pcm; rate=24000;channels=2"),
                       LiveMediaType(type: "audio/pcm", params: ["rate": "24000", "channels": "2"]))
        XCTAssertEqual(parseMediaType("Audio/PCM;Rate=8000")?.type, "audio/pcm")
        XCTAssertEqual(parseMediaType("Audio/PCM;Rate=8000")?.params, ["rate": "8000"])
        XCTAssertNil(parseMediaType(nil))
        XCTAssertNil(parseMediaType(""))
    }

    func testReadsPCMOnlyFrom16BitPCMAudio() {
        XCTAssertEqual(pcmFormat(parseMediaType("audio/pcm;format=s16le;rate=24000")), PCMFormat(sampleRate: 24000, channels: 1))
        XCTAssertEqual(pcmFormat(parseMediaType("audio/pcm")), PCMFormat(sampleRate: 16000, channels: 1))
        XCTAssertNil(pcmFormat(parseMediaType("audio/pcm;format=f32le;rate=24000")))
        XCTAssertNil(pcmFormat(parseMediaType("audio/pcm;rate=fast")))
        XCTAssertNil(pcmFormat(parseMediaType("image/jpeg")))
        XCTAssertNil(pcmFormat(nil))
    }

    // MARK: - Discriminated items

    func testLabelsAlternativesByTheDiscriminator() {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "events": [
                    "type": "array",
                    "format": "stream",
                    "items": ["oneOf": [["$ref": "#/$defs/Ask"], ["$ref": "#/$defs/Stop"]], "discriminator": ["propertyName": "kind"]],
                ],
            ],
            "$defs": [
                "Ask": ["type": "object", "properties": ["kind": ["const": "ask"], "q": ["type": "string"]]],
                "Stop": ["type": "object", "title": "Stop", "properties": ["kind": ["const": "stop"]]],
            ],
        ]
        let events = splitLiveSchema(schema).live[0]
        XCTAssertEqual(events.discriminator, "kind")
        XCTAssertEqual(events.alternatives.enumerated().map { alternativeLabel($1, index: $0, discriminator: events.discriminator) },
                       ["ask", "stop"])
        XCTAssertEqual(alternativeTag(events.alternatives[0], discriminator: events.discriminator), "kind")
    }

    func testFallsBackToTypeThenTheFirstConstantThenTheTitle() {
        XCTAssertEqual(alternativeLabel(["properties": ["type": ["const": "text"]]], index: 0), "text")
        XCTAssertEqual(alternativeLabel(["properties": ["op": ["const": "ping"]]], index: 0), "ping")
        XCTAssertEqual(alternativeLabel(["properties": ["a": ["const": "x"], "type": ["const": "t"]]], index: 0), "t")
        XCTAssertEqual(alternativeLabel(["title": "Plain"], index: 3), "Plain")
        XCTAssertNil(alternativeTag(["title": "Plain"]))
    }
}
