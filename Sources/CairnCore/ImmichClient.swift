import Foundation

/// Errors surfaced by `ImmichClient` and `ImmichThumbnailLoader`. The
/// `httpStatus` body is truncated by `description` to keep logs legible;
/// callers that need the full body should pattern-match directly.
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

    /// HTTP status code if this is an `httpStatus` case; nil for
    /// `unexpectedResponse` and `invalidURL`. Convenience accessor so
    /// orchestrators can populate `trashFailed.httpStatus` /
    /// `restoreFailed.httpStatus` without re-pattern-matching.
    public var httpStatusCode: Int? {
        if case .httpStatus(let code, _) = self { return code }
        return nil
    }

    /// Lift an arbitrary `Error` into an HTTP status code when it
    /// happens to be an `ImmichClientError.httpStatus`. Returns nil
    /// for transport-level errors (DNS, TLS, network unreachable),
    /// decoding errors, or any other non-Immich error type.
    public static func httpStatus(from error: any Error) -> Int? {
        (error as? ImmichClientError)?.httpStatusCode
    }
}

/// Thin HTTP client over the subset of Immich's REST API that cairn's
/// reconciliation pipeline touches. Value type; safe to pass between
/// actors. `URLSession` handles connection pooling so constructing
/// fresh instances on credential rotation is cheap.
///
/// Authentication is `x-api-key` on every request. The API key's scope
/// determines which endpoints work: `asset.read`, `asset.delete`,
/// `tag.create`, and `tag.asset` cover the trash/restore path;
/// `tag.read` is additionally required for history reconstruction.
public struct ImmichClient: Sendable {
    public let baseURL: URL
    public let apiKey: String
    private let session: URLSession

    public init(baseURL: URL, apiKey: String, session: URLSession = .shared) {
        self.baseURL = Self.normalize(baseURL)
        self.apiKey = apiKey
        self.session = session
    }

    /// Build a `URLSession` with timeouts and connectivity behavior
    /// suited to the iOS app. Two changes from `URLSession.shared`:
    ///
    /// - **`waitsForConnectivity = false`**: the default on iOS 11+
    ///   is `true`, which makes a request in airplane mode wait
    ///   silently up to `timeoutIntervalForResource` (7 days!) for
    ///   connectivity to return. We want fast failure with
    ///   `URLError.notConnectedToInternet` instead, so the user
    ///   sees a clear error and the persistent retry queue can
    ///   take over.
    /// - **Tighter request timeout**: 30 seconds rather than the
    ///   60-second default. Self-hosted Immich servers should
    ///   respond well under that. A user on a flaky network
    ///   getting one slow page will see the error sooner.
    ///
    /// CLI usage continues to use `URLSession.shared` because CLI
    /// users can ctrl-c, and CLI workflows (cron, scripts) often
    /// run in environments where waiting is fine.
    public static func makeAppURLSession(timeoutSeconds: TimeInterval = 30) -> URLSession {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = timeoutSeconds
        return URLSession(configuration: config)
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

    /// Parse + sanitize a user-entered server URL string. Handles the
    /// common input mistakes:
    ///
    ///   - Missing scheme (`"immich.example.com"`) → assumes `https://`.
    ///     Typed bare hostnames should "just work" since iPhone users
    ///     rarely type schemes.
    ///   - Whitespace around the URL → trimmed.
    ///   - Trailing slashes → preserved; `normalize` handles either form.
    ///   - `http://` — accepted as-is (legit for home-LAN installs like
    ///     `http://immich.local:2283`); we never silently upgrade to
    ///     `https`, since that'd break those setups.
    ///   - Anything with no parseable host, or with a scheme other than
    ///     http/https → `nil`. Caller surfaces "Invalid URL" to the user.
    ///
    /// Returns a `URL` suitable for `ImmichClient.init(baseURL:)` — no
    /// `/api` appending yet; the init's `normalize` does that.
    public static func parseServerURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: String
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            candidate = trimmed
        } else if trimmed.contains("://") {
            // Some other scheme typed explicitly (ftp://, ws://, file://).
            // Reject outright — these aren't valid Immich endpoints and a
            // silent upgrade would mask a user typo.
            return nil
        } else {
            candidate = "https://" + trimmed
        }

