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

    /// Streams every asset visible to the API key's user. By default the server
    /// excludes hidden assets (e.g., motion videos of Live Photos); pass an explicit
    /// `visibility` to filter to a single class, or call repeatedly across cases of
    /// `AssetVisibility` and merge to get a complete view.
    public func listAllAssets(
        includeTrashed: Bool = false,
        visibility: AssetVisibility? = nil,
        pageSize: Int = 1000
    ) async throws -> [ServerAsset] {
        var out: [ServerAsset] = []
        var page = 1
        while true {
            var body: [String: Any] = [
                "page": page,
                "size": pageSize,
                "withDeleted": includeTrashed,
                "withExif": false,
            ]
            if let visibility {
                body["visibility"] = visibility.rawValue
            }
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

    /// Restores specific assets from trash by their UUIDs. Server is idempotent for
    /// assets that aren't currently trashed, so callers don't need to pre-filter.
    public func restoreAssets(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        var req = try makeRequest(method: "POST", path: "trash/restore/assets")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["ids": ids]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        try Self.expectOK(resp, data: data)
    }

    // MARK: - Tags (breadcrumbs)

    /// Creates (or returns existing) tag. Immich's POST /tags is upsert-by-value.
    public func upsertTag(value: String) async throws -> ImmichTag {
        let body: [String: Any] = ["name": value]
        let dto: TagDTO = try await postJSON(path: "tags", jsonObject: body)
        return dto.asImmichTag
    }

    /// Lists every tag visible to the API key's user. Requires `tag.read` scope.
    public func listTags() async throws -> [ImmichTag] {
        let req = try makeRequest(method: "GET", path: "tags")
        let (data, resp) = try await session.data(for: req)
        try Self.expectOK(resp, data: data)
        let dtos = try JSONDecoder().decode([TagDTO].self, from: data)
        return dtos.map(\.asImmichTag)
    }

    /// Every asset attached to a given tag, across every non-locked visibility
    /// class (timeline/archive/hidden) and including trashed ones by default.
    /// Search by tagIds honors the default visibility filter on the server,
    /// so a naive single query misses Live Photo motion videos (visibility
    /// `hidden`). We iterate and merge. `locked` is intentionally skipped —
    /// listing it requires an elevated auth flow our API key doesn't have.
    public func assetsForTag(
        tagId: String,
        includeTrashed: Bool = true,
        pageSize: Int = 1000
    ) async throws -> [ServerAsset] {
        var out: [ServerAsset] = []
        var seen: Set<String> = []
        for visibility in [AssetVisibility.timeline, .archive, .hidden] {
            var page = 1
            while true {
                let body: [String: Any] = [
                    "page": page,
                    "size": pageSize,
                    "withDeleted": includeTrashed,
                    "withExif": false,
                    "tagIds": [tagId],
                    "visibility": visibility.rawValue,
                ]
                let result: SearchResponseDTO = try await postJSON(path: "search/metadata", jsonObject: body)
                for asset in result.assets.items.map(\.asServerAsset) where !seen.contains(asset.id) {
                    out.append(asset)
                    seen.insert(asset.id)
                }
                guard let nextString = result.assets.nextPage, let nextPage = Int(nextString) else { break }
                page = nextPage
            }
        }
        return out
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
    let color: String?
    let createdAt: String?

    var asImmichTag: ImmichTag {
        let date = createdAt.flatMap { Self.parseISO8601($0) }
        return ImmichTag(id: id, value: value, color: color, createdAt: date)
    }

    /// Immich sends timestamps in both `2026-04-21T00:00:00Z` and
    /// `2026-04-21T00:00:00.000Z` forms depending on the endpoint. Try both.
    private static func parseISO8601(_ string: String) -> Date? {
        let withFractions = ISO8601DateFormatter()
        withFractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractions.date(from: string) { return d }
        return ISO8601DateFormatter().date(from: string)
    }
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
