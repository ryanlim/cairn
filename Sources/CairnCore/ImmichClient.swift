import Foundation

public enum ImmichClientError: Error, CustomStringConvertible {
    case httpStatus(Int, body: String)
    case unexpectedResponse(String)
    case invalidURL

    public var description: String {
        switch self {
        case .httpStatus(let code, let body):
            return "HTTP \(code): \(body.prefix(500))"
        case .unexpectedResponse(let msg):
            return "unexpected response: \(msg)"
        case .invalidURL:
            return "invalid URL"
        }
    }
}

public struct ImmichClient: Sendable {
    public let baseURL: URL
    public let apiKey: String
    private let session: URLSession

    public init(baseURL: URL, apiKey: String, session: URLSession = .shared) {
        self.baseURL = Self.normalize(baseURL)
        self.apiKey = apiKey
        self.session = session
    }

    /// Immich serves its API under `/api`. Accept either form from callers —
    /// `https://host/` and `https://host/api/` should both work.
    static func normalize(_ url: URL) -> URL {
        let path = url.path
        if path.hasSuffix("/api") || path.hasSuffix("/api/") {
            return url
        }
        return url.appending(path: "api")
    }

    // MARK: - Ping / verify

    public struct PingResponse: Decodable, Sendable { public let res: String }

    public func ping() async throws -> String {
        let req = try makeRequest(method: "GET", path: "server/ping")
        let (data, resp) = try await session.data(for: req)
        try Self.expectOK(resp, data: data)
        return try JSONDecoder().decode(PingResponse.self, from: data).res
    }

    // MARK: - List assets (paginated)

    /// Streams every asset visible to the API key's user. Set `includeTrashed: true`
    /// if you want trashed assets in the result (we usually don't).
    public func listAllAssets(includeTrashed: Bool = false, pageSize: Int = 1000) async throws -> [ServerAsset] {
        var out: [ServerAsset] = []
        var page = 1
        while true {
            let body: [String: Any] = [
                "page": page,
                "size": pageSize,
                "withDeleted": includeTrashed,
                "withExif": false,
            ]
            let result: SearchResponseDTO = try await postJSON(path: "search/metadata", jsonObject: body)
            out.append(contentsOf: result.assets.items.map(\.asServerAsset))
            guard let nextString = result.assets.nextPage, let nextPage = Int(nextString) else { break }
            page = nextPage
        }
        return out
    }

    // MARK: - Trash

    /// Moves the given assets to Immich trash. `force: false` is the trash path; never call with `force: true` from this app.
    public func trashAssets(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        var req = try makeRequest(method: "DELETE", path: "assets")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["ids": ids, "force": false]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        try Self.expectOK(resp, data: data)
    }

    // MARK: - Tags (breadcrumbs)

    /// Creates (or returns existing) tag. Immich's POST /tags is upsert-by-value.
    public func upsertTag(value: String) async throws -> ImmichTag {
        let body: [String: Any] = ["name": value]
        let dto: TagDTO = try await postJSON(path: "tags", jsonObject: body)
        return ImmichTag(id: dto.id, value: dto.value)
    }

    public func bulkTagAssets(tagIds: [String], assetIds: [String]) async throws {
        guard !tagIds.isEmpty, !assetIds.isEmpty else { return }
        var req = try makeRequest(method: "PUT", path: "tags/assets")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["tagIds": tagIds, "assetIds": assetIds]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        try Self.expectOK(resp, data: data)
    }

    // MARK: - HTTP plumbing

    private func makeRequest(method: String, path: String) throws -> URLRequest {
        let url = baseURL.appending(path: path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        return req
    }

    private func postJSON<T: Decodable>(path: String, jsonObject: [String: Any]) async throws -> T {
        var req = try makeRequest(method: "POST", path: path)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: jsonObject)
        let (data, resp) = try await session.data(for: req)
        try Self.expectOK(resp, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func expectOK(_ resp: URLResponse, data: Data) throws {
        guard let http = resp as? HTTPURLResponse else {
            throw ImmichClientError.unexpectedResponse("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ImmichClientError.httpStatus(http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
    }
}

// MARK: - Internal DTOs

struct SearchResponseDTO: Decodable {
    let assets: AssetGroupDTO
    struct AssetGroupDTO: Decodable {
        let items: [AssetItemDTO]
        let nextPage: String?
    }
}

struct TagDTO: Decodable {
    let id: String
    let value: String
}

struct AssetItemDTO: Decodable {
    let id: String
    let checksum: String
    let livePhotoVideoId: String?
    let isTrashed: Bool

    var asServerAsset: ServerAsset {
        ServerAsset(
            id: id,
            checksum: Checksum(base64: checksum),
            livePhotoVideoId: livePhotoVideoId,
            isTrashed: isTrashed
        )
    }
}
