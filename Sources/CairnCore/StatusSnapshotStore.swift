import Foundation

/// User-visible counts captured at the end of each `requestSync` so the
/// Status screen has something to render at cold launch — before the
/// next sync has had a chance to recompute them. Keep this surface
/// minimal: it's a cosmetic carry-over for at-a-glance display, not the
/// source of truth for any reconciliation decision.
///
/// **Why counts only.** Persisting the full `[ServerAsset]` lists from
/// `LiveReconciliation` would be large, can stale arbitrarily fast, and
/// the user only needed numbers visible at launch. When the user taps
/// the Ready-to-Trash hero, the existing flow triggers a fresh sync;
/// the saved counts are a hold-over until that lands.
public struct StatusSnapshot: Sendable, Equatable, Codable {
    public let deleteCandidatesCount: Int
    /// Mirrors `ReconciliationOutput.assetsInEverSeen` — drives the
    /// "X.XX% of synced" chip math on Status.
    public let matchedCount: Int
    public let pendingReviewCount: Int
    public let inferredOrphanCount: Int
    public let computedAt: Date

    public init(
        deleteCandidatesCount: Int,
        matchedCount: Int,
        pendingReviewCount: Int,
        inferredOrphanCount: Int,
        computedAt: Date
    ) {
        self.deleteCandidatesCount = deleteCandidatesCount
        self.matchedCount = matchedCount
        self.pendingReviewCount = pendingReviewCount
        self.inferredOrphanCount = inferredOrphanCount
        self.computedAt = computedAt
    }
}

/// Per-server, single-row store for the most recent `StatusSnapshot`.
/// Save overwrites; load returns `nil` when nothing is stored yet.
public protocol StatusSnapshotStore: Sendable {
    func load() async throws -> StatusSnapshot?
    func save(_ snapshot: StatusSnapshot) async throws
    func clear() async throws
}

/// CLI-friendly impl. JSON object at a fixed path; atomic writes;
/// missing file decodes as `nil`.
public actor JSONFileStatusSnapshotStore: StatusSnapshotStore {
    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    public init(filePath: String) {
        self.path = URL(fileURLWithPath: filePath)
    }

    public func load() async throws -> StatusSnapshot? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data = try Data(contentsOf: path)
        guard !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StatusSnapshot.self, from: data)
    }

    public func save(_ snapshot: StatusSnapshot) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: path, options: .atomic)
    }

    public func clear() async throws {
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        try FileManager.default.removeItem(at: path)
    }
}
