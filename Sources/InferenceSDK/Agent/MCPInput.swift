// MCP input requests on agent tool invocations. Mirrors
// js/sdk-js/src/agent/mcp-input.ts.
//
// When a remote MCP server answers a tool call with `input_required`, the
// agent runtime parks the invocation in `awaiting_input` and stores an
// MCPInputState in its `data` (go/api internal/runtime/agent/mcp_tools.go).
// The UI renders each input request, collects an `ElicitResult` per key, and
// submits them with `AgentChatSession.submitMCPInput`; the runtime then
// re-sends the tool call with those responses.
//
// MCPInputState and the elicitation params are not api DTOs (the runtime's
// own state and the MCP spec's request shape), so like sdk-js they are
// declared here; `InputRequest`, `ElicitResult` and `ElicitAction` are the
// generated types.

import Foundation

/// js MCPMethodElicitationCreate.
public let mcpMethodElicitationCreate = "elicitation/create"

/// Stored in `ToolInvocationDTO.data` while an MCP tool call waits for the user.
public struct MCPInputState: Sendable {
    /// One request per key; the answers go back under the same keys.
    public var inputRequests: [String: InputRequest] {
        didSet { elicitations = Self.elicitations(inputRequests) }
    }
    /// Each elicitation request's params under its key, decoded once when
    /// the requests are set (a view reads them on every render). Requests of
    /// other methods have none.
    public private(set) var elicitations: [String: ElicitRequestParams]
    public var requestState: String?
    /// 1 for the first request; goes up each time the server asks again.
    public var round: Int

    public init(inputRequests: [String: InputRequest], requestState: String? = nil, round: Int = 1) {
        self.inputRequests = inputRequests
        self.elicitations = Self.elicitations(inputRequests)
        self.requestState = requestState
        self.round = round
    }

    private static func elicitations(_ requests: [String: InputRequest]) -> [String: ElicitRequestParams] {
        requests.compactMapValues(\.elicitParams)
    }

    /// js parseMCPInputState: an invocation's data (an object or a JSON
    /// string) as an MCPInputState, or nil when it is not a pending MCP input.
    public init?(data: JSONValue?) {
        guard let value = data?.parsingJSONString,
              value["input_required"]?.boolValue == true,
              let requests = value["input_requests"]?.objectValue, !requests.isEmpty else { return nil }
        var out: [String: InputRequest] = [:]
        for (key, request) in requests {
            out[key] = InputRequest(method: request["method"]?.stringValue ?? "", params: request["params"] ?? .null)
        }
        self.init(inputRequests: out,
                  requestState: value["request_state"]?.stringValue,
                  round: value["round"]?.doubleValue.map { Int($0) } ?? 1)
    }
}

public extension ToolInvocationDTO {
    /// The MCP input requests this call is waiting on, or nil.
    var mcpInputState: MCPInputState? { MCPInputState(data: data) }
}

/// One property of a form-mode `requestedSchema` (MCP restricts these to flat primitives).
public struct ElicitPropertySchema: Codable, Sendable, Equatable {
    public struct Option: Codable, Sendable, Equatable {
        public var const: String
        public var title: String?
    }

    /// "string", "number", "integer" or "boolean".
    public var type: String?
    public var title: String?
    public var description: String?
    public var `default`: JSONValue?
    /// "email", "uri", "date", "date-time", or another the server names.
    public var format: String?
    public var minLength: Int?
    public var maxLength: Int?
    public var minimum: Double?
    public var maximum: Double?
    public var `enum`: [String]?
    public var enumNames: [String]?
    public var oneOf: [Option]?
}

// The schema decoders are lenient: a field of an unexpected type reads as nil
// (and a property or option that is not an object is skipped) so one stray
// field never hides the request. sdk-js passes params through untyped.
public extension ElicitPropertySchema {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lenient(String.self, .type)
        title = c.lenient(String.self, .title)
        description = c.lenient(String.self, .description)
        `default` = c.lenient(JSONValue.self, .default)
        format = c.lenient(String.self, .format)
        minLength = c.lenient(Int.self, .minLength)
        maxLength = c.lenient(Int.self, .maxLength)
        minimum = c.lenient(Double.self, .minimum)
        maximum = c.lenient(Double.self, .maximum)
        // Non-string entries are dropped; an options list without a const is skipped.
        `enum` = c.lenient([JSONValue].self, .enum)?.compactMap(\.stringValue)
        enumNames = c.lenient([JSONValue].self, .enumNames)?.compactMap(\.stringValue)
        oneOf = c.lenient([Lenient<Option>].self, .oneOf)?.compactMap(\.value)
    }
}

public struct ElicitRequestedSchema: Codable, Sendable, Equatable {
    public var type: String?
    public var properties: [String: ElicitPropertySchema]?
    public var required: [String]?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lenient(String.self, .type)
        properties = c.lenient([String: Lenient<ElicitPropertySchema>].self, .properties)?
            .compactMapValues(\.value)
        required = c.lenient([JSONValue].self, .required)?.compactMap(\.stringValue)
    }
}

/// A value that decodes to nil instead of failing.
private struct Lenient<T: Decodable>: Decodable {
    var value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

private extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

/// params of an elicitation/create request.
public struct ElicitRequestParams: Codable, Sendable, Equatable {
    /// "form" or "url"; absent means form (see `isURL`).
    public var mode: String?
    public var message: String
    public var requestedSchema: ElicitRequestedSchema?
    public var url: String?

    public init(mode: String? = nil, message: String = "", requestedSchema: ElicitRequestedSchema? = nil, url: String? = nil) {
        self.mode = mode
        self.message = message
        self.requestedSchema = requestedSchema
        self.url = url
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = c.lenient(String.self, .mode)
        message = c.lenient(String.self, .message) ?? ""
        requestedSchema = c.lenient(ElicitRequestedSchema.self, .requestedSchema)
        url = c.lenient(String.self, .url)
    }

    /// js isURLElicitation: URL mode sends the user to a page; form mode asks
    /// for fields. Mode defaults to form, or url when only a url is given.
    public var isURL: Bool { mode == "url" || (mode == nil && url != nil) }
}

public extension InputRequest {
    /// js elicitParams: the elicitation params, or nil for other methods.
    /// Decodes on every read; from an `MCPInputState`, read its
    /// `elicitations`, decoded once.
    var elicitParams: ElicitRequestParams? {
        guard method == mcpMethodElicitationCreate, !params.isNull,
              let data = try? JSONEncoder().encode(params) else { return nil }
        return try? JSONDecoder().decode(ElicitRequestParams.self, from: data)
    }
}

public extension JSONValue {
    /// This value, or the JSON a string holds: api fields typed as JSON are
    /// sometimes stored as a JSON string (tool invocation `data`). nil for a
    /// string that holds no JSON.
    var parsingJSONString: JSONValue? {
        guard let s = stringValue else { return self }
        return try? InferenceClient.decoder.decode(JSONValue.self, from: Data(s.utf8))
    }
}

/// js buildMCPInputResult: the tool result string the runtime expects,
/// `{<key>: {action, content?}}`. Content is kept only for accepted answers.
/// Keys are sorted, so the same answers always encode the same.
public func buildMCPInputResult(_ responses: [String: ElicitResult]) -> String {
    var out: [String: ElicitResult] = [:]
    for (key, response) in responses {
        out[key] = ElicitResult(action: response.action, content: response.action == .accept ? response.content : nil)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(out)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
}
