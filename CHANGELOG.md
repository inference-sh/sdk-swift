# Changelog

## Unreleased

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
