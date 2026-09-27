// Where InferenceClient gets its bearer token. Not in sdk-js (which takes a
// static key); the Apple apps sign users in with OAuth and need a token that
// refreshes under a long-lived client.

import Foundation

/// Supplies the bearer token for api requests. `InferenceClient` asks on every
/// request and on every stream connect and reconnect, with
/// `forceRefresh: false`; after a 401 it asks once more with
/// `forceRefresh: true` and retries if the token changed.
public protocol InferenceAuthProvider: Sendable {
    func bearerToken(forceRefresh: Bool) async throws -> String
}

/// A fixed token: an API key, or any bearer token you manage yourself.
/// `forceRefresh` has nothing to refresh, so a 401 is not retried.
public struct StaticAuthProvider: InferenceAuthProvider {
    public let token: String

    public init(_ token: String) { self.token = token }

    public func bearerToken(forceRefresh: Bool) async throws -> String { token }
}

/// OAuth tokens that refresh themselves. Hand it to
/// `InferenceClient(auth:)` and keep a reference to update or clear it.
///
/// - Refreshes before a request when the access token expires within
///   `refreshLeeway` (inference.sh access tokens live 10 minutes), and on
///   `forceRefresh` (after a 401).
/// - Concurrent callers share one refresh request. inference.sh rotates
///   refresh tokens: each refresh invalidates the one it used, so two parallel
///   refreshes with the same token would sign the user out.
/// - `onTokens` gets every new token set; persist it (Keychain) there.
/// - A refresh the server rejects for good (`invalid_grant`: revoked, expired
///   after 30 days unused, or already rotated elsewhere) clears the tokens and
///   calls `onSignedOut`; every later call throws `OAuthError.notSignedIn`
///   until `setTokens` is called with a new sign-in. Network errors keep the
///   tokens: the current access token is returned while it is still valid,
///   else the error is thrown and the next call tries again.
/// - Tokens without a refresh token (device flow) are used until they
///   expire or the server rejects them, then the provider signs out.
public actor RefreshingAuthProvider: InferenceAuthProvider {
    public typealias Refresh = @Sendable (_ refreshToken: String) async throws -> OAuthTokens

    public private(set) var tokens: OAuthTokens?
    public let refreshLeeway: TimeInterval
    private let refresh: Refresh
    private let onTokens: (@Sendable (OAuthTokens) -> Void)?
    private let onSignedOut: (@Sendable (Error) -> Void)?
    private let now: @Sendable () -> Date
    private var inflight: Task<OAuthTokens, Error>?
    private var lastRefresh: Date?

    /// A forced refresh this soon after the last one returns the current
    /// token: several requests that failed with the old token at once should
    /// not rotate the pair once each.
    static let forceRefreshThrottle: TimeInterval = 10

    /// Refreshes with `oauth.refresh(_:)`.
    public init(tokens: OAuthTokens, oauth: InferenceOAuth, refreshLeeway: TimeInterval = 60,
                onTokens: (@Sendable (OAuthTokens) -> Void)? = nil,
                onSignedOut: (@Sendable (Error) -> Void)? = nil) {
        self.init(tokens: tokens, refreshLeeway: refreshLeeway, onTokens: onTokens, onSignedOut: onSignedOut,
                  refresh: { try await oauth.refresh($0) })
    }

    /// Refreshes with `refresh`, e.g. a call to your own backend.
    public init(tokens: OAuthTokens, refreshLeeway: TimeInterval = 60,
                onTokens: (@Sendable (OAuthTokens) -> Void)? = nil,
                onSignedOut: (@Sendable (Error) -> Void)? = nil,
                refresh: @escaping Refresh) {
        self.init(tokens: tokens, refreshLeeway: refreshLeeway, onTokens: onTokens, onSignedOut: onSignedOut,
                  now: { Date() }, refresh: refresh)
    }

    init(tokens: OAuthTokens, refreshLeeway: TimeInterval,
         onTokens: (@Sendable (OAuthTokens) -> Void)?, onSignedOut: (@Sendable (Error) -> Void)?,
         now: @escaping @Sendable () -> Date, refresh: @escaping Refresh) {
        self.tokens = tokens
        self.refreshLeeway = refreshLeeway
        self.onTokens = onTokens
        self.onSignedOut = onSignedOut
        self.now = now
        self.refresh = refresh
    }

    public func bearerToken(forceRefresh: Bool) async throws -> String {
        guard let current = tokens else { throw OAuthError.notSignedIn }

        if forceRefresh {
            if inflight == nil, let lastRefresh, now().timeIntervalSince(lastRefresh) < Self.forceRefreshThrottle {
                return current.accessToken
            }
            guard current.refreshToken != nil else {
                // Rejected and nothing to refresh with.
                signOut(reason: OAuthError.notSignedIn)
                throw OAuthError.notSignedIn
            }
            return try await refreshed().accessToken
        }

        guard current.expires(within: refreshLeeway, now: now()) else { return current.accessToken }
        guard current.refreshToken != nil else {
            if current.expires(within: 0, now: now()) {
                signOut(reason: OAuthError.notSignedIn)
                throw OAuthError.notSignedIn
            }
            return current.accessToken
        }
        do {
            return try await refreshed().accessToken
        } catch {
            // Proactive refresh failed on the network: the old token still works.
            if let still = tokens, !still.expires(within: 0, now: now()) { return still.accessToken }
            throw error
        }
    }

    /// Replaces the tokens (a new sign-in). Cancels nothing in flight: a
    /// refresh already running finishes and is dropped.
    public func setTokens(_ tokens: OAuthTokens) {
        self.tokens = tokens
        inflight = nil
        lastRefresh = nil
    }

    /// Forgets the tokens without calling `onSignedOut`. Revoke first with
    /// `InferenceOAuth.revoke` if the server should forget them too.
    public func clear() {
        tokens = nil
        inflight = nil
    }

    /// One refresh at a time; later callers await the running one.
    private func refreshed() async throws -> OAuthTokens {
        if let inflight { return try await inflight.value }
        guard let refreshToken = tokens?.refreshToken else { throw OAuthError.notSignedIn }

        let refresh = self.refresh
        let task = Task { try await refresh(refreshToken) }
        inflight = task
        do {
            var fresh = try await task.value
            guard inflight == task else { return fresh }  // setTokens/clear ran meanwhile
            inflight = nil
            if fresh.refreshToken == nil { fresh.refreshToken = refreshToken }
            tokens = fresh
            lastRefresh = now()
            onTokens?(fresh)
            return fresh
        } catch {
            if inflight == task {
                inflight = nil
                if let oauth = error as? OAuthError, oauth.isPermanent { signOut(reason: error) }
            }
            throw error
        }
    }

    private func signOut(reason: Error) {
        guard tokens != nil else { return }
        tokens = nil
        inflight = nil
        onSignedOut?(reason)
    }
}
