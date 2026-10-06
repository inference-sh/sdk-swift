// OAuth 2.1 client for signing users in to inference.sh. Not in sdk-js.
// Server side: go/api internal/auth/oauth.go (discovery, registration,
// authorize, token, revoke) and internal/auth/deviceauth.go (RFC 8628).
//
// What the server does, and so what this assumes:
// - Every endpoint is on the api host. GET /oauth/authorize redirects the
//   browser to the web app (app.inference.sh) for login and consent, which
//   then navigates to the redirect URI with `code` and `state`. Every
//   sign-in shows the consent page (no code is issued without it); the team
//   is the one picked there, preselected from `team_id` when the request
//   carries it, else the web session's current team.
// - Public clients (token_endpoint_auth_method "none") must use PKCE S256.
// - /oauth/token and /oauth/revoke take application/x-www-form-urlencoded;
//   /oauth/register takes JSON. Responses are bare JSON (no {data} envelope),
//   errors are RFC 6749 {error, error_description}.
// - Access tokens are 10-minute JWTs. Refresh tokens ("infrt-…") last 30 days
//   and rotate: each refresh returns a new one and invalidates the old.
// - A token carries the scopes granted at consent; no scope means full access.
// - The device flow (/oauth/device_authorization) returns a session token:
//   no refresh token, no expires_in (a 7-day session unless the approver
//   picked another lifetime).
//
// Foundation only, so it builds on Linux; the browser step
// (ASWebAuthenticationSession) and Keychain storage belong to the app.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Tokens

/// A token set from the token endpoint. Codable for storage (Keychain).
public struct OAuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    /// nil for device-flow session tokens.
    public var refreshToken: String?
    /// When the access token expires; nil when the server did not say.
    public var expiresAt: Date?
    /// Space-separated granted scopes. Empty or nil means unrestricted.
    public var scope: String?
    public var tokenType: String

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil,
                scope: String? = nil, tokenType: String = "Bearer") {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.tokenType = tokenType
    }

    /// True when the access token expires within `seconds` of `now`. Tokens
    /// without an expiry never expire by the clock.
    public func expires(within seconds: TimeInterval, now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= seconds
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case scope
        case tokenType = "token_type"
    }

    /// Token endpoint response → tokens; `expires_in` is counted from `receivedAt`.
    static func decode(tokenResponse data: Data, receivedAt: Date = Date()) throws -> OAuthTokens {
        let r = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard !r.accessToken.isEmpty else { throw OAuthError.unexpectedResponse("token response has no access_token") }
        return OAuthTokens(
            accessToken: r.accessToken,
            refreshToken: r.refreshToken.flatMap { $0.isEmpty ? nil : $0 },
            expiresAt: r.expiresIn.flatMap { $0 > 0 ? receivedAt.addingTimeInterval(TimeInterval($0)) : nil },
            scope: r.scope,
            tokenType: r.tokenType ?? "Bearer")
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let tokenType: String?
    let expiresIn: Int?
    let refreshToken: String?
    let scope: String?
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", tokenType = "token_type", expiresIn = "expires_in"
        case refreshToken = "refresh_token", scope
    }
}

// MARK: - Errors

public enum OAuthError: Error, LocalizedError, Sendable, Equatable {
    /// An RFC 6749 error from the server (`invalid_grant`,
    /// `authorization_pending`, …), or one a callback URL carried
    /// (`access_denied`).
    case server(error: String, description: String?)
    /// The callback's `state` does not match the request's.
    case stateMismatch
    /// The callback carries neither `code` nor `error`.
    case missingCode
    /// No tokens: never signed in, signed out, or the refresh was rejected.
    case notSignedIn
    case unexpectedResponse(String)

    /// The OAuth error code, for `.server`.
    public var code: String? {
        if case .server(let error, _) = self { return error }
        return nil
    }

    /// Retrying will not help: the grant is gone or the client is unknown.
    public var isPermanent: Bool {
        switch self {
        case .server(let error, _):
            return ["invalid_grant", "invalid_client", "unauthorized_client", "access_denied", "expired_token"].contains(error)
        case .notSignedIn:
            return true
        default:
            return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .server(let error, let description):
            return description.map { "\(error): \($0)" } ?? error
        case .stateMismatch: return "OAuth callback state does not match the request"
        case .missingCode: return "OAuth callback has no code"
        case .notSignedIn: return "Not signed in"
        case .unexpectedResponse(let s): return s
        }
    }
}

