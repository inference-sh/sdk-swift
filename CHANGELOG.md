# Changelog

## Unreleased

Added:
- Live (stream) functions, a port of sdk-js `live/` and `api/sockets.ts`. `client.live(_:)` starts a stream function and dials the socket its run response carries; `client.sockets` has `open` (a run response or a task id), `get`, `list`, `forTask`, `access` and `delete`.
- `LiveSession`: `events` is an `AsyncStream<LiveEvent>` (state changes, binary frames, JSON patches, `$clear`, `$error`, plain text); `sendBinary`, `sendPatch`, `sendField`, `sendText`, `close`, `ended`. It waits for the app's first frame, ends if the task ends first, and redials with a fresh credential on relay close codes 1012 and 1013 while waiting (up to five times). The socket is `URLSessionWebSocketTask` with the credential as a bearer header; `OpenSocketOptions(dial:)` takes another WebSocket (`LiveSocket`).
- Live schema helpers: `splitLiveSchema`, `binaryLiveField`, `isLiveField`, `parseMediaType`, `pcmFormat`, `alternativeTag`, `alternativeLabel`, and `LiveProtocol` for the wire constants.
- `tasks.watch(_:options:)`: follows a task that is already running until it ends, with `run`'s outcomes.
- `Examples/live-run` and `make live APP=...`: a live end-to-end check for stream functions.

Changes:
- `tasks.run` no longer opens the task stream for a task that has already ended when it is first read: it reports the task through `onUpdate` and settles.

Breaking:
- `ChatDTO`, `ProjectDTO` and `ToolParameterProperty` are structs, no longer classes. Every generated type is a `Sendable` value type (gotypegen v0.8.2, inference-sh/api#1468): struct-typed fields are `@Indirect`, stored in an immutable box, so values stay small (`ChatDTO` 392 bytes) and cycles like `ChatDTO.parent` still work. Code that mutated a `let` DTO needs `var`.

Fixes:
- `ChatStreamEvent: Sendable` no longer warns in consumer builds.
- `apps.getByName("ns/app@version")` returns that version. It used to strip the suffix and return the current version, so `live-run` against a staged version read the wrong functions ("no stream function").

## 0.7.1

- Types: `ChatSettingsRequest` (name, visibility, `allowAllTools`, `disableHooks`, `forgetMemory`) and `ChatData.allowAllTools` / `disableHooks` for `POST /chats/{id}/settings`; per-server MCP headers and setup; API key scope; `MeResponse.needsUsername`.

## 0.5.1

- `tasks.run` survives a dropped task stream: it reconnects (up to `maxReconnects`, the budget resets whenever a line arrives), resyncs the task with `GET /tasks/{id}` after each drop and returns if it finished meanwhile. The stream request times out after 45s of silence (the server heartbeats every 10s) instead of the default 300s, so a dead connection no longer leaves a run looking stuck.

## 0.5.0

Breaking:
- `tasks.create` returns `TaskResultDTO`, what POST /apps/run sends (id, status, output). It was typed `TaskDTO`, so every `create`, and `tasks.run` (which starts with `create`), failed to decode: `keyNotFound(user_id)`. `tasks.run` now reads the full task with `GET /tasks/{id}` after creating it and still returns `TaskDTO`.

Changes:
- `client.teams`: `me()` (GET /me → generated `MeResponse`), list, get, view, create, update, delete, checkUsername, members and invites. Ports sdk-js `teams.ts` on the server's types: teams are `TeamDTO` (sdk-js says `TeamRelationDTO`).
- Types regenerated: `MeResponse` and what it references (`TeamDTO`, `OrgDTO`, `TeamViewDTO`, `DiagnosticsConfig`, `TeamKind`, governance types), rooted in go/api `SDKTypes` (inference-sh/api#1462).

## 0.4.0

Breaking:
- `ToolParameterProperty.type` is now optional. A parameter that accepts several shapes carries them in `anyOf` and has no single `type`; code that read `type` unconditionally should handle `nil` and look at `anyOf`.

Changes:
- `ToolParameterProperty.anyOf`: the shapes a union parameter may take, each a `ToolParameterProperty`.
- `ToolParameterProperty.enum`: the closed set of values a scalar may take, as data rather than description text.
- Types regenerated from the api (agentprotocol v0.16.0, models v0.8.60).

## 0.3.0

No breaking changes. `InferenceClient(apiKey:)`, `InferenceClient(baseURL:apiKey:onMessage:)` and the `apiKey` property keep working.

Added:
- Pluggable auth: `InferenceAuthProvider` and `InferenceClient(baseURL:auth:onMessage:)`. `StaticAuthProvider` wraps an API key. The provider is asked for a token on every request, upload, and stream connect and reconnect (chat SSE, `runAgentStream`, `tasks.run`), and the TTS/STT helpers go through the same path. A 401 is retried once with `forceRefresh: true` when that yields a different token. Presigned upload URLs and file downloads never get the token.
- OAuth sign-in: `InferenceOAuth` (metadata discovery, dynamic client registration, PKCE S256, authorization URL, callback handling, code exchange, refresh, revoke, RFC 8628 device authorization and polling), `OAuthTokens`, `OAuthError`.
- `RefreshingAuthProvider`: an actor that refreshes before expiry and after a 401, runs one refresh at a time for all callers (inference.sh rotates refresh tokens), reports new tokens through `onTokens`, and calls `onSignedOut` when the refresh token is rejected.
- `client.knowledge`: `list`, `get`, `getByName`, `create`, `update`, `delete`, `listVersions`, `getVersion`, `transferOwnership`, `updateVisibility`.

Changes:
- `apiKey` is now computed from `auth`: it returns the key of a `StaticAuthProvider` (else ""), and setting it installs one.

## 0.2.0

Breaking:
- The top-level `InferenceClient` methods `getApp`, `runApp`, `uploadFile` and `stopChat` are removed. Use the namespaces: `client.apps.get`, `client.tasks.run`, `client.files.upload`, `client.chats.stop`.

Changes:
- Request and response bodies are the generated types (hand-written copies removed).
- Types regenerated from the api: `ErrorCode` on API errors, `channel_context` on agent run requests, `remotes:*` and `artifacts` scopes, credential OAuth callback `params`, builtin hooks.

## 0.1.2

- Types regenerated from the api: `agents.harness`, `chats.work_dir`, settings v2, `RemoteStatus`, credential types.

## 0.1.1

- Types regenerated from the api: credential wire names, `CredentialRequirement` provider/name/website, auth schemes.

## 0.1.0

First public release.

- `InferenceClient` with namespaced apis: `tasks`, `agents`, `chats`, `apps`, `files`, `search`.
- `tasks.run` with NDJSON streaming, polling, fire-and-forget and delta callbacks.
- `AgentChatSession`: agent chat state machine (port of sdk-js agent actions + reducer) with SSE streaming, reconnect, per-message delta attribution, queued messages, tool approvals, widget results and older-message paging.
- `TextToSpeech` / `SpeechToText` over any speech app, driven by the app's schema.
- Codable models generated from the api (gotypegen), tolerant of enum values added later.
- iOS 17+, macOS 14+, Linux.