        guard let url = URL(string: candidate),
              let host = url.host,
              !host.isEmpty,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return nil
        }
        return url
    }

    // MARK: - Ping / verify

    /// Decoded body of `GET /server/ping` — a tiny `{"res": "pong"}`.
    /// Internal — `ping()` returns the unwrapped `res` string, no caller
    /// outside this file needs the DTO.
    private struct PingResponse: Decodable { let res: String }

    /// Confirms the server is reachable and the API key authenticates.
    /// Returns the `res` field ("pong" on a healthy server).
    ///
    /// Note: we deliberately do **not** send `Accept: application/json`
    /// here. Immich's `/server/ping` responds with `text/html` and
    /// returns `406 Not Acceptable` when JSON is explicitly requested.
    /// `makeRequest` accordingly sets no Accept header.
    public func ping() async throws -> String {
        let req = try makeRequest(method: "GET", path: "server/ping")
        let (data, resp) = try await session.data(for: req)
        try Self.expectOK(resp, data: data)
        return try JSONDecoder().decode(PingResponse.self, from: data).res
    }

    // MARK: - API key introspection

    public struct ApiKeyInfo: Sendable, Codable {
        public let id: String
        public let name: String
        public let permissions: [String]
    }

    public func apiKeyInfo() async throws -> ApiKeyInfo {
        let req = try makeRequest(method: "GET", path: "api-keys/me")
        let (data, resp) = try await session.data(for: req)
        try Self.expectOK(resp, data: data)
        return try JSONDecoder().decode(ApiKeyInfo.self, from: data)
    }

    // MARK: - Server identity (for per-user partitioning)

    /// The Immich user the current API key authenticates as. Used as the
    /// stable per-user discriminator in cairn's partition key — paired
    /// with server URL, this lets multiple Immich accounts on the same
    /// server URL get isolated journal/runs/Observed state on the same
    /// device.
    ///
    /// `id` is the canonical Immich user UUID — stable across email and
    /// username changes. `email` is human-readable, useful as a label
    /// when debugging filesystem layout. Cairn caches both at setup
    /// time and uses `id` as the partition discriminator going forward;
    /// network access isn't required at app launch once cached.
    public struct UserIdentity: Sendable, Codable, Equatable {
        public let id: String
        public let email: String
        public let name: String?

        public init(id: String, email: String, name: String? = nil) {
            self.id = id
            self.email = email
            self.name = name
        }
    }

    public func usersMe() async throws -> UserIdentity {
        let req = try makeRequest(method: "GET", path: "users/me")
        let (data, resp) = try await session.data(for: req)
        try Self.expectOK(resp, data: data)
        return try JSONDecoder().decode(UserIdentity.self, from: data)
    }

    /// Permissions cairn requires for full functionality. Declared once
    /// so the UI, bootstrap check, and documentation stay in sync.
    public static let requiredPermissions: [String] = [
        "asset.read",
        "asset.delete",
        "asset.view",
        "asset.download",
        "tag.create",
        "tag.read",
        "tag.asset",
    ]

    /// Permissions that enhance functionality but aren't essential.
    public static let optionalPermissions: [String] = [
        "asset.statistics",
    ]

    public static func missingPermissions(granted: [String]) -> [String] {
        let grantedSet = Set(granted)
        if grantedSet.contains("all") { return [] }
        return requiredPermissions.filter { !grantedSet.contains($0) }
    }

    // MARK: - List assets (paginated)

    /// Streams every asset visible to the API key's user via
    /// `POST /api/search/metadata`, paginated by `pageSize`. Results are
    /// accumulated into one array; large libraries should expect
    /// tens-of-megabytes memory footprint during the call.
    ///
    /// `visibility` defaults to nil (server default: excludes `hidden`),
    /// which omits Live Photo motion videos. To reconstruct a full view,
    /// call once per `AssetVisibility` case and merge on asset `id`, or
    /// use `assetsForTag` which already does this for tag scoping.
    ///
    /// `includeTrashed: true` sets `withDeleted` so restored-candidate
    /// detection can see trashed assets. `withExif: false` — we never
    /// need EXIF; skipping it keeps the wire payload small.
    public func listAllAssets(
        includeTrashed: Bool = false,
        visibility: AssetVisibility? = nil,
        pageSize: Int = 1000,
        maxRetries: Int = 2
    ) async throws -> [ServerAsset] {
        var out: [ServerAsset] = []
        var page = 1
        while true {
            try Task.checkCancellation()
            var body: [String: Any] = [
                "page": page,
                "size": pageSize,
                "withDeleted": includeTrashed,
                "withExif": false,
            ]
            if let visibility {
                body["visibility"] = visibility.rawValue
            }
            var lastError: Error?
            for attempt in 0...maxRetries {
                do {
                    let result: SearchResponseDTO = try await postJSON(path: "search/metadata", jsonObject: body)
                    out.append(contentsOf: result.assets.items.map(\.asServerAsset))
                    guard let nextString = result.assets.nextPage, let nextPage = Int(nextString) else { return out }
                    page = nextPage
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    if attempt < maxRetries {
                        try await Task.sleep(nanoseconds: UInt64((attempt + 1) * 1_000_000_000))
                    }
                }
            }
            if let lastError { throw lastError }
        }
    }

    // MARK: - Server-side statistics (fast count)

    /// Decoded body of `GET /api/assets/statistics`. `total == images +
    /// videos` on every Immich version we've tested; callers prefer
    /// `total` over summing.
    public struct AssetStatistics: Sendable, Equatable, Codable {
        public let images: Int
        public let videos: Int
        public let total: Int
    }

    /// `GET /api/assets/statistics?isTrashed=false` — a `{images,
    /// videos, total}` payload the UI renders as "On server" at sync
    /// start, before the full `listAllAssets()` reconciliation fetch
    /// finishes. Cheap enough to call on every sync.
    ///
    /// `isTrashed: false` mirrors the `serverNonTrashed` filter the
    /// reconciliation display uses, so the number the user sees during
    /// scanning matches the number after scanning.
    public func assetStatistics(includeTrashed: Bool = false) async throws -> AssetStatistics {
        // `makeRequest(path:)` appends via `URL.appending(path:)`,
        // which URL-encodes `?` and `=`. Build the URL with query
        // items through URLComponents instead so the query string
        // stays unescaped.
        let base = baseURL.appending(path: "assets/statistics")
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "isTrashed", value: includeTrashed ? "true" : "false"),
        ]
        guard let url = comps?.url else {
            throw ImmichClientError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        let (data, resp) = try await session.data(for: req)
        try Self.expectOK(resp, data: data)
        return try JSONDecoder().decode(AssetStatistics.self, from: data)
    }

    // MARK: - Trash

    /// Moves the given assets to Immich trash via `DELETE /api/assets`
    /// with `force: false`. The server treats `force: true` as immediate
    /// hard-delete with no restore path — cairn never calls it that way,
    /// and this method's body hard-codes `force: false` to keep that
    /// invariant at the call site.
    ///
    /// Empty `ids` is a no-op rather than a zero-length call.
    public func trashAssets(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        var req = try makeRequest(method: "DELETE", path: "assets")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["ids": ids, "force": false]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        // Debug-only log so the device console shows exactly what the
        // server returned for a trash call. Bodies for DELETE
        // /api/assets are typically empty (204) on success; anything
        // else is worth seeing. Helps diagnose "Immich UI disagrees
        // with the trash state" reports. Gated on `#if DEBUG` so
        // production builds don't stream per-call logs to stderr.
        #if DEBUG
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let bodySnippet = String(data: data.prefix(200), encoding: .utf8) ?? "<non-utf8>"
        print("[cairn.api] DELETE /api/assets ids=\(ids.count) force=false → HTTP \(status) body=\(bodySnippet.isEmpty ? "(empty)" : bodySnippet)")
        #endif
        try Self.expectOK(resp, data: data)
    }

    /// `POST /api/trash/restore/assets` — moves the given assets out of
    /// trash. The server is idempotent for assets not currently trashed
    /// (returns 2xx without touching them), so callers don't need to
    /// pre-filter. Empty `ids` is a no-op.
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

    /// `POST /api/tags` — upsert-by-value. Returning an existing tag
    /// when the name matches lets trash runs safely call this without a
    /// lookup-then-create race. cairn uses tags named
    /// `cairn/v1/run/<run_id>` as per-run breadcrumbs on the server.
    public func upsertTag(value: String) async throws -> ImmichTag {
        let body: [String: Any] = ["name": value]
        let dto: TagDTO = try await postJSON(path: "tags", jsonObject: body)
        return dto.asImmichTag
    }

    /// `GET /api/tags` — every tag visible to the API key's user.
    /// Requires `tag.read` scope (not part of the default trash-run
    /// scope set); `cairn history` and filename-based restore use this.
    public func listTags() async throws -> [ImmichTag] {
        let req = try makeRequest(method: "GET", path: "tags")
        let (data, resp) = try await session.data(for: req)
        try Self.expectOK(resp, data: data)
        let dtos = try JSONDecoder().decode([TagDTO].self, from: data)
        return dtos.map(\.asImmichTag)
    }

    /// Every asset attached to a given tag, across every non-locked
    /// visibility class (timeline/archive/hidden) and including trashed
    /// ones by default. `search/metadata` honors the default visibility
    /// filter on the server, so a naive single query misses Live Photo
    /// motion videos (visibility `hidden`). Iterate and merge to get a
    /// complete view. `locked` is intentionally skipped — listing it
    /// requires an elevated auth flow our API key doesn't have.
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

    /// `DELETE /api/tags/{id}` — remove a tag from the server. Used by
    /// `TrashOrchestrator` to clean up the just-created run tag when
    /// `bulkTagAssets` fails: the upsertTag call already committed the
    /// tag, so without this cleanup the server keeps an orphan
    /// `cairn/v1/run/<id>` with zero attached assets. Best-effort — if
    /// the delete itself fails the caller logs and continues with the
    /// original error.
    public func deleteTag(id: String) async throws {
        let req = try makeRequest(method: "DELETE", path: "tags/\(id)")
        let (data, resp) = try await session.data(for: req)
        try Self.expectOK(resp, data: data)
    }

    // MARK: - Assets by ID

    /// Fetch the current server-side state of each asset in `ids` via
    /// `GET /api/assets/{id}`. Used by `RestoreOrchestrator` to verify
    /// which IDs actually moved out of trash after a restore call —
    /// Immich's restore endpoint is silently idempotent (204 even for
    /// IDs that don't exist or were already non-trashed), so the
    /// response alone can't distinguish "restored" from "no-op'd."
    ///
    /// `GET /api/assets/{id}` returns trashed assets unconditionally,
    /// so no `withDeleted` knob is needed — `isTrashed` on the response
    /// is the source of truth. Missing IDs (404 from the server) are
    /// dropped from the result rather than thrown; the orchestrator
    /// treats "absent" as "still trashed" so the user errs toward
    /// review rather than false success. Other HTTP errors propagate.
    public func fetchAssets(ids: [String]) async throws -> [ServerAsset] {
        guard !ids.isEmpty else { return [] }
        var out: [ServerAsset] = []
        for id in ids {
            try Task.checkCancellation()
            let req = try makeRequest(method: "GET", path: "assets/\(id)")
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw ImmichClientError.unexpectedResponse("not an HTTP response")
            }
            if http.statusCode == 404 {
                // Asset is gone (hard-deleted, never existed, or the API
                // key can't see it). Treated as "still trashed" by
                // RestoreOrchestrator so the user reviews rather than
                // assumes success.
                continue
            }
            guard (200..<300).contains(http.statusCode) else {
                throw ImmichClientError.httpStatus(http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
            }
            let dto = try JSONDecoder().decode(AssetItemDTO.self, from: data)
            out.append(dto.asServerAsset)
        }
        return out
    }

    /// `PUT /api/tags/assets` — attach the given tags to every asset in
    /// `assetIds`. Used at trash time to stamp the per-run breadcrumb
    /// tag across every trashed asset. Empty input on either side is a
    /// no-op.
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

    /// Builds a request with `x-api-key` auth and no Accept header —
    /// see `ping()` for why the Accept omission matters on some
    /// endpoints.
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

/// Wire shape of `POST /api/search/metadata`. `nextPage` is a stringified
/// integer page number on servers that paginate (nil = final page).
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
    let originalFileName: String?
    let fileCreatedAt: String?
    let thumbhash: String?

    /// Parse an ISO-8601 string that may or may not include
    /// fractional seconds. `ISO8601DateFormatter` is
    /// non-`Sendable`, so instantiate per-call rather than hold a
    /// static — cheap and keeps strict-concurrency happy.
    private static func parseISO8601(_ s: String) -> Date? {
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    var asServerAsset: ServerAsset {
        // Server sends fractional seconds on some assets and not on
        // others; `parseISO8601` tries both. Nil on unparseable is
        // fine — UI renders a placeholder rather than crashing.
        let created: Date? = fileCreatedAt.flatMap(Self.parseISO8601)
        return ServerAsset(
            id: id,
            checksum: Checksum(base64: checksum),
            livePhotoVideoId: livePhotoVideoId,
            isTrashed: isTrashed,
            originalFileName: originalFileName,
            fileCreatedAt: created,
            thumbhash: thumbhash
        )
    }
}