// MARK: - Metadata, registration, PKCE, device authorization

/// RFC 8414 authorization server metadata.
public struct OAuthServerMetadata: Codable, Sendable, Equatable {
    public var issuer: String
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var registrationEndpoint: URL?
    public var deviceAuthorizationEndpoint: URL?
    public var revocationEndpoint: URL?
    public var scopesSupported: [String]?
    public var grantTypesSupported: [String]?
    public var codeChallengeMethodsSupported: [String]?

    public init(issuer: String, authorizationEndpoint: URL, tokenEndpoint: URL,
                registrationEndpoint: URL? = nil, deviceAuthorizationEndpoint: URL? = nil,
                revocationEndpoint: URL? = nil, scopesSupported: [String]? = nil,
                grantTypesSupported: [String]? = nil, codeChallengeMethodsSupported: [String]? = nil) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.deviceAuthorizationEndpoint = deviceAuthorizationEndpoint
        self.revocationEndpoint = revocationEndpoint
        self.scopesSupported = scopesSupported
        self.grantTypesSupported = grantTypesSupported
        self.codeChallengeMethodsSupported = codeChallengeMethodsSupported
    }

    /// The endpoints inference.sh serves under `baseURL` (what
    /// /.well-known/oauth-authorization-server returns), without a request.
    public static func inference(baseURL: URL = URL(string: "https://api.inference.sh")!) -> OAuthServerMetadata {
        OAuthServerMetadata(
            issuer: baseURL.absoluteString,
            authorizationEndpoint: baseURL.appendingPathComponent("oauth/authorize"),
            tokenEndpoint: baseURL.appendingPathComponent("oauth/token"),
            registrationEndpoint: baseURL.appendingPathComponent("oauth/register"),
            deviceAuthorizationEndpoint: baseURL.appendingPathComponent("oauth/device_authorization"),
            revocationEndpoint: baseURL.appendingPathComponent("oauth/revoke"),
            grantTypesSupported: ["authorization_code", "refresh_token", "urn:ietf:params:oauth:grant-type:device_code"],
            codeChallengeMethodsSupported: ["S256"])
    }

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case deviceAuthorizationEndpoint = "device_authorization_endpoint"
        case revocationEndpoint = "revocation_endpoint"
        case scopesSupported = "scopes_supported"
        case grantTypesSupported = "grant_types_supported"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
    }
}

/// RFC 7591 registration response. The client id does not expire; store it
/// and register again only if the server stops recognizing it.
public struct OAuthClientRegistration: Codable, Sendable, Equatable {
    public var clientId: String
    /// Only for confidential clients (`token_endpoint_auth_method` other than "none").
    public var clientSecret: String?
    public var clientName: String
    public var redirectURIs: [String]
    public var grantTypes: [String]
    public var tokenEndpointAuthMethod: String

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case clientSecret = "client_secret"
        case clientName = "client_name"
        case redirectURIs = "redirect_uris"
        case grantTypes = "grant_types"
        case tokenEndpointAuthMethod = "token_endpoint_auth_method"
    }
}

private struct RegistrationRequest: Encodable {
    let clientName: String
    let redirectURIs: [String]
    let grantTypes: [String]
    let scope: String?
    let tokenEndpointAuthMethod: String
    enum CodingKeys: String, CodingKey {
        case clientName = "client_name", redirectURIs = "redirect_uris", grantTypes = "grant_types"
        case scope, tokenEndpointAuthMethod = "token_endpoint_auth_method"
    }
}

