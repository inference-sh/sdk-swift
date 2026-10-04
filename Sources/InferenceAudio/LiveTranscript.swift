import Foundation
import InferenceSDK

/// The transcript so far, from an STT stream function's `text` patches.
///
/// Each patch carries the whole transcript so far, not a delta. Apps differ:
/// xAI and OpenAI grow it word by word, ElevenLabs sends a full line at once,
/// Inworld rewrites its last words. The leading words a patch left as they
/// were are `settled`; the ones it added or changed are `tail` (still
/// moving: show them lighter).
public struct LiveTranscript: Equatable, Sendable {
    public private(set) var text = ""
    /// The leading words the last patch did not change.
    public private(set) var settled = ""
    /// The rest: what the last patch added or rewrote.
    public private(set) var tail = ""
    /// Patches applied (an empty first patch counts).
    public private(set) var patches = 0
    /// The app's last `$error`, if any.
    public var error: String?

    public init() {}

    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// A new value of the text field.
    public mutating func apply(_ next: String) {
        patches += 1
        let old = text.split(separator: " ", omittingEmptySubsequences: true)
        let new = next.split(separator: " ", omittingEmptySubsequences: true)
        var same = 0
        while same < old.count, same < new.count, old[same] == new[same] { same += 1 }
        // A word the app only extended ("Charles" → "Charles.") stays tail
        // with what follows, so the settled part never shows half a word.
        text = new.joined(separator: " ")
        settled = new.prefix(same).joined(separator: " ")
        tail = new.dropFirst(same).joined(separator: " ")
    }

    /// `$clear`: the app dropped what it had sent.
    public mutating func clear() {
        text = ""
        settled = ""
        tail = ""
    }

    /// Everything counts as settled (the take is over).
    public mutating func settle() {
        settled = text
        tail = ""
    }

    /// The text a finished STT task returned: `text`, else its `utterances`,
    /// `turns` or `segments` joined. Nil when it has no words.
    public static func resultText(_ output: JSONValue?) -> String? {
        guard let output else { return nil }
        if let text = output["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        for key in ["utterances", "turns", "segments"] {
            let parts = (output[key]?.arrayValue ?? []).compactMap {
                $0["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: " ") }
        }
        return nil
    }

    /// A take's final text: the task's result when it came (it has the words
    /// spoken right before the release), else the last patch. Nil when
    /// neither has words.
    public static func finalText(result: JSONValue?, lastPatch: LiveTranscript) -> String? {
        if let text = resultText(result) { return text }
        return lastPatch.isEmpty ? nil : lastPatch.text
    }
}
