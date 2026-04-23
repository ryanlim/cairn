import Foundation

/// Fetches `/api/assets/{id}/thumbnail` bytes from an Immich server,
/// de-duplicates concurrent requests for the same asset, and keeps a
/// bounded in-memory LRU-ish cache so the UI can re-display thumbnails
/// without re-fetching.
///
/// Scope deliberately narrow: returns raw `Data` rather than any platform
/// image type so the actor stays in `CairnCore` (Foundation-only,
/// portable to Kotlin later). Callers in `CairnIOSCore` decode to
/// `UIImage`; an Android port would decode to `Bitmap`.
///
/// Eviction strategy: naive "drop-an-arbitrary-entry when over budget."
/// Good enough for the 50-MB-ish working set of visible thumbnails; can
/// upgrade to a true LRU if profiling says it matters.
public actor ImmichThumbnailLoader {
    public let baseURL: URL
    public let apiKey: String
    private let session: URLSession
    private let maxCacheBytes: Int

    private var cache: [String: Data] = [:]
    private var currentCacheBytes: Int = 0
    private var inFlight: [String: Task<Data, Error>] = [:]

    public init(
        baseURL: URL,
        apiKey: String,
        session: URLSession = .shared,
        maxCacheBytes: Int = 50 * 1024 * 1024
    ) {
        self.baseURL = Self.normalize(baseURL)
        self.apiKey = apiKey
        self.session = session
        self.maxCacheBytes = maxCacheBytes
    }

    /// Immich serves its API under `/api`. Accept either form from callers —
    /// `https://host/` and `https://host/api/` should both work. Same
    /// normalization logic as `ImmichClient` so the two types agree on the
    /// base URL.
    private static func normalize(_ url: URL) -> URL {
        let path = url.path
        if path.hasSuffix("/api") || path.hasSuffix("/api/") {
            return url
        }
        return url.appending(path: "api")
    }

    /// Fetch bytes for an asset's thumbnail. Returns cached bytes on a
    /// second call for the same asset. Concurrent calls for the same
    /// asset share a single HTTP request.
    public func load(assetId: String) async throws -> Data {
        if let hit = cache[assetId] { return hit }
        if let task = inFlight[assetId] { return try await task.value }

        let task = Task { () throws -> Data in
            try await self.fetch(assetId: assetId)
        }
        inFlight[assetId] = task
        defer { inFlight[assetId] = nil }

        let data = try await task.value
        insertIntoCache(assetId: assetId, data: data)
        return data
    }

    /// Drop all cached thumbnails. Useful when credentials rotate (the
    /// previously-cached bytes were fetched with a now-stale key).
    public func clearCache() {
        cache.removeAll()
        currentCacheBytes = 0
    }

    private func fetch(assetId: String) async throws -> Data {
        var req = URLRequest(url: baseURL.appending(path: "assets/\(assetId)/thumbnail"))
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ImmichClientError.unexpectedResponse("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ImmichClientError.httpStatus(http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func insertIntoCache(assetId: String, data: Data) {
        cache[assetId] = data
        currentCacheBytes += data.count
        // Naive eviction — drop arbitrary entries until under budget.
        // Small per-thumbnail size (Immich serves ~WebP thumbnails of a
        // few KB each) means the working set rarely saturates; a true
        // LRU would be overkill for this access pattern.
        while currentCacheBytes > maxCacheBytes,
              let (k, v) = cache.first(where: { $0.key != assetId }) {
            cache.removeValue(forKey: k)
            currentCacheBytes -= v.count
        }
    }
}
