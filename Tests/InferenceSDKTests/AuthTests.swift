import XCTest
@testable import InferenceSDK

final class AuthTests: XCTestCase {

    // MARK: - PKCE / SHA-256

    func testSHA256Vectors() {
        func hex(_ s: String) -> String { SHA256.hash(Array(s.utf8)).map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(hex(String(repeating: "a", count: 1000)),
                       "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    func testPKCERFC7636AppendixB() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(pkce.method, "S256")
    }

    func testPKCERandomVerifier() {
        let a = PKCE(), b = PKCE()
        XCTAssertEqual(a.verifier.count, 43)
        XCTAssertNotEqual(a.verifier, b.verifier)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertTrue(a.verifier.unicodeScalars.allSatisfy(allowed.contains))
        XCTAssertEqual(a.challenge, PKCE.challenge(for: a.verifier))
    }

    // MARK: - Authorization URL and callback

    func testAuthorizationURL() throws {
        let oauth = InferenceOAuth(clientId: "client-abc")
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let req = oauth.authorizationRequest(redirectURI: "inferencesh://oauth/callback",
                                             scope: "agents:read apps:write", pkce: pkce, state: "st+1")
        let comps = try XCTUnwrap(URLComponents(url: req.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.scheme, "https")
        XCTAssertEqual(comps.host, "api.inference.sh")
        XCTAssertEqual(comps.path, "/oauth/authorize")
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q, [
            "response_type": "code",
            "client_id": "client-abc",
            "redirect_uri": "inferencesh://oauth/callback",
            "code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            "code_challenge_method": "S256",
            "state": "st+1",
            "scope": "agents:read apps:write",
        ])
        let raw = try XCTUnwrap(comps.percentEncodedQuery)
        XCTAssertTrue(raw.contains("redirect_uri=inferencesh%3A%2F%2Foauth%2Fcallback"))
        XCTAssertTrue(raw.contains("scope=agents%3Aread%20apps%3Awrite"))
        XCTAssertTrue(raw.contains("state=st%2B1"), "a bare + would reach Go as a space")
        XCTAssertEqual(req.callbackScheme, "inferencesh")

        let noScope = oauth.authorizationRequest(redirectURI: "inferencesh://oauth/callback")
        XCTAssertFalse(noScope.url.absoluteString.contains("scope="))
        XCTAssertFalse(noScope.url.absoluteString.contains("team_id="))
        XCTAssertEqual(noScope.pkce.verifier.count, 43)
    }

    /// team_id preselects the team on the consent page (api 052c9835, web d3e7d26).
    func testAuthorizationURLTeam() throws {
        let oauth = InferenceOAuth(clientId: "client-abc")
        let req = oauth.authorizationRequest(redirectURI: "inferencesh://oauth/callback", teamId: "team_work")
        let items = URLComponents(url: req.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.filter { $0.name == "team_id" }.map(\.value), ["team_work"])
        let empty = oauth.authorizationRequest(redirectURI: "inferencesh://oauth/callback", teamId: "")
        XCTAssertFalse(empty.url.absoluteString.contains("team_id="))
    }

    func testCompleteAuthorizationExchangesCode() async throws {
        var oauth = InferenceOAuth(clientId: "client-abc")
        oauth.transport = StubProtocol.start { _, _ in
            .json(#"{"access_token":"at1","token_type":"Bearer","expires_in":600,"refresh_token":"infrt-1","scope":"agents:read"}"#)
        }
        let req = oauth.authorizationRequest(redirectURI: "inferencesh://oauth/callback")
        let callback = URL(string: "inferencesh://oauth/callback?code=c0de&state=\(req.state)")!
        let tokens = try await oauth.completeAuthorization(callbackURL: callback, request: req)
        XCTAssertEqual(tokens.accessToken, "at1")
        XCTAssertEqual(tokens.refreshToken, "infrt-1")

        let sent = try XCTUnwrap(StubProtocol.recorded.first)
        XCTAssertEqual(sent.request.url?.absoluteString, "https://api.inference.sh/oauth/token")
        XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(formFields(sent.body), [
            "grant_type": "authorization_code",
            "code": "c0de",
            "code_verifier": req.pkce.verifier,
            "redirect_uri": "inferencesh://oauth/callback",
            "client_id": "client-abc",
        ])
    }

    func testCompleteAuthorizationRejectsBadCallbacks() async {
        let oauth = InferenceOAuth(clientId: "c")
        let req = oauth.authorizationRequest(redirectURI: "inferencesh://oauth/callback")
        do {
            _ = try await oauth.completeAuthorization(
                callbackURL: URL(string: "inferencesh://oauth/callback?code=x&state=other")!, request: req)
            XCTFail("state mismatch accepted")
        } catch { XCTAssertEqual(error as? OAuthError, .stateMismatch) }
        do {
            _ = try await oauth.completeAuthorization(
                callbackURL: URL(string: "inferencesh://oauth/callback?error=access_denied&state=\(req.state)")!, request: req)
            XCTFail("denial accepted")
        } catch { XCTAssertEqual((error as? OAuthError)?.code, "access_denied") }
    }

    func testTokenErrorBodyBecomesOAuthError() async {
        var oauth = InferenceOAuth(clientId: "c")
        oauth.transport = StubProtocol.start { _, _ in
            .json(#"{"error":"invalid_grant","error_description":"Invalid refresh token"}"#, status: 400)
        }
        do {
            _ = try await oauth.refresh("infrt-old")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? OAuthError, .server(error: "invalid_grant", description: "Invalid refresh token"))
            XCTAssertTrue((error as? OAuthError)?.isPermanent ?? false)
        }
        XCTAssertEqual(formFields(StubProtocol.recorded[0].body),
                       ["grant_type": "refresh_token", "refresh_token": "infrt-old", "client_id": "c"])
    }

    // MARK: - Token decoding

    func testTokenResponseDecoding() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tokens = try OAuthTokens.decode(tokenResponse: Data(#"""
            {"access_token":"eyJ.a.b","token_type":"Bearer","expires_in":600,"refresh_token":"infrt-x","scope":"agents:read apps:write"}
            """#.utf8), receivedAt: now)
        XCTAssertEqual(tokens, OAuthTokens(accessToken: "eyJ.a.b", refreshToken: "infrt-x",
                                           expiresAt: now.addingTimeInterval(600),
                                           scope: "agents:read apps:write", tokenType: "Bearer"))
        XCTAssertFalse(tokens.expires(within: 599, now: now))
        XCTAssertTrue(tokens.expires(within: 600, now: now))

        // Device flow: a session token, no refresh token or expiry.
        let device = try OAuthTokens.decode(tokenResponse: Data(#"{"access_token":"sess","token_type":"Bearer","team_id":"t1"}"#.utf8))
        XCTAssertNil(device.refreshToken)
        XCTAssertNil(device.expiresAt)
        XCTAssertFalse(device.expires(within: 1e9))

        // Storage round trip.
        let stored = try JSONDecoder().decode(OAuthTokens.self, from: JSONEncoder().encode(tokens))
        XCTAssertEqual(stored, tokens)
    }

    func testDeviceAuthorizationPollingHonorsPendingAndSlowDown() async throws {
        var oauth = InferenceOAuth(clientId: "c")
        let replies = [
            #"{"error":"authorization_pending","error_description":"User has not yet approved"}"#,
            #"{"error":"slow_down"}"#,
            #"{"error":"authorization_pending"}"#,
        ]
        oauth.transport = StubProtocol.start { _, _ in
            let n = StubProtocol.recorded.count
            return n <= replies.count ? .json(replies[n - 1], status: 400)
                : .json(#"{"access_token":"sess","token_type":"Bearer"}"#)
        }
        let device = DeviceAuthorization(deviceCode: "dc", userCode: "ABCD-EFGH",
                                         verificationURI: "https://app.inference.sh/auth/device", expiresIn: 300, interval: 3)
        let sleeps = Recorder<UInt64>()
        let tokens = try await oauth.pollDeviceToken(device, now: { Date() }, sleep: { sleeps.append($0) })
        XCTAssertEqual(tokens.accessToken, "sess")
        XCTAssertEqual(sleeps.values.map { $0 / 1_000_000_000 }, [3, 3, 8, 8])
        XCTAssertEqual(formFields(StubProtocol.recorded[0].body),
                       ["grant_type": "urn:ietf:params:oauth:grant-type:device_code", "device_code": "dc", "client_id": "c"])
    }

    func testDeviceAuthorizationPollingExpires() async {
        var oauth = InferenceOAuth(clientId: "c")
        oauth.transport = StubProtocol.start { _, _ in .json(#"{"error":"authorization_pending"}"#, status: 400) }
        let clock = Recorder<Date>()
        clock.append(Date(timeIntervalSince1970: 0))
        let device = DeviceAuthorization(deviceCode: "dc", userCode: "U", verificationURI: "v", expiresIn: 10, interval: 3)
        do {
            _ = try await oauth.pollDeviceToken(device, now: { clock.values.last! }, sleep: { ns in
                clock.append(clock.values.last!.addingTimeInterval(TimeInterval(ns / 1_000_000_000)))
            })
            XCTFail("expected expiry")
        } catch {
            XCTAssertEqual((error as? OAuthError)?.code, "expired_token")
        }
        XCTAssertEqual(StubProtocol.recorded.count, 4)  // t=3,6,9,12
    }

    // MARK: - RefreshingAuthProvider

    func testConcurrentCallersShareOneRefresh() async throws {
        let calls = Recorder<String>()
        let saved = Recorder<OAuthTokens>()
        let provider = RefreshingAuthProvider(
            tokens: OAuthTokens(accessToken: "old", refreshToken: "infrt-1", expiresAt: Date().addingTimeInterval(5)),
            onTokens: { saved.append($0) },
            refresh: { refreshToken in
                calls.append(refreshToken)
                try await Task.sleep(nanoseconds: 100_000_000)
                return OAuthTokens(accessToken: "new", refreshToken: "infrt-2", expiresAt: Date().addingTimeInterval(600))
            })

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0..<20 { group.addTask { try await provider.bearerToken(forceRefresh: i % 2 == 0) } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(tokens, Array(repeating: "new", count: 20))
        XCTAssertEqual(calls.values, ["infrt-1"])
        XCTAssertEqual(saved.values.map(\.refreshToken), ["infrt-2"])

        // Fresh token: no refresh; a forced one right after a refresh is throttled.
        let again = try await provider.bearerToken(forceRefresh: false)
        let forced = try await provider.bearerToken(forceRefresh: true)
        XCTAssertEqual(again, "new")
        XCTAssertEqual(forced, "new")
        XCTAssertEqual(calls.values.count, 1)
    }

    func testInvalidGrantSignsOut() async throws {
        let signedOut = Recorder<String>()
        let provider = RefreshingAuthProvider(
            tokens: OAuthTokens(accessToken: "old", refreshToken: "infrt-1", expiresAt: Date().addingTimeInterval(-1)),
            onSignedOut: { signedOut.append(($0 as? OAuthError)?.code ?? "?") },
            refresh: { _ in throw OAuthError.server(error: "invalid_grant", description: nil) })
        do { _ = try await provider.bearerToken(forceRefresh: false); XCTFail() } catch {
            XCTAssertEqual((error as? OAuthError)?.code, "invalid_grant")
        }
        XCTAssertEqual(signedOut.values, ["invalid_grant"])
        let remaining = await provider.tokens
        XCTAssertNil(remaining)
        do { _ = try await provider.bearerToken(forceRefresh: false); XCTFail() } catch {
            XCTAssertEqual(error as? OAuthError, .notSignedIn)
        }

        await provider.setTokens(OAuthTokens(accessToken: "again"))
        let token = try await provider.bearerToken(forceRefresh: false)
        XCTAssertEqual(token, "again")
    }

    func testNetworkErrorDuringEarlyRefreshKeepsValidToken() async throws {
        let signedOut = Recorder<String>()
        let provider = RefreshingAuthProvider(
            tokens: OAuthTokens(accessToken: "still-valid", refreshToken: "infrt-1", expiresAt: Date().addingTimeInterval(30)),
            onSignedOut: { _ in signedOut.append("x") },
            refresh: { _ in throw InferenceError.transport("offline") })
        let token = try await provider.bearerToken(forceRefresh: false)
        XCTAssertEqual(token, "still-valid")
        XCTAssertEqual(signedOut.values, [])
        let kept = await provider.tokens
        XCTAssertNotNil(kept)
    }

    // MARK: - InferenceClient 401 handling

    func test401RetriesOnceWithRefreshedToken() async throws {
        let refreshes = Recorder<String>()
        let provider = RefreshingAuthProvider(
            tokens: OAuthTokens(accessToken: "old", refreshToken: "infrt-1", expiresAt: Date().addingTimeInterval(600)),
            refresh: { rt in
                refreshes.append(rt)
                return OAuthTokens(accessToken: "new", refreshToken: "infrt-2", expiresAt: Date().addingTimeInterval(600))
            })
        var client = InferenceClient(auth: provider)
        client.transport = StubProtocol.start { req, _ in
            req.value(forHTTPHeaderField: "Authorization") == "Bearer new"
                ? .json(#"{"data":null}"#)
                : .json(#"{"type":"about:blank","title":"unauthorized","status":401}"#, status: 401)
        }
        try await client.files.delete("f1")
        XCTAssertEqual(StubProtocol.recorded.map(\.authorization), ["Bearer old", "Bearer new"])
        XCTAssertEqual(StubProtocol.recorded.map(\.path), ["/files/f1", "/files/f1"])
        XCTAssertEqual(refreshes.values, ["infrt-1"])
    }

    func test401WithStaticKeyIsNotRetried() async {
        var client = InferenceClient(apiKey: "1nfsh-key")
        client.transport = StubProtocol.start { _, _ in .json(#"{"title":"invalid credentials"}"#, status: 401) }
        do {
            try await client.tasks.cancel("t1")
            XCTFail("expected 401")
        } catch InferenceError.http(let status, _) {
            XCTAssertEqual(status, 401)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(StubProtocol.recorded.map(\.authorization), ["Bearer 1nfsh-key"])
        XCTAssertEqual(client.apiKey, "1nfsh-key")
    }

    func testPresignedUploadCarriesNoTokenAndIsNotRetriedOn401() async {
        let refreshes = Recorder<String>()
        let provider = RefreshingAuthProvider(
            tokens: OAuthTokens(accessToken: "at", refreshToken: "infrt-1", expiresAt: Date().addingTimeInterval(600)),
            refresh: { rt in refreshes.append(rt); return OAuthTokens(accessToken: "at2") })
        var client = InferenceClient(auth: provider)
        client.transport = StubProtocol.start { req, _ in
            if req.url?.host == "api.inference.sh" {
                return .json(#"{"data":[\#(Self.fileJSON)]}"#)
            }
            return .json("denied", status: 401)
        }
        do {
            _ = try await client.files.upload(Data("hello".utf8), filename: "a.txt", contentType: "text/plain")
            XCTFail("expected 401 from storage")
        } catch InferenceError.http(let status, _) {
            XCTAssertEqual(status, 401)
        } catch { XCTFail("\(error)") }
        let hosts = StubProtocol.recorded.map { $0.request.url?.host ?? "" }
        XCTAssertEqual(hosts, ["api.inference.sh", "storage.example.com"])
        XCTAssertEqual(StubProtocol.recorded.map(\.authorization), ["Bearer at", nil])
        #if !canImport(FoundationNetworking)  // corelibs does not hand upload bodies to URLProtocol
        XCTAssertEqual(StubProtocol.recorded[1].body, Data("hello".utf8))
        #endif
        XCTAssertEqual(refreshes.values, [])
    }

    func testStream401ReconnectsWithForcedRefresh() async throws {
        let provider = RefreshingAuthProvider(
            tokens: OAuthTokens(accessToken: "old", refreshToken: "infrt-1", expiresAt: Date().addingTimeInterval(600)),
            refresh: { _ in OAuthTokens(accessToken: "new", refreshToken: "infrt-2", expiresAt: Date().addingTimeInterval(600)) })
        var client = InferenceClient(auth: provider)
        client.transport = StubProtocol.start { req, _ in
            guard req.value(forHTTPHeaderField: "Authorization") == "Bearer new" else {
                return .json(#"{"title":"invalid credentials"}"#, status: 401)
            }
            return StubProtocol.Response(headers: ["Content-Type": "application/x-ndjson"],
                                         body: Data((#"{"type":"heartbeat"}"# + "\n" + Self.readyMessageJSON + "\n").utf8))
        }
        var texts: [String] = []
        for try await message in client.runAgentStream(ApiAgentRunRequest(agent: "a/b", input: LLMInput(text: "hi"))) {
            texts.append(message.text)
        }
        XCTAssertEqual(texts, ["done"])
        XCTAssertEqual(StubProtocol.recorded.map(\.authorization), ["Bearer old", "Bearer new"])
    }

    func testChatStream401ReconnectsWithForcedRefresh() async throws {
        let refreshes = Recorder<String>()
        let provider = RefreshingAuthProvider(
            tokens: OAuthTokens(accessToken: "old", refreshToken: "infrt-1", expiresAt: Date().addingTimeInterval(600)),
            refresh: { rt in
                refreshes.append(rt)
                return OAuthTokens(accessToken: "new", refreshToken: "infrt-2", expiresAt: Date().addingTimeInterval(600))
            })
        var client = InferenceClient(auth: provider)
        client.transport = StubProtocol.start { req, _ in
            guard req.value(forHTTPHeaderField: "Authorization") == "Bearer new" else {
                return .json(#"{"title":"invalid credentials"}"#, status: 401)
            }
            let sse = ": ping\n\nevent: chat_messages\ndata: \(Self.readyMessageJSON)\n\n"
            return StubProtocol.Response(headers: ["Content-Type": "text/event-stream"], body: Data(sse.utf8))
        }
        for try await event in client.chats.stream("c1") {
            guard case .message(let message, _) = event else { continue }
            XCTAssertEqual(message.text, "done")
            break
        }
        XCTAssertEqual(Array(StubProtocol.recorded.map(\.authorization).prefix(2)), ["Bearer old", "Bearer new"])
        XCTAssertEqual(StubProtocol.recorded.first?.path, "/chats/c1/stream")
        XCTAssertEqual(refreshes.values, ["infrt-1"])
    }

    // MARK: - Fixtures

    static let fileJSON = #"""
        {"id":"f1","short_id":"f1","created_at":"x","updated_at":"x","user_id":"u","team_id":"t","visibility":"private",
         "uri":"https://cdn.example.com/f1","path":"a.txt","content_type":"text/plain","size":5,"filename":"a.txt",
         "upload_url":"https://storage.example.com/put/f1","remote_path":"r","category":"","rating":"safe"}
        """#

    static let readyMessageJSON = #"{"id":"m1","short_id":"m1","created_at":"x","updated_at":"x","user_id":"u","team_id":"t","visibility":"private","chat_id":"c1","order":1,"status":"ready","role":"assistant","content":[{"type":"text","text":"done"}]}"#
}

/// Thread-safe append-only log for callbacks in tests.
final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return items }
}