/// RFC 7636 proof key: a random verifier and its S256 challenge.
public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String
    public var method: String { "S256" }

    /// 32 random bytes, base64url: a 43-character verifier.
    public init() {
        self.init(verifier: Self.randomToken(bytes: 32))
    }

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Self.challenge(for: verifier)
    }

    /// BASE64URL(SHA256(ASCII(verifier))), no padding.
    public static func challenge(for verifier: String) -> String {
        base64URL(SHA256.hash(Array(verifier.utf8)))
    }

    /// `bytes` random bytes from the system CSPRNG, base64url without padding.
    public static func randomToken(bytes: Int = 16) -> String {
        var rng = SystemRandomNumberGenerator()
        return base64URL((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
    }

    static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Everything one browser sign-in needs: open `url`, then hand the callback
/// URL and this value to `InferenceOAuth.completeAuthorization`.
public struct OAuthAuthorizationRequest: Sendable, Equatable {
    public let url: URL
    public let redirectURI: String
    public let state: String
    public let pkce: PKCE

    /// The redirect URI's scheme, e.g. for ASWebAuthenticationSession's
    /// `callbackURLScheme`.
    public var callbackScheme: String? { URL(string: redirectURI)?.scheme }
}

/// RFC 8628 device authorization response. Show `userCode` and
/// `verificationURI` (or a QR code of `verificationURIComplete`).
public struct DeviceAuthorization: Codable, Sendable, Equatable {
    public var deviceCode: String
    public var userCode: String
    public var verificationURI: String
    public var verificationURIComplete: String?
    /// Seconds until `deviceCode` expires.
    public var expiresIn: Int
    /// Minimum seconds between polls.
    public var interval: Int?

    public init(deviceCode: String, userCode: String, verificationURI: String,
                verificationURIComplete: String? = nil, expiresIn: Int, interval: Int? = nil) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.verificationURIComplete = verificationURIComplete
        self.expiresIn = expiresIn
        self.interval = interval
    }

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code", userCode = "user_code"
        case verificationURI = "verification_uri", verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in", interval
    }
}

private struct OAuthErrorBody: Decodable {
    let error: String
    let errorDescription: String?
    enum CodingKeys: String, CodingKey { case error, errorDescription = "error_description" }
}

// MARK: - Client

/// OAuth client for one registered `clientId`.
///
/// Browser sign-in (authorization code + PKCE):
/// 1. `register` once per install (or ship a registered id / a Client ID
///    Metadata Document URL as `clientId`) and store the client id.
/// 2. `authorizationRequest(redirectURI:scope:)`; open `.url` in the browser.
/// 3. `completeAuthorization(callbackURL:request:)` → `OAuthTokens`.
/// 4. `RefreshingAuthProvider(tokens:oauth:)` → `InferenceClient(auth:)`.
///
/// `clientId` may be an https URL of a Client ID Metadata Document: JSON with
/// `client_id` (equal to that URL), `client_name`, `redirect_uris` and
/// optionally `grant_types` and `scope`. The server fetches it on first use,
/// so no registration call is needed.
public struct InferenceOAuth: Sendable {
    public var clientId: String
    /// Confidential clients only, sent as `client_secret` (client_secret_post).
    public var clientSecret: String?
    public var metadata: OAuthServerMetadata
    var transport: HTTPTransport = .shared

    public init(clientId: String, clientSecret: String? = nil,
                baseURL: URL = URL(string: "https://api.inference.sh")!) {
        self.init(clientId: clientId, clientSecret: clientSecret, metadata: .inference(baseURL: baseURL))
    }

