import Foundation

/// Persistent queue of local asset identifiers that the hashing pipeline
/// attempted and **deferred** rather than completed. Items re-enter the
/// pipeline on a later pass — a small batch during each foreground
/// incremental scan, and (crucially) the full queue during a
/// `BGProcessingTask` slot when the device is on power + Wi-Fi and
/// foreground size limits are relaxed.
///
/// Without this store, deferred assets only retry when the
/// `PHPersistentChangeToken` expires and the full-enumeration path
/// rebuilds everything from scratch — which can be never, in practice.
/// This store closes that gap so "deferred" actually means
/// "queued for later" rather than "silently skipped forever."
///
/// **Lifecycle.**
///   - Added on defer. Reason + optional size carry forward to the UI.
///   - Removed on successful hash (the next attempt cleared them).
///   - Entry's `firstDeferredAt` is stable across retries — useful for
///     surfacing "been deferred for N days" in Settings.
///   - Hard-ceiling assets (`DeferReason.aboveHardCeiling`) are
///     intentionally **not** persisted here — they're out-of-scope by
///     user choice and shouldn't grow the queue.
public protocol DeferredHashStore: Sendable {
    /// Every queued entry. Ordered is not guaranteed — callers that need
    /// deterministic ordering should sort client-side.
    func snapshot() async throws -> [DeferredHashEntry]

    /// Count only (cheaper than `snapshot().count` on a SwiftData store
    /// that can use an aggregate query). Primary use: Settings' "N
    /// assets queued for background hashing" line.
    func count() async throws -> Int

    /// Upsert each entry by `localIdentifier`. `firstDeferredAt` is
    /// preserved from the existing row when present (first-write-wins);
    /// other fields overwrite so the latest defer reason/size wins.
    func upsert(_ entries: [DeferredHashEntry]) async throws

    /// Drop entries by identifier. Silent no-op on absence so callers
    /// don't need to pre-check after a successful hash.
    func remove(_ localIdentifiers: Set<String>) async throws

    /// Nuke the whole queue. Part of Settings → Reset index; also used
    /// by "Rescan library" after the user bumps the soft limit and
    /// wants to retry from a clean slate.
    func clear() async throws
}

/// One asset's row in the defer queue. Plain value type; the platform
/// store turns these into rows (SwiftData on iOS, JSON or another
/// KV-store on Android when the Kotlin port happens).
public struct DeferredHashEntry: Sendable, Equatable {
    /// Platform-specific local identifier. On iOS this is
    /// `PHAsset.localIdentifier`.
    public let localIdentifier: String
    /// Why we deferred on the most recent attempt. Distinct enum rather
    /// than a free-form string so the UI can render reasons
    /// consistently.
    public let reason: DeferReason
    /// Estimated iCloud-download size in bytes, when known.
    /// Populated for the `tooLarge` reason; typically nil for
    /// `timedOut` (we aborted before observing a size) and nil for
    /// `noHashableResources`.
    public let sizeBytes: Int64?
    /// Time of the first defer observation for this identifier. Carried
    /// forward across retries so the UI can surface "queued for N
    /// days" without a side-store for age.
    public let firstDeferredAt: Date

    public init(
        localIdentifier: String,
        reason: DeferReason,
        sizeBytes: Int64?,
        firstDeferredAt: Date
    ) {
        self.localIdentifier = localIdentifier
        self.reason = reason
        self.sizeBytes = sizeBytes
        self.firstDeferredAt = firstDeferredAt
    }

    /// Mirrors the iOS reconciler's `DeferReason` but lives in Core so
    /// it's portable. `aboveHardCeiling` is intentionally not listed
    /// here — hard-ceiling skips are permanent, and never land in the
    /// defer queue.
    public enum DeferReason: String, Sendable, Equatable, Codable {
        /// iCloud fetch exceeded the soft limit on the last attempt.
        /// The background drain (no soft limit) will pick these up.
        case tooLarge
        /// A per-asset wall-clock timeout elapsed on the last attempt.
        /// Usually a transient network stall; next slot retries.
        case timedOut
        /// PHAsset had no hashable resources. Rare; retry rarely
        /// helps, but we keep the entry so the UI can warn the user.
        case noHashableResources
    }
}
