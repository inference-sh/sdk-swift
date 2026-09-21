// Mirrors js/sdk-js/src/api/search.ts. Access as `client.search`.
//
// Divergence from JS, shared by every API struct here: methods return the
// decoded DTO directly instead of a `Response<T>` envelope — `decode` unwraps
// `{data, messages}` and routes `messages` to `client.onMessage`.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SearchAPI: Sendable {
    let client: InferenceClient
    init(_ client: InferenceClient) { self.client = client }

    /// POST /suggest: unified search across skills, knowledge, and apps.
    public func suggest(_ params: SuggestRequest) async throws -> SuggestResponse {
        try await client.decode(client.send(client.request("suggest", body: params)))
    }

    /// POST /search: full-text search via Meilisearch. The js return type is
    /// `unknown`, so the payload is decoded as JSONValue.
    public func search(q: String, type: String? = nil, limit: Int? = nil) async throws -> JSONValue {
        try await client.decode(client.send(client.request("search", body: SearchBody(q: q, type: type, limit: limit))))
    }
}

// MARK: - Request bodies (ad-hoc object literals in the js source)

private struct SearchBody: Encodable {
    let q: String
    let type: String?
    let limit: Int?
}

// MARK: - Namespace (js: client.search)

public extension InferenceClient {
    var search: SearchAPI { SearchAPI(self) }
}
