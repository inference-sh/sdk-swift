// Mirrors js/sdk-js/src/api/apps.ts. Access as `client.apps`.
//
// Divergence from JS, shared by every API struct here: methods return the
// decoded DTO directly instead of a `Response<T>` envelope — `decode` unwraps
// `{data, messages}` and routes `messages` to `client.onMessage`.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AppsAPI: Sendable {
    let client: InferenceClient
    init(_ client: InferenceClient) { self.client = client }

    /// POST /apps/list: cursor-paginated apps.
    public func list(_ params: CursorListRequest? = nil) async throws -> CursorListResponse<AppDTO> {
        try await client.cursorList("apps/list", params)
    }

    /// GET /apps/{id}.
    public func get(_ appId: String) async throws -> AppDTO {
        try await client.decode(client.send(client.request("apps/\(appId)", method: "GET")))
    }

    /// GET /apps/{id}/versions/{versionId}: the app resolved at a specific version.
    public func getByVersionId(_ appId: String, _ versionId: String) async throws -> AppDTO {
        try await client.decode(client.send(client.request("apps/\(appId)/versions/\(versionId)", method: "GET")))
    }

    /// POST /apps: create a new app.
    public func create(_ data: AppDTO) async throws -> AppDTO {
        try await client.decode(client.send(client.request("apps", body: data)))
    }

    /// POST /apps/{id}: update app fields.
    public func update(_ appId: String, _ data: AppDTO) async throws -> AppDTO {
        try await client.decode(client.send(client.request("apps/\(appId)", body: data)))
    }

    /// DELETE /apps/{id}.
    public func delete(_ appId: String) async throws {
        _ = try await client.send(client.request("apps/\(appId)", method: "DELETE"))
    }

    /// POST /apps/{id}/duplicate: copy an app.
    public func duplicate(_ appId: String) async throws -> AppDTO {
        try await client.decode(client.send(client.request("apps/\(appId)/duplicate")))
    }

    /// POST /apps/{id}/versions/list: cursor-paginated app versions.
    public func listVersions(_ appId: String, _ params: CursorListRequest? = nil) async throws -> CursorListResponse<AppVersionDTO> {
        try await client.cursorList("apps/\(appId)/versions/list", params)
    }

    /// POST /apps/{id}/transfer: move ownership to another team.
    public func transferOwnership(_ appId: String, newTeamId: String) async throws -> AppDTO {
        try await client.decode(client.send(client.request("apps/\(appId)/transfer", body: TeamBody(teamId: newTeamId))))
    }

    /// POST /apps/{id}/visibility.
    public func updateVisibility(_ appId: String, visibility: String) async throws -> AppDTO {
        try await client.decode(client.send(client.request("apps/\(appId)/visibility", body: VisibilityBody(visibility: visibility))))
    }

    /// POST /apps/{id}/status: update app lifecycle status. `message` is dropped when nil.
    public func updateStatus(_ appId: String, status: String, message: String? = nil) async throws -> AppDTO {
        try await client.decode(client.send(client.request("apps/\(appId)/status", body: StatusBody(status: status, message: message))))
    }

    /// GET /apps/{name}: look up an app by qualified name (e.g.
    /// "inference/claude-haiku"). Delegates to the pre-existing getApp, which
    /// also strips an "@version" suffix and retries once.
    public func getByName(_ name: String) async throws -> AppDTO {
        try await client.getApp(name)
    }

    /// GET /apps/{id}/license: the app's license record.
    public func getLicense(_ appId: String) async throws -> LicenseRecordDTO {
        try await client.decode(client.send(client.request("apps/\(appId)/license", method: "GET")))
    }

    /// POST /apps/{id}/license: save the app's license text.
    public func saveLicense(_ appId: String, license: String) async throws -> LicenseRecordDTO {
        try await client.decode(client.send(client.request("apps/\(appId)/license", body: LicenseBody(license: license))))
    }

    /// PUT /apps/{id}/versions/{versionId}/current: set the active version.
    public func setCurrentVersion(_ appId: String, _ versionId: String) async throws -> AppDTO {
        try await client.decode(client.send(client.request("apps/\(appId)/versions/\(versionId)/current", method: "PUT")))
    }
}

// MARK: - Request bodies (ad-hoc object literals in the js source)

// TeamBody/VisibilityBody are shared — see Bodies.swift.

private struct StatusBody: Encodable {
    let status: String
    let message: String?
}

private struct LicenseBody: Encodable {
    let license: String
}

// MARK: - Namespace (js: client.apps)

public extension InferenceClient {
    var apps: AppsAPI { AppsAPI(self) }
}
