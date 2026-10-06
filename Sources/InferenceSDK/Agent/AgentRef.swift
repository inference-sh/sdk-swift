// How an agent is named to people and to the api, in one place: the Apple
// app had two versions that disagreed on an empty namespace.

import Foundation

public extension AgentDTO {
    /// What to call the agent: its title, or its name when the title is
    /// blank (empty or only whitespace).
    var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? name : title
    }

    /// "namespace/name", the ref `AgentChatSession` and `createChat` take.
    /// Just the name when the namespace is empty, as the api builds it
    /// (go/api apitypes `Ref.FullName`), never "/name".
    var ref: String {
        namespace.isEmpty ? name : "\(namespace)/\(name)"
    }
}
