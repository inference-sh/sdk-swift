// Mirrors js/sdk-js/src/http/poll.ts (PollManager). The callback class
// becomes one structured loop: start/stop/onData/onError map to calling the
// function, cancelling the task, the `onData` closure and a thrown error.
//
// Divergences from JS, both documented on the function: `retryDelayMs` is
// dropped (PollManager declares it but never schedules with it), and hitting
// `maxRetries` throws the last error instead of stopping silently (PollManager
// leaves surfacing the error to its onError callback).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Repeatedly calls `poll` and hands each result to `onData` until `onData`
/// returns a value, which becomes the result.
///
/// PollManager semantics: the first poll is immediate, later polls keep the
/// `interval` cadence. A successful poll resets the error counter; `maxRetries`
/// consecutive poll errors abort by throwing the last one. Errors thrown by
/// `onData` propagate immediately (the JS callers reject there too).
/// Cancellation propagates out of `Task.sleep`.
public func pollUntil<T, R>(
    interval: Duration = .seconds(2),
    maxRetries: Int = 5,
    poll: () async throws -> T,
    onData: (T) async throws -> R?
) async throws -> R {
    var consecutiveErrors = 0
    var first = true
    while true {
        if !first { try await Task.sleep(for: interval) }
        first = false

        let data: T
        do {
            data = try await poll()
        } catch {
            consecutiveErrors += 1
            if consecutiveErrors >= maxRetries { throw error }
            continue
        }
        consecutiveErrors = 0
        if let result = try await onData(data) { return result }
    }
}
