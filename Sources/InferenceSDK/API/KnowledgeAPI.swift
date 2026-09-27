// Mirrors js/sdk-js/src/api/knowledge.ts, the `KnowledgeAPI` class only.
// Access as `client.knowledge`.
//
// Divergences from JS, beyond the Response<T> unwrap shared by every API
// struct here (see ChatsAPI.swift):
// - `update` takes KnowledgeUpdateRequest (the body the api declares for
//   POST /knowledge/{id}) instead of Partial<KnowledgeDTO>: every KnowledgeDTO
//   field is non-optional in Swift, so a DTO would send them all.
// - `getVersion` returns KnowledgeDTO with that version loaded, which is what
//   the api sends (go/api KnowledgeHandler.GetVersion); the JS signature says
//   KnowledgeVersionDTO.
// - SkillsAPI from the same js file is not ported.
//
// Scopes: reads are public (visibility-filtered, no scope check); create,
// update, delete, transfer and visibility require `apps:write` on a scoped
// key or OAuth token (go/api routes.go), not `knowledge:write`.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct KnowledgeAPI: Sendable {
    let client: InferenceClient
    init(_ client: InferenceClient) { self.client = client }

    /// POST /knowledge/list: cursor-paginated knowledge entries.
    public func list(_ params: CursorListRequest? = nil) async throws -> CursorListResponse<KnowledgeDTO> {
        try await client.cursorList("knowledge/list", params)
    }

    /// GET /knowledge/{id}.
    public func get(_ id: String) async throws -> KnowledgeDTO {
        try await client.decode(client.send(client.request("knowledge/\(id)", method: "GET")))
    }

    /// GET /knowledge/{namespace}/{name}.
    public func getByName(namespace: String, name: String) async throws -> KnowledgeDTO {
        try await client.decode(client.send(client.request("knowledge/\(namespace)/\(name)", method: "GET")))
    }

    /// POST /knowledge: create an entry, or add a version to an existing one.
    ///
    /// For a plain markdown document put the text in `version.content.content`
    /// and leave `path`, `uri`, `size` and `hash` unset; the server stores it
    /// as `instructions.md` (`SKILL.md` for type skill) and fills them in:
    ///
    ///     KnowledgeCreateRequest(
    ///         name: "meeting-2026-09-27",          // a 400 names the rule and a fixed form
    ///         description: "Standup transcript",
    ///         type: .observation,                  // the default when omitted
    ///         version: KnowledgeVersionInput(content: KnowledgeFile(content: markdown)))
    ///
    /// The entry lands in the caller's team namespace. Posting an existing
    /// name adds a new version to that entry (identical content returns the
    /// entry unchanged); a new name creates one. Extra files go in
    /// `version.files`, each with `path` and `content` (or an uploaded `uri`).
    public func create(_ data: KnowledgeCreateRequest) async throws -> KnowledgeDTO {
        try await client.decode(client.send(client.request("knowledge", body: data)))
    }

    /// POST /knowledge/{id}: update entry fields (title, description). To
    /// change the content, `create` again with the same name.
    public func update(_ id: String, _ data: KnowledgeUpdateRequest) async throws -> KnowledgeDTO {
        try await client.decode(client.send(client.request("knowledge/\(id)", body: data)))
    }

    /// DELETE /knowledge/{id}.
    public func delete(_ id: String) async throws {
        _ = try await client.send(client.request("knowledge/\(id)", method: "DELETE"))
    }

    /// POST /knowledge/{id}/versions/list: cursor-paginated versions.
    public func listVersions(_ id: String, _ params: CursorListRequest? = nil) async throws -> CursorListResponse<KnowledgeVersionDTO> {
        try await client.cursorList("knowledge/\(id)/versions/list", params)
    }

    /// GET /knowledge/{id}/versions/{versionId}: the entry with that version loaded.
    public func getVersion(_ id: String, _ versionId: String) async throws -> KnowledgeDTO {
        try await client.decode(client.send(client.request("knowledge/\(id)/versions/\(versionId)", method: "GET")))
    }

    /// POST /knowledge/{id}/transfer: move ownership to another team.
    public func transferOwnership(_ id: String, newTeamId: String) async throws -> KnowledgeDTO {
        try await client.decode(client.send(client.request("knowledge/\(id)/transfer", body: TeamBody(teamId: newTeamId))))
    }

    /// POST /knowledge/{id}/visibility.
    public func updateVisibility(_ id: String, visibility: String) async throws -> KnowledgeDTO {
        try await client.decode(client.send(client.request("knowledge/\(id)/visibility", body: SetVisibilityRequest(visibility: visibility))))
    }
}

public extension InferenceClient {
    var knowledge: KnowledgeAPI { KnowledgeAPI(self) }
}
