// Mirrors js/sdk-js/src/delta.ts: generic delta accumulator for streaming
// outputs, driven by the generated per-type field tags (LLMDelta.fieldTags
// and friends in Types.swift).
//
// Divergence from JS, registry shape: delta.ts keys a Map by the identity of
// a fieldTags object to find the child tags used one level down
// (LLMDelta_fieldTags -> ToolCallDelta_fieldTags -> ToolCallFunctionDelta_fieldTags).
// Swift dictionaries are values, not identities, so the registry is modeled
// as an explicit chain: `tagsChain[0]` is the root tags, `tagsChain[i + 1]`
// is what `registry.get(tagsChain[i])` returns in JS. This is faithful
// because the JS registry maps a whole tags dict (not a field) to a single
// child dict, so from any root it is traversed as a linear chain. Levels
// past the end of the chain behave like a registry miss ({} in JS).

import Foundation

/// js: `FieldTags = Record<string, { merge: string }>`, here the generated
/// `[String: [String: String]]` statics (e.g. `LLMDelta.fieldTags`).
public typealias DeltaFieldTags = [String: [String: String]]

public final class DeltaAccumulator {
    private var state: [String: JSONValue] = [:]
    private let tagsChain: [DeltaFieldTags]

    /// `tagsChain[0]` are the tags for the top-level delta; each following
    /// element is the child tags applied inside `indexed`/`nested` fields of
    /// the previous level (JS: `tags` + `registry`).
    public init(tagsChain: [DeltaFieldTags]) {
        self.tagsChain = tagsChain
    }

    public convenience init(tags: DeltaFieldTags) {
        self.init(tagsChain: [tags])
    }

    /// js delta.ts seed(): copy non-null fields into the state.
    public func seed(_ output: [String: JSONValue]) {
        for (key, value) in output where !value.isNull {
            state[key] = value
        }
    }

    /// js delta.ts apply(): merge each non-null delta field per its tag.
    public func apply(_ delta: [String: JSONValue]) {
        let tags = tags(at: 0)
        for (key, value) in delta where !value.isNull {
            let strategy = tags[key]?["merge"] ?? MergeStrategy.replace.rawValue
            state[key] = Self.mergeField(current: state[key], incoming: value, strategy: strategy, childLevel: 1, chain: tagsChain)
        }
    }

    public func toOutput() -> [String: JSONValue] {
        state
    }

    private func tags(at level: Int) -> DeltaFieldTags {
        Self.tags(at: level, chain: tagsChain)
    }

    private static func tags(at level: Int, chain: [DeltaFieldTags]) -> DeltaFieldTags {
        level < chain.count ? chain[level] : [:]
    }

    // js mergeField(). `childLevel` is the chain index of the tags to use for
    // the field's children (JS: `registry.get(tags)`).
    private static func mergeField(current: JSONValue?, incoming: JSONValue, strategy: String, childLevel: Int, chain: [DeltaFieldTags]) -> JSONValue {
        if incoming.isNull { return current ?? .null }
        switch strategy {
        case MergeStrategy.concat.rawValue:
            // js: (current ?? '') + incoming — string append. Non-string
            // operands would be coerced in JS; here non-strings contribute "".
            return .string((current?.stringValue ?? "") + (incoming.stringValue ?? ""))
        case MergeStrategy.replace.rawValue:
            return incoming
        case MergeStrategy.indexed.rawValue:
            return mergeIndexed(current: current?.arrayValue, incoming: incoming.arrayValue ?? [], childLevel: childLevel, chain: chain)
        case MergeStrategy.nested.rawValue:
            return mergeNested(current: current, incoming: incoming, childLevel: childLevel, chain: chain)
        default:
            return incoming
        }
    }

    // js mergeIndexed(): array of objects merged by their "index" member,
    // result sorted by index. Items are assumed to be objects (ToolCallDelta).
    private static func mergeIndexed(current: [JSONValue]?, incoming: [JSONValue], childLevel: Int, chain: [DeltaFieldTags]) -> JSONValue {
        var byIndex: [Int: [String: JSONValue]] = [:]
        if let current {
            for item in current {
                let obj = item.objectValue ?? [:]
                byIndex[indexOf(obj)] = obj
            }
        }
        for item in incoming {
            let obj = item.objectValue ?? [:]
            let idx = indexOf(obj)
            if let existing = byIndex[idx] {
                byIndex[idx] = mergeObject(current: existing, incoming: obj, level: childLevel, chain: chain)
            } else {
                byIndex[idx] = obj
            }
        }
        return .array(byIndex.sorted { $0.key < $1.key }.map { .object($0.value) })
    }

    private static func indexOf(_ obj: [String: JSONValue]) -> Int {
        // js: item.index ?? 0
        obj["index"]?.doubleValue.map(Int.init) ?? 0
    }

    // js mergeNested(): recursive object merge; nil current copies incoming.
    private static func mergeNested(current: JSONValue?, incoming: JSONValue, childLevel: Int, chain: [DeltaFieldTags]) -> JSONValue {
        let incomingObj = incoming.objectValue ?? [:]
        guard let currentObj = current?.objectValue else { return .object(incomingObj) }
        return .object(mergeObject(current: currentObj, incoming: incomingObj, level: childLevel, chain: chain))
    }

    // js mergeObject(): merge each non-null incoming field per this level's tags.
    private static func mergeObject(current: [String: JSONValue], incoming: [String: JSONValue], level: Int, chain: [DeltaFieldTags]) -> [String: JSONValue] {
        var result = current
        let levelTags = tags(at: level, chain: chain)
        for (key, value) in incoming where !value.isNull {
            let strategy = levelTags[key]?["merge"] ?? MergeStrategy.replace.rawValue
            result[key] = mergeField(current: result[key], incoming: value, strategy: strategy, childLevel: level + 1, chain: chain)
        }
        return result
    }
}

/// js delta.ts createLLMDeltaAccumulator(): LLMDelta -> ToolCallDelta ->
/// ToolCallFunctionDelta, wired from the generated fieldTags.
public func createLLMDeltaAccumulator() -> DeltaAccumulator {
    DeltaAccumulator(tagsChain: [
        LLMDelta.fieldTags,
        ToolCallDelta.fieldTags,
        ToolCallFunctionDelta.fieldTags,
    ])
}
