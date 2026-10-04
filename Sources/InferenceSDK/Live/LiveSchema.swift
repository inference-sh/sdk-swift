// Mirrors js/sdk-js/src/live/schema.ts: the live fields of a stream function.
//
// A stream function's input and output schemas are ordinary JSON Schemas in
// which some properties are live: `{"type": "array", "format": "stream",
// "items": ...}`. Their values travel over the task's socket while it runs,
// instead of in the request body or the final output. `format: "stream"` is
// the sibling of `format: "file"`: the same media, live instead of by
// reference.
//
// On the wire a binary frame is one item of the schema's binary live field
// (there is at most one per direction), and a JSON text frame is a partial
// object keyed by property name: an item of a live field, or a new value for
// an ordinary one.
//
// Divergences from JS:
// - Schemas are JSONValue, as AppFunction carries them, where JS is generic
//   over a schema type.
// - JSONValue keeps no property order, so live fields come out sorted by key
//   and "the first property with a constant" is the first by key.
// - `MediaType` is `LiveMediaType`: the bare name is too likely to exist in
//   an app already.
// - A chain of `$ref`s stops resolving after 32 hops instead of overflowing
//   the stack on a schema that refers to itself.

import Foundation

/// A property whose values travel over the socket: `{"format": "stream"}`.
public func isLiveField(_ schema: JSONValue?) -> Bool {
    schema?["format"]?.stringValue == LiveProtocol.streamFormat
}

public struct LiveMediaType: Sendable, Equatable {
    /// e.g. "audio/pcm"
    public var type: String
    /// e.g. ["format": "s16le", "rate": "16000", "channels": "1"]
    public var params: [String: String]

    public init(type: String, params: [String: String] = [:]) {
        self.type = type
        self.params = params
    }
}