    public init(clientId: String, clientSecret: String? = nil, metadata: OAuthServerMetadata) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.metadata = metadata
    }

    /// GET /.well-known/oauth-authorization-server.
    public static func discover(baseURL: URL = URL(string: "https://api.inference.sh")!) async throws -> OAuthServerMetadata {
        try await discover(baseURL: baseURL, transport: .shared)
    }

    static func discover(baseURL: URL, transport: HTTPTransport) async throws -> OAuthServerMetadata {
        var req = URLRequest(url: baseURL.appendingPathComponent(".well-known/oauth-authorization-server"))
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, status) = try await transport.perform(req, upload: nil)
        return try parse(data, status: status) { try JSONDecoder().decode(OAuthServerMetadata.self, from: $0) }
    }

    /// POST /oauth/register (RFC 7591, JSON) as a public client
    /// (`token_endpoint_auth_method: none`, PKCE required). The server
    /// accepts any redirect URI with a scheme — custom schemes like
    /// `myapp://oauth/callback` included — except plain http off loopback.
    /// Rate limited to 10 registrations per IP per hour.
    public static func register(clientName: String, redirectURIs: [String], scope: String? = nil,
                                grantTypes: [String] = ["authorization_code", "refresh_token"],
                                metadata: OAuthServerMetadata = .inference()) async throws -> OAuthClientRegistration {
        try await register(clientName: clientName, redirectURIs: redirectURIs, scope: scope,
                           grantTypes: grantTypes, metadata: metadata, transport: .shared)
    }

    static func register(clientName: String, redirectURIs: [String], scope: String?, grantTypes: [String],
                         metadata: OAuthServerMetadata, transport: HTTPTransport) async throws -> OAuthClientRegistration {
        guard let endpoint = metadata.registrationEndpoint else {
            throw OAuthError.unexpectedResponse("server metadata has no registration_endpoint")
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONEncoder().encode(RegistrationRequest(
            clientName: clientName, redirectURIs: redirectURIs, grantTypes: grantTypes,
            scope: scope, tokenEndpointAuthMethod: "none"))
        let (data, status) = try await transport.perform(req, upload: nil)
        return try parse(data, status: status) { try JSONDecoder().decode(OAuthClientRegistration.self, from: $0) }
    }

    // MARK: Authorization code

    /// Builds the authorize URL with a fresh PKCE pair and state. `scope` is
    /// space-separated; nil asks for no scope, which inference.sh grants as
    /// unrestricted access. `redirectURI` must be one the client registered.
    /// `teamId` (sent as `team_id`) preselects that team on the consent page,
    /// e.g. to sign a second device in to the team the first one uses; the
    /// person can still pick another. Without it the page starts on the web
    /// session's current team.
    public func authorizationRequest(redirectURI: String, scope: String? = nil, teamId: String? = nil,
                                     pkce: PKCE = PKCE(), state: String = PKCE.randomToken()) -> OAuthAuthorizationRequest {
        var params: [(String, String)] = [
            ("response_type", "code"),
            ("client_id", clientId),
            ("redirect_uri", redirectURI),
            ("code_challenge", pkce.challenge),
            ("code_challenge_method", pkce.method),
            ("state", state),
        ]
        if let scope, !scope.isEmpty { params.append(("scope", scope)) }
        if let teamId, !teamId.isEmpty { params.append(("team_id", teamId)) }
        var comps = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        let existing = comps.percentEncodedQuery.map { $0 + "&" } ?? ""
        comps.percentEncodedQuery = existing + Self.formEncode(params)
        return OAuthAuthorizationRequest(url: comps.url!, redirectURI: redirectURI, state: state, pkce: pkce)
    }

    /// Reads `code`/`state` (or `error`) off the redirect and exchanges the code.
    public func completeAuthorization(callbackURL: URL, request: OAuthAuthorizationRequest) async throws -> OAuthTokens {
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw OAuthError.server(error: error, description: value("error_description"))
        }
        guard value("state") == request.state else { throw OAuthError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw OAuthError.missingCode }
        return try await exchangeCode(code, codeVerifier: request.pkce.verifier, redirectURI: request.redirectURI)
    }

    /// POST /oauth/token, grant_type=authorization_code.
    public func exchangeCode(_ code: String, codeVerifier: String, redirectURI: String) async throws -> OAuthTokens {
        try await tokenRequest([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("code_verifier", codeVerifier),
            ("redirect_uri", redirectURI),
        ])
    }

    /// POST /oauth/token, grant_type=refresh_token. The server rotates the
    /// refresh token: use the returned one, the old one is now invalid. If a
    /// response ever lacks one, the old one is kept.
    public func refresh(_ refreshToken: String) async throws -> OAuthTokens {
        var tokens = try await tokenRequest([("grant_type", "refresh_token"), ("refresh_token", refreshToken)])
        if tokens.refreshToken == nil { tokens.refreshToken = refreshToken }
        return tokens
    }

    /// POST /oauth/revoke (RFC 7009). Revoke the refresh token on sign-out:
    /// access tokens are stateless JWTs and expire on their own (10 minutes).
    /// Also accepts device-flow session tokens. Unknown tokens succeed.
    public func revoke(_ token: String) async throws {
        guard let endpoint = metadata.revocationEndpoint else {
            throw OAuthError.unexpectedResponse("server metadata has no revocation_endpoint")
        }
        let (data, status) = try await transport.perform(formRequest(endpoint, [("token", token)] + clientAuth), upload: nil)
        _ = try Self.parse(data, status: status) { _ in () }
    }

    // MARK: Device authorization (RFC 8628)

    /// POST /oauth/device_authorization. inference.sh ignores `client_id` and
    /// `scope` here; the approver picks the team and scopes on the web page.
    public func startDeviceAuthorization(scope: String? = nil) async throws -> DeviceAuthorization {
        guard let endpoint = metadata.deviceAuthorizationEndpoint else {
            throw OAuthError.unexpectedResponse("server metadata has no device_authorization_endpoint")
        }
        var params = [("client_id", clientId)]
        if let scope, !scope.isEmpty { params.append(("scope", scope)) }
        let (data, status) = try await transport.perform(formRequest(endpoint, params), upload: nil)
        return try Self.parse(data, status: status) { try JSONDecoder().decode(DeviceAuthorization.self, from: $0) }
    }

    /// Polls the token endpoint until the user approves. Waits `interval`
    /// seconds (5 when absent) between polls, adds 5 on `slow_down`, keeps
    /// going on `authorization_pending`, and throws `.server(error:
    /// "expired_token")` once `expiresIn` has passed. `access_denied` and other
    /// errors are thrown as they come. Cancel the task to stop.
    public func pollDeviceToken(_ device: DeviceAuthorization) async throws -> OAuthTokens {
        try await pollDeviceToken(device, now: { Date() }, sleep: { try await Task.sleep(nanoseconds: $0) })
    }

    func pollDeviceToken(_ device: DeviceAuthorization, now: @Sendable () -> Date,
                         sleep: @Sendable (UInt64) async throws -> Void) async throws -> OAuthTokens {
        var interval = max(device.interval ?? 5, 1)
        let deadline = now().addingTimeInterval(TimeInterval(device.expiresIn))
        while true {
            try await sleep(UInt64(interval) * 1_000_000_000)
            do {
                return try await tokenRequest([
                    ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
                    ("device_code", device.deviceCode),
                ])
            } catch OAuthError.server(let error, _) where error == "authorization_pending" {
            } catch OAuthError.server(let error, _) where error == "slow_down" {
                interval += 5
            }
            if now() >= deadline {
                throw OAuthError.server(error: "expired_token", description: "device code expired before approval")
            }
        }
    }

    // MARK: Plumbing

    private var clientAuth: [(String, String)] {
        var params = [("client_id", clientId)]
        if let clientSecret { params.append(("client_secret", clientSecret)) }
        return params
    }

    private func tokenRequest(_ params: [(String, String)]) async throws -> OAuthTokens {
        let (data, status) = try await transport.perform(formRequest(metadata.tokenEndpoint, params + clientAuth), upload: nil)
        let receivedAt = Date()
        return try Self.parse(data, status: status) { try OAuthTokens.decode(tokenResponse: $0, receivedAt: receivedAt) }
    }

    private func formRequest(_ url: URL, _ params: [(String, String)]) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = Data(Self.formEncode(params).utf8)
        req.timeoutInterval = 60
        return req
    }

    /// Non-2xx with an OAuth error body → `OAuthError.server`; any other
    /// non-2xx → `InferenceError.http`.
    static func parse<T>(_ data: Data, status: Int, _ decode: (Data) throws -> T) throws -> T {
        guard (200..<300).contains(status) else {
            if let body = try? JSONDecoder().decode(OAuthErrorBody.self, from: data), !body.error.isEmpty {
                throw OAuthError.server(error: body.error, description: body.errorDescription)
            }
            throw InferenceError.http(status: status, body: String(decoding: data.prefix(2000), as: UTF8.self))
        }
        return try decode(data)
    }

    /// application/x-www-form-urlencoded with only RFC 3986 unreserved
    /// characters left bare (space is %20, "+" is %2B).
    static func formEncode(_ params: [(String, String)]) -> String {
        params.map { "\(percentEncode($0.0))=\(percentEncode($0.1))" }.joined(separator: "&")
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func percentEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }
}
