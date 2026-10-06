// Chat rows the model did not write. Mirrors the predicates of
// js/common-js src/components/infsh/agent/system-message.tsx (the web chat's
// SystemMessage), so every client classifies messages the same way.
//
// What the api stores (go/api origin/dev):
// - injection: context a hook added to the prompt, one text block
//   (domain/hook/service.go). The model sees it folded into the user turn as
//   a <system-reminder>; the chat shows it as "context added".
// - event: a hook ran, an `event` block with `event.hook` (ChatHookEvent) and
//   a "hook {event}: {handler}" text. Display only: BuildContext skips it.
// - compaction: earlier turns replaced by a summary, one text block opening
//   with "[Earlier conversation compacted]" (domain/chatmessage/compaction.go).

import Foundation

public extension ChatMessageRole {
    /// Go ChatMessageRole.IsLLMRole: system, user, assistant and tool. The
    /// others (injection, compaction, event) are bookkeeping the chat shows
    /// as system rows.
    var isLLMRole: Bool { self == .system || self == .user || self == .assistant || self == .tool }
}

/// What a system row shows (web SystemMessage).
public enum ChatSystemNote: Sendable {
    /// An event message for a hook run: the hook's line.
    case hook(ChatHookEvent)
    /// An injection (or an event without a hook): context added to the prompt.
    case contextAdded(String)
    /// A compaction: the summary that replaced the earlier turns, without the
    /// api's "[Earlier conversation compacted]" opening line.
    case compacted(summary: String)
}

public extension ChatMessageDTO {
    /// The api opens every compaction summary with this line.
    static let compactionPrefix = "[Earlier conversation compacted]"

    /// web isSystemMessage: injections, events and compactions render as a
    /// muted row instead of a bubble.
    var isSystemMessage: Bool { role == .injection || role == .event || role == .compaction }

    /// The hook run an event message records, or nil.
    var hookEvent: ChatHookEvent? {
        guard role == .event else { return nil }
        return content?.first(where: { $0.type == .event })?.event?.hook
    }

    /// web SystemMessage: what a system row shows; nil for a message that is
    /// not one, or one with nothing to show.
    var systemNote: ChatSystemNote? {
        guard isSystemMessage else { return nil }
        if let hook = hookEvent { return .hook(hook) }
        guard let text = content?.first(where: { $0.type == .text })?.text?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if role == .compaction {
            let summary = text.hasPrefix(Self.compactionPrefix)
                ? String(text.dropFirst(Self.compactionPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                : text
            return .compacted(summary: summary)
        }
        return .contextAdded(text)
    }
}

public extension ChatHookEvent {
    /// The hook stopped what it ran on: a decision other than allow.
    var isBlocking: Bool { decision.map { !$0.rawValue.isEmpty && $0 != .allow } ?? false }

    /// web HookEventRow's line: "hook · {event} · {handler}", then
    /// "added context" and "{decision}: {reason}" when they apply.
    var summary: String {
        var parts = [event.rawValue, handler]
        if injected == true { parts.append("added context") }
        if isBlocking, let decision {
            let reason = reason.flatMap { $0.isEmpty ? nil : $0 }
            parts.append(reason.map { "\(decision.rawValue): \($0)" } ?? decision.rawValue)
        }
        return "hook · " + parts.joined(separator: " · ")
    }
}
