import Foundation
import InferenceSDK

/// How to stream speech into one STT app: its stream function, the binary
/// PCM live input (and the rate its schema asks for) and the text output.
public struct LiveSpeechPlan: Equatable, Sendable {
    public var app: String
    public var function: String
    public var inputSchema: JSONValue
    public var outputSchema: JSONValue
    /// The input's binary live field (PCM frames).
    public var audioField: String
    /// The rate the function takes, from its schema (openai/gpt-transcribe: 24 kHz).
    public var sampleRate: Int
    /// The output field the transcript so far arrives in.
    public var textField: String
    /// The spec's key=value inputs the function takes. Others are dropped: a
    /// spec written for the app's run function may name inputs the stream
    /// function lacks.
    public var input: [String: JSONValue]

    public init(app: String, function: String, inputSchema: JSONValue, outputSchema: JSONValue, audioField: String,
                sampleRate: Int, textField: String, input: [String: JSONValue] = [:]) {
        self.app = app
        self.function = function
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.audioField = audioField
        self.sampleRate = sampleRate
        self.textField = textField
        self.input = input
    }

    /// The format to send.
    public var format: PCMFormat { PCMFormat(sampleRate: sampleRate, channels: 1) }

    /// The plan for an app's functions, or nil when none is a stream function
    /// that takes mono 16-bit PCM and sends text.
    public static func make(app: String, functions: [String: AppFunction], extraInput: [String: JSONValue] = [:]) -> LiveSpeechPlan? {
        for (name, function) in functions.sorted(by: { $0.key < $1.key }) where function.kind == .stream {
            let (ordinary, live) = splitLiveSchema(function.inputSchema)
            guard let audio = binaryLiveField(live), let pcm = pcmFormat(audio.media), pcm.channels == 1 else { continue }
            let outLive = splitLiveSchema(function.outputSchema).live
            let outProps = function.outputSchema["properties"]?.objectValue ?? [:]
            let textField: String
            if outProps["text"] != nil || outLive.contains(where: { $0.key == "text" }) {
                textField = "text"
            } else if let field = outLive.first(where: { !$0.binary }) {
                textField = field.key
            } else {
                continue
            }
            let accepted = Set((ordinary?["properties"]?.objectValue ?? [:]).keys)
            return LiveSpeechPlan(app: app, function: name, inputSchema: function.inputSchema,
                                  outputSchema: function.outputSchema, audioField: audio.key,
                                  sampleRate: pcm.sampleRate, textField: textField,
                                  input: extraInput.filter { accepted.contains($0.key) })
        }
        return nil
    }
}

/// Plans by app spec, so a press does not wait on `GET /apps`. An app
/// without a stream function is remembered as such (nil).
public actor LiveSpeechPlans {
    public static let shared = LiveSpeechPlans()

    private var cache: [String: LiveSpeechPlan?] = [:]
    private var inFlight: [String: Task<LiveSpeechPlan?, Error>] = [:]

    public init() {}

    /// The plan for "namespace/name[@version] key=value …" (`parseAppSpec`).
    public func plan(for spec: String, client: InferenceClient) async throws -> LiveSpeechPlan? {
        let key = cacheKey(spec, client)
        if let cached = cache[key] { return cached }
        if let running = inFlight[key] { return try await running.value }
        let (app, extra) = parseAppSpec(spec)
        guard !app.isEmpty else { return nil }
        let task = Task { () throws -> LiveSpeechPlan? in
            let functions = try await client.apps.getByName(app).version?.functions ?? [:]
            return LiveSpeechPlan.make(app: app, functions: functions, extraInput: extra)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let plan = try await task.value
        cache[key] = .some(plan)
        return plan
    }

    /// Sets the answer for a spec (tests, an app that ships its plans).
    public func remember(_ plan: LiveSpeechPlan?, for spec: String, client: InferenceClient) {
        cache[cacheKey(spec, client)] = .some(plan)
    }

    private func cacheKey(_ spec: String, _ client: InferenceClient) -> String {
        "\(client.baseURL.absoluteString) \(spec.trimmingCharacters(in: .whitespaces))"
    }
}
