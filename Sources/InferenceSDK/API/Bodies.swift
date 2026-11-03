// Ad-hoc request bodies shared by several API files (the js source inlines
// them as object literals per call site; three drifting Swift copies of each
// is worse than one).

import Foundation

struct TeamBody: Encodable {
    let teamId: String
    enum CodingKeys: String, CodingKey { case teamId = "team_id" }
}

// MARK: - Update bodies (js/sdk-js/src/api/write-bodies.ts)
//
// Each names exactly the fields its route writes; a nil field is left out of
// the JSON and keeps its stored value. The API checks every key of a write
// body against the route's writable fields (go/api docs/writable-fields.md)
// and, in enforce mode, answers 400 validation_error to an unknown key, a
// relation (user, team, project, ...) or a read-only field whose value
// differs from the stored one. Do not send a fetched DTO back.

/// POST /agents/{id}. Images, and a new version when `version` is set.
/// Visibility: `agents.updateVisibility`. Name, title, harness, placement:
/// set at creation. Owner: `agents.transferOwnership`.
public struct AgentUpdateBody: Encodable, Sendable {
    public var images: ResourceImages?
    public var version: AgentConfigInput?

    public init(images: ResourceImages? = nil, version: AgentConfigInput? = nil) {
        self.images = images
        self.version = version
    }
}

/// PATCH /apps/{id}: the app's copy. `images` replaces the stored set
/// whole. Visibility: `apps.updateVisibility`; status: `apps.updateStatus`;
/// name, namespace and version contents: a deploy.
public struct AppPatchBody: Encodable, Sendable {
    public var title: String?
    public var description: String?
    public var agentDescription: String?
    public var category: AppCategory?
    public var images: ResourceImages?
    public var tags: [String]?

    public init(title: String? = nil, description: String? = nil, agentDescription: String? = nil,
                category: AppCategory? = nil, images: ResourceImages? = nil, tags: [String]? = nil) {
        self.title = title
        self.description = description
        self.agentDescription = agentDescription
        self.category = category
        self.images = images
        self.tags = tags
    }

    enum CodingKeys: String, CodingKey {
        case title, description, category, images, tags
        case agentDescription = "agent_description"
    }
}

/// POST /apps/{id}. The app's copy (as AppPatchBody), plus an in-place edit
/// of the version `versionId` names: its metadata, required secrets and
/// required credentials.
public struct AppUpdateBody: Encodable, Sendable {
    public var patch: AppPatchBody
    public var versionId: String?
    public var version: AppVersionDTO?

    public init(_ patch: AppPatchBody = AppPatchBody(), versionId: String? = nil, version: AppVersionDTO? = nil) {
        self.patch = patch
        self.versionId = versionId
        self.version = version
    }

    enum CodingKeys: String, CodingKey {
        case versionId = "version_id"
        case version
    }

    public func encode(to encoder: Encoder) throws {
        try patch.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(versionId, forKey: .versionId)
        try c.encodeIfPresent(version, forKey: .version)
    }
}

/// PATCH /chats/{id}. Name and description. Visibility and the chat's
/// settings: `updateChatSettings`.
public struct ChatUpdateBody: Encodable, Sendable {
    public var name: String?
    public var description: String?

    public init(name: String? = nil, description: String? = nil) {
        self.name = name
        self.description = description
    }
}

/// PATCH /teams/{id}. The team's profile. The username is the team's
/// namespace and does not change here; status and concurrency are platform
/// staff's.
public struct TeamUpdateBody: Encodable, Sendable {
    public var name: String?
    public var email: String?
    public var avatarUrl: String?

    public init(name: String? = nil, email: String? = nil, avatarUrl: String? = nil) {
        self.name = name
        self.email = email
        self.avatarUrl = avatarUrl
    }

    enum CodingKeys: String, CodingKey {
        case name, email
        case avatarUrl = "avatar_url"
    }
}
