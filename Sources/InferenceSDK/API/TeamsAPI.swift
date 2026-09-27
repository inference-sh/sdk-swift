// Mirrors js/sdk-js/src/api/teams.ts. Access as `client.teams`.
//
// Divergences from JS, beyond the Response<T> unwrap shared by every API
// struct here (see ChatsAPI.swift):
// - `me` returns the generated MeResponse. sdk-js declares its own
//   interface typed with TeamRelationDTO; the server sends TeamDTO (plus org,
//   team_view and diagnostics) — go/api user.Handler.Me.
// - list/get/create/update return TeamDTO, which is what go/api
//   team.Handler sends; the JS signatures say TeamRelationDTO.
// - `view` (GET /teams/{id}/view → TeamViewDTO) is added; JS has no method.
// - updateMemberRole takes TeamMemberUpdateRoleRequest, the body the server
//   decodes, rather than a bare role string.
//
// Scopes: /me needs none; reads need `teams:read`, writes `teams:write`
// (go/api routes.go), plus the matching team capability for member,
// invite and profile changes.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct TeamsAPI: Sendable {
    let client: InferenceClient
    init(_ client: InferenceClient) { self.client = client }

    /// GET /me: the signed-in user and the team the credential acts as.
    public func me() async throws -> MeResponse {
        try await client.decode(client.send(client.request("me", method: "GET")))
    }

    /// GET /teams: the teams the user belongs to.
    public func list() async throws -> [TeamDTO] {
        try await client.decode(client.send(client.request("teams", method: "GET")))
    }

    /// GET /teams/{id}.
    public func get(_ teamId: String) async throws -> TeamDTO {
        try await client.decode(client.send(client.request("teams/\(teamId)", method: "GET")))
    }

    /// GET /teams/{id}/view: kind, governance and what the caller may do.
    public func view(_ teamId: String) async throws -> TeamViewDTO {
        try await client.decode(client.send(client.request("teams/\(teamId)/view", method: "GET")))
    }

    /// POST /teams.
    public func create(_ data: TeamCreateRequest) async throws -> TeamDTO {
        try await client.decode(client.send(client.request("teams", body: data)))
    }

    /// POST /teams/{id}: update the team's name, username and email. The api
    /// decodes its Team model here (no request type of its own), so all
    /// three are sent and all three are written.
    public func update(_ teamId: String, _ data: TeamCreateRequest) async throws -> TeamDTO {
        try await client.decode(client.send(client.request("teams/\(teamId)", body: data)))
    }

    /// DELETE /teams/{id}.
    public func delete(_ teamId: String) async throws {
        _ = try await client.send(client.request("teams/\(teamId)", method: "DELETE"))
    }

    /// GET /teams/check-username?username=….
    public func checkUsername(_ username: String) async throws -> AvailabilityResponse {
        try await client.decode(client.send(client.request(
            "teams/check-username", method: "GET", query: [URLQueryItem(name: "username", value: username)])))
    }

    /// GET /teams/{id}/members.
    public func getMembers(_ teamId: String) async throws -> [TeamMemberDTO] {
        try await client.decode(client.send(client.request("teams/\(teamId)/members", method: "GET")))
    }

    /// POST /teams/{id}/members.
    public func addMember(_ teamId: String, _ data: TeamMemberAddRequest) async throws -> TeamMemberDTO {
        try await client.decode(client.send(client.request("teams/\(teamId)/members", body: data)))
    }

    /// DELETE /teams/{id}/members/{userId}.
    public func removeMember(_ teamId: String, userId: String) async throws {
        _ = try await client.send(client.request("teams/\(teamId)/members/\(userId)", method: "DELETE"))
    }

    /// POST /teams/{id}/members/{userId}/role.
    public func updateMemberRole(_ teamId: String, userId: String, _ data: TeamMemberUpdateRoleRequest) async throws -> TeamMemberDTO {
        try await client.decode(client.send(client.request("teams/\(teamId)/members/\(userId)/role", body: data)))
    }

    /// GET /teams/{id}/invites.
    public func listInvites(_ teamId: String) async throws -> [TeamInviteDTO] {
        try await client.decode(client.send(client.request("teams/\(teamId)/invites", method: "GET")))
    }

    /// POST /teams/{id}/invites.
    public func createInvite(_ teamId: String, _ data: TeamInviteCreateRequest) async throws -> TeamInviteDTO {
        try await client.decode(client.send(client.request("teams/\(teamId)/invites", body: data)))
    }

    /// DELETE /teams/{id}/invites/{inviteId}.
    public func revokeInvite(_ teamId: String, inviteId: String) async throws {
        _ = try await client.send(client.request("teams/\(teamId)/invites/\(inviteId)", method: "DELETE"))
    }
}

public extension InferenceClient {
    var teams: TeamsAPI { TeamsAPI(self) }
}
