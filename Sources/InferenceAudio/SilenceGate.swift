import Foundation

/// Stops a microphone streaming silence (web app: `SilenceGate` in
/// src/lib/live/pcm.ts). A frame goes out while the input is above a very
/// low level (below it is near-digital silence: a muted input, or noise
/// suppression with nobody speaking), and for `tail` after it drops, so the
/// app's voice detection still hears the pause that ends a turn. Past that
/// nothing is sent until the level rises again.
public struct SilenceGate: Sendable {
    /// Peak level (0...1) that counts as sound: 0.0005 is about -66 dBFS.
    public var threshold: Float
    /// How long quiet frames still go out after the last sound. It covers the
    /// pause voice detection waits for to end a turn.
    public var tail: TimeInterval
    private var lastSound = -Double.infinity

    public init(threshold: Float = 0.0005, tail: TimeInterval = 6) {
        self.threshold = threshold
        self.tail = tail
    }

    /// Some frame has reached the threshold. With `pass` false it tells
    /// "quiet for `tail` after sound" (a tapped take ends here) from "no
    /// sound yet" (waiting for the speaker to start).
    public var hasHeardSound: Bool { lastSound > -Double.infinity }

    /// Whether a frame with this peak level should be sent. `now` is any
    /// monotonic clock in seconds (the default is the system uptime).
    public mutating func pass(level: Float, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        if level >= threshold { lastSound = now }
        return now - lastSound <= tail
    }
}
