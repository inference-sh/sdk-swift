// Small concurrency helpers shared by the module. Foundation only.

import Foundation

extension NSLock {
    /// Runs `body` with the lock held. (NSLocking.withLock is not in every
    /// Foundation this package builds against.)
    @inline(__always)
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// Why InferenceAudio could not do what was asked.
public enum AudioError: Error, LocalizedError, Sendable, Equatable {
    /// The user has not allowed the microphone.
    case permissionDenied
    /// The input device is not there or not ready (no input route, a sample rate of 0).
    case inputUnavailable(String)
    /// A format this code cannot produce or read.
    case unsupportedFormat(String)
    /// Not a WAV file, or one this code cannot read.
    case invalidWAV(String)
    /// The source or sink was already running.
    case alreadyRunning
    /// A file operation failed.
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "the microphone is not allowed"
        case .inputUnavailable(let why): return "the microphone is not available: \(why)"
        case .unsupportedFormat(let what): return "unsupported audio format: \(what)"
        case .invalidWAV(let why): return "not a readable WAV file: \(why)"
        case .alreadyRunning: return "already running"
        case .io(let what): return what
        }
    }
}

/// The body's value, or nil when it fails or takes longer than `seconds`.
/// Returns at the deadline even if the body ignores cancellation (a task
/// group would wait for it); the body is cancelled then.
func withDeadline<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async -> T? {
    let once = ResumeOnce<T?>()
    let work = Task { once.resume(try? await body()) }
    let value = await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        once.set(continuation)
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { once.resume(nil) }
    }
    work.cancel()
    return value
}

/// A continuation resumed by whichever caller comes first; a value that
/// arrives before the continuation is kept for it.
final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var early: T?
    private var done = false

    func set(_ continuation: CheckedContinuation<T, Never>) {
        let value: T? = lock.locked {
            if done, let early { self.early = nil; return early }
            self.continuation = continuation
            return nil
        }
        if let value { continuation.resume(returning: value) }
    }

    func resume(_ value: T) {
        let continuation: CheckedContinuation<T, Never>? = lock.locked {
            if done { return nil }
            done = true
            guard let c = self.continuation else { early = value; return nil }
            self.continuation = nil
            return c
        }
        continuation?.resume(returning: value)
    }
}

/// Monotonic seconds, for timing that must not jump with the wall clock.
func monotonicNow() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
