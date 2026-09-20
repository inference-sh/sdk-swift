// Mirrors js/sdk-js/src/api/agents.ts, the `AgentsAPI` class only. Access as
// `client.agents`.
//
// Skipped from the js file:
// - The legacy `Agent` runner class and `AgentsAPI.create` — superseded by the
//   agent/ session module (see ChatAPI.swift / ChatStream.swift).
// - `submitToolResult` and `resolveInterrupt` — the same endpoints already
//   exist on InferenceClient in ChatAPI.swift (mirror of js agent/api.ts).
//
// Divergence from JS, shared by every API struct here: methods return the
// decoded DTO directly instead of a `Response<T>` envelope — `decode` unwraps
// `{data, messages}` and routes `messages` to `client.onMessage`.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AgentsAPI: Sendable {
    let client: InferenceClient
    init(_ client: InferenceClient) { self.client = client }

    // MARK: - Agent template CRUD (stored agent configurations)

    /// POST /agents/list: cursor-paginated agent templates.
    public func list(_ params: CursorListRequest? = nil) async throws -> CursorListResponse<AgentDTO> {
        try await client.decode(client.send(client.request("agents/list", body: params ?? CursorListRequest(cursor: ""))))
    }

    /// GET /agents/{id}.
    public func get(_ agentId: String) async throws -> AgentDTO {
        try await client.decode(client.send(client.request("agents/\(agentId)", method: "GET")))
    }

    /// POST /agents: create an agent template or a new version of an existing one.
    public func createAgent(_ data: CreateAgentRequest) async throws -> AgentDTO {
        try await client.decode(client.send(client.request("agents", body: data)))
    }

    /// POST /agents/{id}: update agent template fields.
    public func update(_ agentId: String, _ data: AgentDTO) async throws -> AgentDTO {
        try await client.decode(client.send(client.request("agents/\(agentId)", body: data)))
    }

    /// DELETE /agents/{id}.
    public func delete(_ agentId: String) async throws {
        _ = try await client.send(client.request("agents/\(agentId)", method: "DELETE"))
    }

    /// POST /agents/{id}/duplicate: copy an agent template.
    public func duplicate(_ agentId: String) async throws -> AgentDTO {
        try await client.decode(client.send(client.request("agents/\(agentId)/duplicate")))
    }

    /// POST /agents/{id}/versions/list: cursor-paginated template versions.
    public func listVersions(_ agentId: String, _ params: CursorListRequest? = nil) async throws -> CursorListResponse<AgentVersionDTO> {
        try await client.decode(client.send(client.request("agents/\(agentId)/versions/list", body: params ?? CursorListRequest(cursor: ""))))
    }

    /// POST /agents/{id}/transfer: move ownership to another team.
    public func transferOwnership(_ agentId: String, newTeamId: String) async throws -> AgentDTO {
        try await client.decode(client.send(client.request("agents/\(agentId)/transfer", body: TeamBody(teamId: newTeamId))))
    }

    /// POST /agents/{id}/visibility.
    public func updateVisibility(_ agentId: String, visibility: String) async throws -> AgentDTO {
        try await client.decode(client.send(client.request("agents/\(agentId)/visibility", body: VisibilityBody(visibility: visibility))))
    }

    /// GET /agents/{id}/versions/{versionId}.
    public func getVersion(_ agentId: String, _ versionId: String) async throws -> AgentVersionDTO {
        try await client.decode(client.send(client.request("agents/\(agentId)/versions/\(versionId)", method: "GET")))
    }

    /// GET /agents/{namespace}/{name}: look up an agent by its qualified name.
    public func getByName(namespace: String, name: String) async throws -> AgentDTO {
        try await client.decode(client.send(client.request("agents/\(namespace)/\(name)", method: "GET")))
    }

    /// GET /agents/internal-tools: internal tool categories available to agents.
    public func getInternalTools() async throws -> [InternalToolDefinition] {
        try await client.decode(client.send(client.request("agents/internal-tools", method: "GET")))
    }

    /// GET /agents/{id}/card: A2A protocol agent card. Raw JSON — not wrapped
    /// in the V3 envelope — so it is decoded directly, not via `client.decode`.
    public func getA2ACard(_ agentId: String) async throws -> [String: JSONValue] {
        let data = try await client.send(client.request("agents/\(agentId)/card", method: "GET"))
        return try InferenceClient.decoder.decode([String: JSONValue].self, from: data)
    }

    /// GET /agent-runs/{id}/interrupts: pending interrupt gates on an agent run.
    public func listRunInterrupts(_ runId: String) async throws -> [InterruptDTO] {
        try await client.decode(client.send(client.request("agent-runs/\(runId)/interrupts", method: "GET")))
    }
}

/// js `InternalToolDefinition` — declared in agents.ts, not in the generated
/// types, so it lives here instead of Types.swift.
public struct InternalToolDefinition: Codable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let tools: [String]
    public let scope: String
    /// What this category resolves to when the agent's flag is unset. Opt-in
    /// categories default false; render switches from this rather than assume.
    public let defaultEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, description, tools, scope
        case defaultEnabled = "default_enabled"
    }
}

// MARK: - Request bodies (ad-hoc object literals in the js source)

private struct TeamBody: Encodable {
    let teamId: String
    enum CodingKeys: String, CodingKey { case teamId = "team_id" }
}

private struct VisibilityBody: Encodable {
    let visibility: String
    enum CodingKeys: String, CodingKey { case visibility }
}

// MARK: - Namespace (js: client.agents)

public extension InferenceClient {
    var agents: AgentsAPI { AgentsAPI(self) }
}
