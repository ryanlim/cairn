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
    ///
    /// **Imputation contract:** `set` always marks the resulting
    /// entries as **verified** (imputed = false). Callers using the
    /// fast-initial-scan trust path must call `setImputed` instead.
    /// When `set` is invoked on a localIdentifier whose prior entries
    /// were imputed, the imputed flag is cleared — this is the
    /// verify-on-touch path's "I just hashed it locally, the value is
    /// trustworthy" signal.
    func set(_ checksums: Set<Checksum>, for localIdentifier: String, modificationDate: Date?) async throws

    /// Record one or more checksums **imputed from server-side
    /// trust** — not computed locally. Used by the fast-initial-scan
    /// path when a `(filename, fileCreatedAt)` match against the
    /// server lets us trust the server's SHA1(s) without re-hashing
    /// locally. Marks every resulting row as `imputed = true`.
    ///
    /// Live Photos pass multiple checksums in a single call: a Live
    /// Photo is one phone localId with two server assets (still +
    /// motion video, linked via `livePhotoVideoId`), and both
    /// checksums must land on the same localId so the engine's
    /// `observed - currentLocal` diff doesn't phantom-delete the
    /// motion video. Non-Live-Photo callers pass a one-element set.
    ///
    /// Replaces any prior entries for the identifier (same shape as
    /// `set`). `modificationDate` should be the phone-side asset's
    /// `modificationDate` so the skip-rehash heuristic still works
    /// for incremental scans.
    ///
    /// See `docs/active-design/fast-initial-scan-plan.md`.
    func setImputed(_ checksums: Set<Checksum>, for localIdentifier: String, modificationDate: Date?) async throws

    /// Batch form of `setImputed` — seed many imputed entries in a
    /// single transaction. The fast-initial-scan imputation pass can
    /// seed 80k+ entries at once; calling `setImputed` per entry is one
    /// SQLite commit (fetch + delete + insert + save) each — minutes of
    /// fsync-class overhead with no hashing I/O to hide behind. The
    /// per-asset durability rationale `set` carries (don't lose an
    /// expensive iCloud download to a crash) doesn't apply: imputation
    /// is cheap to replay. Keyed by localIdentifier so duplicate ids in
    /// the input collapse. Callers should pass bounded batches (~1k) so
    /// the predicate IN-clause and transaction stay sized; the default
    /// impl loops `setImputed`, concrete stores override with one save.
    func setImputedBatch(_ entries: [String: (checksums: Set<Checksum>, modificationDate: Date?)]) async throws

    /// Whether the cached entries for `localIdentifier` were imputed
    /// (trusted from the server) rather than locally hashed. Used by
    /// the verify-on-touch path before propagating a deletion. Returns
    /// `false` for unknown identifiers and for stores that don't track
    /// the flag.
    func isImputed(for localIdentifier: String) async throws -> Bool

    /// Count of distinct localIdentifiers whose entries are currently
    /// marked imputed. Used by the diagnostics surface and to gate the
    /// "Verify cached checksums" action. Default impl returns 0 for
    /// stores that don't track the flag.
    func imputedCount() async throws -> Int

    /// All localIdentifiers whose entries are currently marked imputed.
    /// Used by the background verifier to enumerate work. Default impl
    /// returns the empty set.
    func imputedIdentifiers() async throws -> Set<String>

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

    /// Fallback for stores that don't track imputation (CLI fixtures,
    /// JSON-file stores used by tests). Records the checksums via the
    /// regular `set` path with no imputed flag — these stores don't
    /// participate in the fast-initial-scan optimization.
    func setImputed(_ checksums: Set<Checksum>, for localIdentifier: String, modificationDate: Date?) async throws {
        try await set(checksums, for: localIdentifier, modificationDate: modificationDate)
    }

    /// Default `setImputedBatch`: loop `setImputed`. Concrete stores with
    /// transactional batch support (SwiftData) override this.
    func setImputedBatch(_ entries: [String: (checksums: Set<Checksum>, modificationDate: Date?)]) async throws {
        for (id, v) in entries {
            try await setImputed(v.checksums, for: id, modificationDate: v.modificationDate)
        }
    }

    /// Fallback for stores that don't track imputation. Always false.
    func isImputed(for localIdentifier: String) async throws -> Bool { false }

    /// Fallback for stores that don't track imputation. Always 0.
    func imputedCount() async throws -> Int { 0 }

    /// Fallback for stores that don't track imputation. Always empty.
    func imputedIdentifiers() async throws -> Set<String> { [] }

    /// Materialized rows suitable for backup / export — one entry per
    /// `(localIdentifier, checksum)` tuple including the modification
    /// date and imputed flag. Used by `Settings → Export data` so the
    /// expensive SHA1 cache can be restored after a Reset Index / Clear
    /// Hash Cache. Default impl materializes from `snapshot()` plus
    /// per-id metadata lookups; concrete stores should override with a
    /// single batched fetch.
    func exportableRows() async throws -> [(localId: String, checksum: Checksum, modificationDate: Date?, imputed: Bool)] {
        let snap = try await snapshot()
        var out: [(localId: String, checksum: Checksum, modificationDate: Date?, imputed: Bool)] = []
        out.reserveCapacity(snap.count)
        for (localId, checksums) in snap {
            let modDate = try await modificationDate(for: localId)
            let imputed = try await isImputed(for: localId)
            for checksum in checksums {
                out.append((localId, checksum, modDate, imputed))
            }
        }
        return out
    }

    /// Bulk-write rows from a backup. Each row replaces any prior
    /// entries for its `localIdentifier`. `imputed=true` rows go
    /// through `setImputed`; `imputed=false` rows through `set`. Used
    /// during `importData` to restore the hash cache portion of a
    /// backup that passed the IDFV gate.
    func restoreFromExport(_ rows: [(localId: String, checksum: Checksum, modificationDate: Date?, imputed: Bool)]) async throws {
        // Group rows by localId so Live Photos (multiple rows per id)
        // land as a single `set` call rather than each row clobbering
        // the prior one's siblings.
        var grouped: [String: (checksums: Set<Checksum>, modDate: Date?, imputed: Bool)] = [:]
        for row in rows {
            if var existing = grouped[row.localId] {
                existing.checksums.insert(row.checksum)
                // Mixed imputed/verified for one localId shouldn't
                // happen in practice, but if it does, the verified
                // row wins (the imputation contract is "imputed
                // until something verifies it").
                existing.imputed = existing.imputed && row.imputed
                grouped[row.localId] = existing
            } else {
                grouped[row.localId] = ([row.checksum], row.modificationDate, row.imputed)
            }
        }
        for (localId, entry) in grouped {
            if entry.imputed {
                try await setImputed(entry.checksums, for: localId, modificationDate: entry.modDate)
            } else {
                try await set(entry.checksums, for: localId, modificationDate: entry.modDate)
            }
        }
    }
}
