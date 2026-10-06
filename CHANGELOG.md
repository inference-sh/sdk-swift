# Changelog

## Unreleased

Added:
- `InferenceOAuth.authorizationRequest(redirectURI:scope:teamId:)`: `teamId` is sent as `team_id` and preselects that team on the consent page (api 052c9835, web d3e7d26). Every sign-in now shows the consent page; without `teamId` it starts on the web session's current team.
- `AgentChatSession.switchAgent(_:)` (sdk-js `switchAgent`): `POST /chats/{id}/agent` and merges the `ChatAgentDTO` it answers into `state.chat` (reducer action `mergeChatAgent`, sdk-js `MERGE_CHAT_AGENT`; an answer for another chat is ignored). A refusal sets `state.error` and is thrown.
- MCP input requests (sdk-js `mcp-input.ts`): `MCPInputState(data:)` and `ToolInvocationDTO.mcpInputState` read what an `awaiting_input` MCP call waits on; `InputRequest.elicitParams` (`ElicitRequestParams`, `ElicitRequestedSchema`, `ElicitPropertySchema`), `ElicitRequestParams.isURL`, `buildMCPInputResult(_:)`. The params decode leniently: a field of an unexpected type reads as nil instead of hiding the request. `AgentChatSession.submitMCPInput(_:responses:)` answers them; a 400 (answers rejected, the call still waiting) is thrown without marking the connection failed.
- System rows (web `SystemMessage`): `ChatMessageDTO.isSystemMessage` (injection, event, compaction), `.systemNote` (`ChatSystemNote`: `.hook(ChatHookEvent)`, `.contextAdded(text)`, `.compacted(summary:)` without the api's "[Earlier conversation compacted]" line), `.hookEvent`; `ChatHookEvent.isBlocking` and `.summary`; `ChatMessageRole.isLLMRole`.
- `internalTools()` (`InternalToolsBuilder`), `lifecycleHook(_:)` (`LifecycleHookBuilder`) and `learningHooks(suggest:learn:)` (sdk-js `tool-builder.ts` internalTools, `hook-builder.ts`): build the generated `InternalToolsConfig` / `LifecycleHookConfig`; builders are values, so a base can be reused.
- Run state predicates (sdk-js `utils.ts`, Go `AgentRunState`): `AgentRunState.isTerminal`, `.isInterrupted`, `.isSettled`, `.isWorking`; `ToolInvocationStatus.isTerminal`; `ChatDTO.isAwaitingHuman`.
- `SilenceGate.hasHeardSound`: with `pass` false, tells "quiet for `tail` after sound" from "no sound yet", so the gate can end a tapped take after a pause.

Fixes:
- `AgentRunDTO.isActive` (and so `ChatDTO.isBusy`) counts a run in `auth_required` as holding the chat, as sdk-js `isChatBusy` does.

## 0.12.0

Added:
- `LiveTransport.http`: a `LiveDialer` that holds the client end of a socket over plain HTTP (`GET {socket}/stream` for the worker's frames, `POST {socket}/frames` for ours, one request at a time) instead of a WebSocket. For watchOS, which allows `URLSessionWebSocketTask` only while streaming audio or in a call (TN3135), and networks that drop the upgrade. Pass it as `OpenSocketOptions(dial: LiveTransport.http)`. `LiveTransport.webSocket` is the default. Needs relay-v4 (inference-sh/relay#4 and #5). It behaves as the WebSocket does:
  - It answers each of the relay's keepalives with a POST, as a WebSocket answers pings. The relay drops an end that posts nothing for 75s.
  - Frames sent while the app is still starting wait instead of ending the socket: the relay holds 64 and answers 429 with how many of a POST it took, and the rest go again in order. A POST carries at most 256 KB of queued frames (one frame at least).
  - When the app closes the socket while frames are on their way, `LiveEnd` carries the app's close code, not 1006 "the relay refused frames".
  - `close(code:reason:)` sends what a close frame can carry: a code outside 1000-1003, 1007-1013 and 3000-4999 goes as 1000, and the reason is cut to 123 bytes.
- `Examples/live-run` and `make live` take `TRANSPORT=http`. On Linux that is the way to run it: Foundation's WebSocket cannot dial there.

There is no 0.11.0 release. The tag 0.11.0 is on 55ab967, the commit before 0.10.1, and holds the same code.

## 0.10.1

Fixes:
- Types regenerated from the api: tasks no longer carry `app_variant` (api 880a9f23, e10803a9). 0.10.0 required it, so every `tasks.get`, `tasks.watch` and `tasks.run` against the current api failed to decode (`keyNotFound(app_variant)`).

## 0.10.0

Added:
- `InferenceAudio`, a second library product: audio for apps on top of the SDK (live dictation, push-to-talk to an agent, voice calls with stream apps, crash-safe long recordings), extracted from the inference.sh Apple app and the web app's live audio. `InferenceSDK` stays Foundation-only.
- Pure parts, on every platform including Linux: `PCM16` (PCM ↔ Float, peak, RMS, meter, up/downmix), `PCMFramer` (20 ms frames), `SilenceGate` (web app's gate: -66 dBFS, 6 s tail), `PCMResampler` with `LinearResampler` and `makeResampler`, `WAV` (header, decode), `WAVStreamParser` (reads Apple's `FLLR`/`JUNK` headers and files still being written), `WAVWriter`, `WAVFileTailer`, `LiveTranscript` (transcript from `text` patches: grow, full line, revised tail, `$clear`; final text from the result's `text`, `utterances`, `turns` or `segments`), `LiveSpeechPlan`/`LiveSpeechPlans`.
- `AudioSource` and `AudioSink` protocols, and `WAVFileSource`: a WAV file as a microphone, in real time.
- `LiveTranscriber`: an STT app's stream function fed from any source (captured at 16 kHz, resampled to the function's rate), the transcript, level and elapsed time on `updates`, the final text from `finish()`. Without a stream function, or when the session fails, the audio is transcribed with `SpeechToText` on `finish()`. Drops takes too short or silent to transcribe (`minimumDuration`, `minimumPeak`).
- `LiveVoiceCall`: a source and a sink wired to a `LiveSession` by the function's schemas: the microphone starts on `.state(.live)` through a `SilenceGate`, `.binary` plays, `.clear` flushes, `.ended` stops both; mute, levels, counts.
- `RecordingStore`, `RecordingManifest`, `SegmentWriter`, `CrashSafeRecorder`: headerless PCM segments synced every second, an atomic manifest, recovery after a crash (`recoverInterrupted`), interruptions as gaps, clips by sample range, joining to WAV, transcription in parts (`store.transcribe(_:with:)`).
- Apple (`#if canImport(AVFoundation)`): `Microphone` with two backends behind one API: an AVAudioEngine tap (optional voice processing, shareable engine) and AVAudioRecorder tailed as it writes, for Bluetooth HFP under PushToTalk, where an engine tap never fires; `.automatic` picks by route. `PCMPlayer` (60 ms jitter lead, restart from now after a gap, `flush` for `$clear`). `AudioSessionConfigurator` (voice chat, push-to-talk, record and playback presets; interruptions, route changes and media resets as async streams). `ConverterResampler` (AVAudioConverter). `AudioEncoder.encodeAAC`.
- `Examples/live-dictate` and `make dictate APP=xai/grok-stt` (`AUDIO_FILE=speech.wav` to feed a file, `BATCH=1` for the fallback); `make audio-e2e`: a voice call round trip with infsh/voice-loop.
- `Package.swift` declares watchOS 10.
- Chat settings: `client.updateChatSettings(chatId:_:)` (`POST /chats/{id}/settings`, answers `ChatSettingsDTO`) and `AgentChatSession.updateChatSettings(_:)`, which merges the answer into `state.chat` (reducer action `mergeChatSettings`, sdk-js `MERGE_CHAT_SETTINGS`).
- Always-allow options: `client.getAlwaysAllowOptions(chatId:toolInvocationId:)`, `client.alwaysAllowTool(chatId:toolInvocationId:option:)` (answers `AlwaysAllowResultDTO`) and the session's `getAlwaysAllowOptions(_:)` / `alwaysAllowTool(_:option:)`. A 409 (stale option) or 400 is thrown without marking the connection failed.
- `client.explainTool(chatId:toolInvocationId:)` and `AgentChatSession.explainTool(_:)`: a call awaiting approval in plain words, with its risk.

Deprecated:
- `alwaysAllowTool(…, toolName:)`: the api ignores `tool_name`; it saves the default option.

## 0.9.0

Added:
- Live (stream) functions, a port of sdk-js `live/` and `api/sockets.ts`. `client.live(_:)` starts a stream function and dials the socket its run response carries; `client.sockets` has `open` (a run response or a task id), `get`, `list`, `forTask`, `access` and `delete`.
- `LiveSession`: `events` is an `AsyncStream<LiveEvent>` (state changes, binary frames, JSON patches, `$clear`, `$error`, plain text); `sendBinary`, `sendPatch`, `sendField`, `sendText`, `close`, `ended`. It waits for the app's first frame, ends if the task ends first, and redials with a fresh credential on relay close codes 1012 and 1013 while waiting (up to five times). The socket is `URLSessionWebSocketTask` with the credential as a bearer header; `OpenSocketOptions(dial:)` takes another WebSocket (`LiveSocket`).
- Live schema helpers: `splitLiveSchema`, `binaryLiveField`, `isLiveField`, `parseMediaType`, `pcmFormat`, `alternativeTag`, `alternativeLabel`, and `LiveProtocol` for the wire constants.
- `tasks.watch(_:options:)`: follows a task that is already running until it ends, with `run`'s outcomes.
- `Examples/live-run` and `make live APP=...`: a live end-to-end check for stream functions.

Changes:
- `tasks.run` no longer opens the task stream for a task that has already ended when it is first read: it reports the task through `onUpdate` and settles.

Fixes:
- `apps.getByName("ns/app@version")` returns that version. It used to strip the suffix and return the current version, so `live-run` against a staged version read the wrong functions ("no stream function").

Verified on macOS against production: the four realtime STT apps (xai/grok-stt, openai/gpt-transcribe at 24 kHz, elevenlabs/stt, inworld/speech-to-text) stream a live transcript and complete; infsh/voice-loop echoes every binary frame back (476 sent, 476 received) and closes 1000 "done".

## 0.8.0

Breaking:
- `ChatDTO`, `ProjectDTO` and `ToolParameterProperty` are structs, no longer classes. Every generated type is a `Sendable` value type (gotypegen v0.8.2+, inference-sh/api#1468): struct-typed fields are `@Indirect`, stored in an immutable box, so values stay small (`ChatDTO` 392 bytes) and cycles like `ChatDTO.parent` still work. Code that mutated a `let` DTO needs `var`.
- Types regenerated from the api (AgentPermissions, policy kinds); `always_allowed_tools` and `usage_policy_id` removed.

Fixes:
- `ChatStreamEvent: Sendable` no longer warns in consumer builds.

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
