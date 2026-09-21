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
        // This payload IS a surface — apply the bound-literal rewrite
        // directly (the transport shim only rewrites under a "widget" key).
        guard let data = try? InferenceClient.encoder.encode(input) else { return nil }
        return try? InferenceClient.decoder.decode(Widget.self, from: InferenceClient.patchWidgetSurface(data))
    }

    static func parse(string: String) -> Widget? {
        // Most tool results are plain text — skip the JSONValue decode unless
        // it can possibly be a widget payload.
        guard string.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
              let value = try? InferenceClient.decoder.decode(JSONValue.self, from: Data(string.utf8)) else { return nil }
        return parse(value)
    }
}

public extension A2UIBoundValue {
    /// The literal the transport shim tunneled through `path` (see
    /// InferenceClient.patchWidgetSurface), or nil for a real data-model path.
    var literal: JSONValue? {
        guard let path, path.hasPrefix("$lit:"),
              let arr = try? InferenceClient.decoder.decode([JSONValue].self,
                                                            from: Data(path.dropFirst(5).utf8))
        else { return nil }
        return arr.first
    }

    /// A REAL data-model path reference, nil when `path` is carrying a
    /// tunneled literal. Read this (or `literal`), never raw `path` — raw
    /// `path` is a transport encoding.
    var dataPath: String? {
        guard let path, !path.isEmpty, !path.hasPrefix("$lit:") else { return nil }
        return path
    }

    /// The renderer's resolveBoundValue: literal → its string form, path
    /// reference → a "[bound: path]" placeholder, nothing → "".
    var display: String {
        if let literal {
            if let s = literal.stringValue { return s }
            if case .number(let n) = literal {
                return n == n.rounded() ? String(Int(n)) : String(n)
            }
            if case .bool(let b) = literal { return String(b) }
        }
        if let dataPath { return "[bound: \(dataPath)]" }
        return ""
    }
}
