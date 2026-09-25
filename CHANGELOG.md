# Changelog

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
