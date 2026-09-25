// Mirrors js/sdk-js/src/api/files.ts. Access as `client.files`.
//
// The JS data-URI/base64 normalization is omitted — Swift callers hand over
// Data, there is nothing to normalize.

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
        let create = FileCreateRequest(files: [PartialFile(uri: "", contentType: contentType, size: data.count, filename: filename)])
        let files: [FileDTO] = try await client.decode(client.send(client.request("files", body: create)))
        guard let file = files.first, let uploadURL = URL(string: file.uploadUrl) else {
            throw InferenceError.transport("POST /files returned no upload_url")
        }
        var put = URLRequest(url: uploadURL)
        put.httpMethod = "PUT"
        put.setValue(contentType, forHTTPHeaderField: "Content-Type")
        put.setValue("", forHTTPHeaderField: "Expect") // R2 resets on 100-continue
        put.timeoutInterval = 300
        _ = try await client.send(put, upload: data, retries: 2)
        return file
    }
}

public extension InferenceClient {
    var files: FilesAPI { FilesAPI(self) }
}