/// Splits "audio/pcm;format=s16le;rate=16000" into its type and parameters.
public func parseMediaType(_ value: String?) -> LiveMediaType? {
    guard let value, !value.isEmpty else { return nil }
    let parts = value.split(separator: ";", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    guard let type = parts.first, !type.isEmpty else { return nil }
    var params: [String: String] = [:]
    for part in parts.dropFirst() {
        guard let eq = part.firstIndex(of: "="), eq > part.startIndex else { continue }
        let key = part[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
        params[key] = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
    }
    return LiveMediaType(type: type.lowercased(), params: params)
}

public struct PCMFormat: Sendable, Equatable {
    public var sampleRate: Int
    public var channels: Int

    public init(sampleRate: Int, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

/// The PCM format of a media type, or nil when it is not 16-bit PCM audio.
public func pcmFormat(_ media: LiveMediaType?) -> PCMFormat? {
    guard let media, media.type == "audio/pcm" else { return nil }
    if let format = media.params["format"], !format.isEmpty, format != "s16le" { return nil }
    guard let sampleRate = Int(media.params["rate"] ?? "16000"), sampleRate > 0,
          let channels = Int(media.params["channels"] ?? "1"), channels > 0
    else { return nil }
    return PCMFormat(sampleRate: sampleRate, channels: channels)
}

public struct LiveField: Sendable, Equatable {
    public var key: String
    public var title: String
    public var description: String?
    /// Items are binary frames.
    public var binary: Bool
    /// Set when binary.
    public var media: LiveMediaType?
    /// What one item can be, references resolved: the alternatives of an anyOf,
    /// or the single item schema. Empty for a binary field.
    public var alternatives: [JSONValue]
    /// The property that tells the alternatives apart, when the schema names one.
    public var discriminator: String?

    public init(key: String, title: String, description: String? = nil, binary: Bool = false,
                media: LiveMediaType? = nil, alternatives: [JSONValue] = [], discriminator: String? = nil) {
        self.key = key
        self.title = title
        self.description = description
        self.binary = binary
        self.media = media
        self.alternatives = alternatives
        self.discriminator = discriminator
    }
}

/// Resolves a `#/$defs/` reference against the root, recursively. The result
/// carries no top-level `$ref` (a validator ignores a `$ref`'s siblings).
private func deref(_ schema: JSONValue, _ root: JSONValue, hops: Int = 0) -> JSONValue {
    guard hops < 32, var own = schema.objectValue, let ref = own["$ref"]?.stringValue,
          let target = root["$defs"]?[ref.replacingOccurrences(of: "#/$defs/", with: "")]
    else { return schema }
    // The reference's own fields (title, description) win over the target's.
    own["$ref"] = nil
    let resolved = deref(target, root, hops: hops + 1).objectValue ?? [:]
    return .object(resolved.merging(own) { _, own in own })
}

private func itemAlternatives(_ items: JSONValue, _ root: JSONValue) -> [JSONValue] {
    let resolved = deref(items, root)
    let options = (resolved["anyOf"] ?? resolved["oneOf"])?.arrayValue ?? []
    let alternatives = options.isEmpty ? [resolved] : options.map { deref($0, root) }
    // Each alternative must stand on its own (a form validates it without the
    // root), and nested references (an enum field, a nested model) still point
    // into the root's $defs, so they travel with it.
    guard let defs = root["$defs"] else { return alternatives }
    return alternatives.map { alternative in
        guard var object = alternative.objectValue else { return alternative }
        object["$defs"] = defs
        return .object(object)
    }
}

/// Splits a function schema into what a form renders (the ordinary
/// properties, also the request body) and what the socket carries (the live
/// ones, sorted by key).
public func splitLiveSchema(_ schema: JSONValue?) -> (ordinary: JSONValue?, live: [LiveField]) {
    guard let schema, var object = schema.objectValue else { return (nil, []) }
    guard let properties = object["properties"]?.objectValue else { return (schema, []) }

    var ordinary: [String: JSONValue] = [:]
    var live: [LiveField] = []
    for (key, property) in properties.sorted(by: { $0.key < $1.key }) {
        guard isLiveField(property) else {
            ordinary[key] = property
            continue
        }
        let items = property["items"].map { $0.arrayValue.map { $0.first ?? [:] } ?? $0 } ?? [:]
        let resolvedItems = deref(items, schema)
        let binary = resolvedItems["format"]?.stringValue == "binary"
        live.append(LiveField(
            key: key,
            title: property["title"]?.stringValue ?? key,
            description: property["description"]?.stringValue,
            binary: binary,
            media: binary ? parseMediaType(resolvedItems["contentMediaType"]?.stringValue) : nil,
            alternatives: binary ? [] : itemAlternatives(items, schema),
            discriminator: binary ? nil : resolvedItems["discriminator"]?["propertyName"]?.stringValue
        ))
    }
    object["properties"] = .object(ordinary)
    if let required = object["required"]?.arrayValue {
        object["required"] = .array(required.filter { $0.stringValue.map { ordinary[$0] != nil } ?? false })
    }
    return (.object(object), live)
}

/// The schema's one binary live field. A binary frame carries no field name.
public func binaryLiveField(_ live: [LiveField]) -> LiveField? {
    live.first(where: \.binary)
}

/// The property whose constant names this alternative: the schema's
/// discriminator, else `type`, else the first property (by key) with a constant.
public func alternativeTag(_ schema: JSONValue, discriminator: String? = nil) -> String? {
    let constants = (schema["properties"]?.objectValue ?? [:])
        .filter { $0.value["const"] != nil }.keys.sorted()
    return ([discriminator, "type"].compactMap { $0 } + constants).first(where: constants.contains)
}

/// A label for one alternative of a JSON live field: the constant that tags it, else its title.
public func alternativeLabel(_ schema: JSONValue, index: Int, discriminator: String? = nil) -> String {
    if let tag = alternativeTag(schema, discriminator: discriminator),
       let value = schema["properties"]?[tag]?["const"]?.stringValue {
        return value
    }
    return schema["title"]?.stringValue ?? "option \(index + 1)"
}
