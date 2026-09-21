// Mirrors js/sdk-js/src/api/files.ts. Access as `client.files`.
//
// The transfer itself (create record → PUT to presigned URL) lives in
// InferenceClient.uploadFile, which predates this namespace and stays public;
// upload(_:) here delegates to it. The JS data-URI/base64 normalization is
// omitted — Swift callers hand over Data, there is nothing to normalize.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct FilesAPI: Sendable {
    let client: InferenceClient
    init(_ client: InferenceClient) { self.client = client }

    /// POST /files/list: cursor-paginated files.
    public func list(_ params: CursorListRequest? = nil) async throws -> CursorListResponse<FileDTO> {
        try await client.cursorList("files/list", params)
    }

    /// GET /files/{id}.
    public func get(_ fileId: String) async throws -> FileDTO {
        try await client.decode(client.send(client.request("files/\(fileId)", method: "GET")))
    }

    /// DELETE /files/{id}.
    public func delete(_ fileId: String) async throws {
        _ = try await client.send(client.request("files/\(fileId)", method: "DELETE"))
    }

    /// Two-step upload: POST /files mints the record + presigned URL, the
    /// bytes are PUT there. Returns the FileDTO whose `uri` goes into inputs.
    public func upload(_ data: Data, filename: String, contentType: String) async throws -> FileDTO {
        try await client.uploadFile(data, filename: filename, contentType: contentType)
    }
}

public extension InferenceClient {
    var files: FilesAPI { FilesAPI(self) }
}
