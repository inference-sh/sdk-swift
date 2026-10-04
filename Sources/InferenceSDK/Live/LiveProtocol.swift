// Mirrors js/sdk-js/src/live/protocol.ts: the live socket's wire protocol.
// sdk-py (inferencesh/models/stream.py) and sdk-js-app (src/stream.ts) hold
// copies too; change them together.

import Foundation

public enum LiveProtocol {
    /// A live field's schema is `{"type": "array", "format": "stream", "items": ...}`.
    public static let streamFormat = "stream"

    // Control frames. Reserved keys start with `$`, which no field name can, so a
    // control frame is never mistaken for an output field.

    /// `{"$clear": "audio"}`: drop what has been buffered of a live output field.
    public static let clearKey = "$clear"
    /// `{"$error": {"field": ..., "message": ...}}`: a refused frame, or anything
    /// else the caller should be told went wrong. The stream goes on.
    public static let errorKey = "$error"

    /// Relay close codes that mean "dial again". 1012: the relay is restarting and
    /// closed an end that still waited for its peer. 1013: the peer did not come in
    /// time. Neither means anything once frames have flowed.
    public static let redialCodes: Set<Int> = [1012, 1013]
}
