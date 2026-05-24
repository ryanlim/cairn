import Foundation

// MARK: - ServerAssetCacheStore
//
// A persistent local mirror of the server's asset metadata, advanced
// incrementally via `POST /api/sync/stream` events. Reconciliation
// reads its server-side input from this cache instead of re-paginating
// `search/metadata` on every sync — see
// `docs/active-design/sync-stream-incremental-server-sync-plan.md`.
//
// The protocol lives in CairnCore so the engine can stay
// platform-neutral and a Kotlin/Android port can drop in its own
// (Room-backed?) implementation behind the same surface.

public protocol ServerAssetCacheStore: Sendable {
    /// Every asset currently cached for this partition. Returns a flat
    /// array; callers (typically the ReconciliationEngine) build their
    /// own checksum-keyed indexes from this.
    ///
    /// Visibility filtering is the caller's responsibility — the cache
    /// preserves whatever `visibility` the server emits so a hidden→
    /// timeline transition just rewrites the row rather than forcing a
    /// delete-then-reinsert cycle.
    func snapshot() async throws -> [ServerAsset]

    /// Row count without paying to materialize asset structs. The
    /// coordinator uses this to decide bootstrap-via-searchAllAssets
    /// (cache empty) vs. stream-only (cache populated).
    func size() async throws -> Int

    /// Apply a batch of SyncEvents transactionally:
    /// - `.asset` upserts by server-side `id`
    /// - `.assetDeleted` removes the matching row (no-op if absent)
    /// - `.complete` / `.ignored` are silently counted as `ignored`
    ///
    /// Returns counts so the caller can journal what was applied. A
    /// throw mid-batch leaves whatever was persisted up to that point
    /// in place; callers are expected to ack the server only after a
    /// successful return (any un-applied events replay on the next
    /// stream call thanks to upsert idempotency).
    func applyEvents(_ events: [SyncEvent]) async throws -> ApplyEventsSummary

    /// Drop every cached row. Forces the next coordinator pass to
    /// bootstrap from scratch via `searchAllAssets()`. Used when the
    /// user toggles the incremental-sync feature flag back on after a
    /// long off period, or to recover from a confirmed-corrupt cache.
    func reset() async throws
}

/// Counts of how many events in a batch landed where. Returned by
/// `ServerAssetCacheStore.applyEvents` and surfaced through the
/// coordinator into journals + diagnostics. `upserted` collapses
/// inserts and updates because the iOS impl pays one extra
/// fetch round-trip to distinguish them and the journal doesn't care.
public struct ApplyEventsSummary: Sendable, Equatable, Hashable {
    public let upserted: Int
    public let deleted: Int
    public let ignored: Int

    public init(upserted: Int, deleted: Int, ignored: Int) {
        self.upserted = upserted
        self.deleted = deleted
        self.ignored = ignored
    }

    public static let empty = ApplyEventsSummary(upserted: 0, deleted: 0, ignored: 0)

    public var total: Int { upserted + deleted + ignored }
}

// MARK: - SyncAckStore
//
// Per-entity-type cursor mirror. The server is authoritative — calling
// `POST /api/sync/ack` advances the server's own cursor for this client
// session — but cairn keeps a local copy so the next stream request can
// resume from the most recent ack and so diagnostics can show "last
// acked at X" without a server round-trip.
//
// The intended write order during a sync is:
//   1. Apply events to ServerAssetCacheStore
//   2. POST acks to /api/sync/ack
//   3. Persist the highest ack per entity type via SyncAckStore.setAck
//
// A crash between steps 2 and 3 leaves the local cursor behind the
// server — the next sync reads `currentSyncAcks()` to repair (or just
// replays the events; upsert idempotency keeps the cache consistent).

public protocol SyncAckStore: Sendable {
    /// The most recent ack id we've persisted for `type`. Nil if we
    /// haven't seen any events of that type yet.
    func ack(for type: SyncEntityType) async throws -> String?

    /// Persist `ack` as the most recent for `type`. Always called
    /// *after* the server has confirmed the corresponding events via
    /// `POST /api/sync/ack`, so a crash between server-ack and local-
    /// persist replays at-most-N events on next stream.
    func setAck(_ ack: String, for type: SyncEntityType) async throws

    /// Every persisted ack as a flat array. Used by the coordinator
    /// to reconcile against `ImmichClient.currentSyncAcks()` on
    /// bootstrap.
    func allAcks() async throws -> [SyncAckRecord]

    /// Drop every ack. Pairs with `ServerAssetCacheStore.reset` —
    /// after this, the next `syncStream(reset: true)` call replays
    /// the server's full state.
    func clearAll() async throws
}
