import Foundation

/// Cached map from a platform-specific local asset identifier (PhotoKit's
/// `PHAsset.localIdentifier` on iOS; likely a MediaStore URI on Android)
/// to the checksums cairn has computed for that asset.
///
/// **Why cache.** The persistent-change pipeline finds out about deleted
/// assets by identifier, but by that point the underlying asset is gone —
/// there's nothing to hash. We seed this cache on the way *in* (during
/// full-library enumeration and on insert/update events) so we have an
/// answer on the way *out* (translate deleted identifiers → checksums →
/// `ConfirmedDeletedStore.union`).
///
/// **Live Photos.** A single `localIdentifier` may map to multiple
/// checksums — a Live Photo contributes both the still and the paired
/// motion video. All are emitted to confirmed-deleted when the corresponding
/// asset is deleted.
///
/// **Lifecycle.** Entries are removed only after the deletion has been
/// translated (via `removeAll(for:)`), or when the full-library
/// re-enumeration path rebuilds the cache from scratch. In steady state
/// the cache is roughly `O(library size)`, bounded by the number of
/// live assets.
public protocol LocalHashStore: Sendable {
    /// The full cached mapping. Callers that only need a single identifier
    /// should use `checksums(for:)` instead — a targeted fetch is cheaper.
    func snapshot() async throws -> [String: Set<Checksum>]

    /// Count of distinct local identifiers with cached checksums.
    /// Used by the UI to surface "how many assets have been indexed"
    /// on progress ticks — needs to be cheap relative to `snapshot()`
    /// which materializes every row. Default impl falls back to
    /// `snapshot().count` for stores that don't override it.
    func indexedCount() async throws -> Int

    /// Just the keys, no checksum values. Cheap alternative to
    /// `snapshot()` for set-membership work (e.g. orphan detection).
    /// Default impl falls back to `snapshot().keys`; concrete stores
    /// with a cheaper aggregate query should override.
    func allLocalIdentifiers() async throws -> Set<String>

    /// Flat union of every cached checksum across all identifiers.
    /// Cheap alternative to `snapshot()` when callers only need the
    /// checksum set for reconciliation diffs (no per-id mapping).
    /// Default impl materializes the snapshot; concrete stores
    /// should override.
    func allChecksums() async throws -> Set<Checksum>

    /// One-shot fetch combining `allChecksums()` + `indexedCount()`.
    /// Both projections from the same materialized rows — saves a
    /// duplicate full-table scan when the caller needs both (the
    /// reconciliation prelude is the only current consumer). Default
    /// impl runs the two methods sequentially; concrete stores should
    /// override with a single fetch.
    func summary() async throws -> (checksums: Set<Checksum>, distinctIdCount: Int)

    /// Batch lookup for a known id set. Returns only entries that
    /// exist (missing ids drop out). Cheaper than calling
    /// `checksums(for:)` and `modificationDate(for:)` in a loop —
    /// one query instead of 2*N. Default impl falls back to per-id
    /// lookups; concrete stores should override.
    func entries(forIdentifiers ids: Set<String>) async throws -> [String: (checksums: Set<Checksum>, modificationDate: Date?)]

    /// Checksums cached for a specific identifier. Empty set when unknown.
    func checksums(for localIdentifier: String) async throws -> Set<Checksum>

    /// Replace the cached entries for `localIdentifier` with `checksums`,
    /// tagging them with the asset's `modificationDate` if known.
    /// Callers use the date to skip re-hashing on subsequent syncs when
    /// the asset's pixel bytes are unchanged (PhotoKit update events
    /// fire for metadata-only changes too — favorites, captions — and
    /// re-hashing those is waste). `modificationDate: nil` means the
    /// caller doesn't know; the cache stays usable but the skip-
    /// heuristic can't engage.
    func set(_ checksums: Set<Checksum>, for localIdentifier: String, modificationDate: Date?) async throws

    /// Modification date paired with the cached checksums for an asset,
    /// or `nil` if no entry exists (or the entry predates modification-
    /// date tracking — legacy rows never had it).
    func modificationDate(for localIdentifier: String) async throws -> Date?

    /// Drop all cached entries for every identifier in the set. Silent
    /// no-op on absence.
    func removeAll(for localIdentifiers: Set<String>) async throws

    /// Drop every entry. Used by the "Reset index" affordance —
    /// nukes the full `localIdentifier → checksum` cache so the next
    /// sync rehashes from scratch. Distinct from `removeAll(for:)`
    /// because callers rarely want to enumerate every id client-side.
    func clear() async throws
}

public extension LocalHashStore {
    /// Convenience: `set` without a modification date. Stores the
    /// checksums but forgoes the stale-detection benefit. Useful for
    /// test fixtures and the CLI's file-backed stores where pixel
    /// modification dates aren't meaningful.
    func set(_ checksums: Set<Checksum>, for localIdentifier: String) async throws {
        try await set(checksums, for: localIdentifier, modificationDate: nil)
    }

    /// Fallback implementation of `indexedCount()` for stores that
    /// don't supply a cheaper one. Materializes the whole snapshot;
    /// concrete stores with an aggregate-query path should override.
    func indexedCount() async throws -> Int {
        try await snapshot().keys.count
    }

    /// Fallback implementation of `allLocalIdentifiers()`. Same caveat
    /// as `indexedCount`'s fallback — concrete stores should override.
    func allLocalIdentifiers() async throws -> Set<String> {
        Set(try await snapshot().keys)
    }

    /// Fallback implementation of `allChecksums()`. Materializes the
    /// snapshot; concrete stores should override.
    func allChecksums() async throws -> Set<Checksum> {
        var out = Set<Checksum>()
        for (_, cks) in try await snapshot() { out.formUnion(cks) }
        return out
    }

    /// Fallback implementation of `summary()`. Two sequential calls;
    /// concrete stores should override with a single fetch.
    func summary() async throws -> (checksums: Set<Checksum>, distinctIdCount: Int) {
        async let cks = allChecksums()
        async let count = indexedCount()
        return try await (checksums: cks, distinctIdCount: count)
    }

    /// Fallback `entries(forIdentifiers:)` — falls back to per-id
    /// queries. Concrete stores should override with one batched fetch.
    func entries(forIdentifiers ids: Set<String>) async throws -> [String: (checksums: Set<Checksum>, modificationDate: Date?)] {
        var out: [String: (checksums: Set<Checksum>, modificationDate: Date?)] = [:]
        for id in ids {
            let cks = try await checksums(for: id)
            guard !cks.isEmpty else { continue }
            let date = try await modificationDate(for: id)
            out[id] = (cks, date)
        }
        return out
    }
}
