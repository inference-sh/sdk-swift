// Widget (A2UI surface) parsing + bound-value resolution. Mirrors
// common-js/src/components/infsh/agent/widget-types.ts parseWidget and the
// renderer's resolveBoundValue. Lives in the SDK because every client needs
// the same parsing of `tool_invocation.widget` / `result` payloads.

import Foundation

public extension Widget {
    /// The web's parseWidget: accepts a raw A2UI surface, the legacy bridge
    /// format `{type:"a2ui", surface:{...}}`, a `{widget:{...}}` wrapper, or
    /// any of those as a JSON string. Returns nil when `input` is none of
    /// them (e.g. a plain-text tool result).
    static func parse(_ input: JSONValue?) -> Widget? {
        guard let input else { return nil }
        if let s = input.stringValue { return parse(string: s) }
        guard let obj = input.objectValue else { return nil }
        if let inner = obj["widget"], inner.objectValue != nil { return parse(inner) }
        if obj["type"]?.stringValue == "a2ui", let surface = obj["surface"], surface.objectValue != nil {
            return parse(surface)
        }
        guard obj["components"]?.arrayValue != nil else { return nil }
        guard let data = try? InferenceClient.encoder.encode(input) else { return nil }
        return try? InferenceClient.decoder.decode(Widget.self, from: data)
    }

    static func parse(string: String) -> Widget? {
        // Most tool results are plain text — skip the JSONValue decode unless
        // it can possibly be a widget payload.
        guard string.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
              let value = try? InferenceClient.decoder.decode(JSONValue.self, from: Data(string.utf8)) else { return nil }
        return parse(value)
    }
}

// A2UI bound values (`A2UIBound` in the TS types) are a wire union —
// string | number | boolean | {"path": ...} — so the generated fields are
// JSONValue. These read them the way the web renderer does.
public extension JSONValue {
    /// A data-model path reference (`{"path": ...}`), nil for a literal.
    var boundPath: String? {
        guard let path = self["path"]?.stringValue, !path.isEmpty else { return nil }
        return path
    }

    /// The renderer's resolveBoundValue: literal → its string form, path
    /// reference → a "[bound: path]" placeholder, anything else → "".
    var boundDisplay: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return String(b)
        default: return boundPath.map { "[bound: \($0)]" } ?? ""
        }
    }
}
