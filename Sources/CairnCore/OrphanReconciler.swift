import Foundation

/// One server asset matched against locally-observed metadata where
/// cairn never managed to hash the asset before it was deleted from
/// the photo library — i.e. an orphan that the standard ever-seen
/// reconciliation cannot surface because the SHA1 was never recorded.
///
/// `matchedMetadata` is surfaced so the UI can explain *why* the asset
/// is being flagged ("we saw a photo named X added on Y, but never
/// finished indexing it before it was deleted").
public struct InferredOrphan: Sendable, Equatable {
    public let serverAsset: ServerAsset
    public let matchedMetadata: LocalAssetMetadata

    public init(serverAsset: ServerAsset, matchedMetadata: LocalAssetMetadata) {
        self.serverAsset = serverAsset
        self.matchedMetadata = matchedMetadata
    }
}

/// Filename-and-date matcher that catches a specific class of orphan
/// the SHA1-based reconciler cannot.
///
/// The cull-burst case: user takes a photo, Immich uploads it, user
/// deletes it locally — all within seconds while cairn is backgrounded.
/// `fetchPersistentChanges(since:)` later returns insert+delete events
/// for the same `localIdentifier`, but `PHAsset.fetchAssets(...)` finds
/// nothing for the deleted id, so the asset's bytes are unreachable
/// and its SHA1 never lands in `EverSeenStore`. The standard
/// reconciliation can't candidate it for trash because the candidate
/// predicate requires `everSeen.contains(checksum)`. Without this
/// matcher, the asset is orphaned on Immich forever.
///
/// `LocalAssetMetadataStore` records filename + creationDate at
/// observation time — early enough to survive the deletion. Immich
/// carries the corresponding identity in `ServerAsset.originalFileName +
/// fileCreatedAt`. Together they're enough to identify orphans even
/// when the SHA1 is unrecoverable.
public enum OrphanReconciler {

    /// Identify server assets that look like uploads from this device
    /// for which cairn observed the asset locally but never hashed it.
    ///
    /// Match criteria — all required:
    ///   - server asset is non-trashed
    ///   - server asset's checksum is NOT in `everSeen` (cairn doesn't
    ///     know about it locally)
    ///   - server asset has a non-nil `originalFileName` and `fileCreatedAt`
    ///   - some entry in `metadata` has matching `originalFileName`
    ///     (case-insensitive) AND `creationDate` within `dateTolerance`
    ///     of `server.fileCreatedAt`
    ///   - the matched metadata's `localIdentifier` is NOT in
    ///     `presentLocalIdentifiers` (asset was deleted from PhotoKit)
    ///
    /// Returns at most one orphan per server asset. If a server asset
    /// matches multiple metadata rows, the closest creationDate wins.
    public static func match(
        serverAssets: [ServerAsset],
        everSeen: Set<Checksum>,
        metadata: [LocalAssetMetadata],
        presentLocalIdentifiers: Set<String>,
        dateTolerance: TimeInterval = 2  // seconds; PhotoKit ↔ Immich rounding
    ) -> [InferredOrphan] {
        // Index metadata by lowercased filename so the per-asset lookup
        // is O(1). PhotoKit and Immich both preserve filename casing
        // but case-folded equality is the safer comparison — APFS is
        // case-insensitive by default and the same physical file can
        // round-trip with different casing across upload paths.
        var byFilename: [String: [LocalAssetMetadata]] = [:]
        for entry in metadata {
            guard let name = entry.originalFileName?.lowercased(), !name.isEmpty else { continue }
            byFilename[name, default: []].append(entry)
        }
        guard !byFilename.isEmpty else { return [] }

        var out: [InferredOrphan] = []
        out.reserveCapacity(min(serverAssets.count, 16))

        for asset in serverAssets {
            guard !asset.isTrashed,
                  !everSeen.contains(asset.checksum),
                  let serverName = asset.originalFileName?.lowercased(),
                  let serverCreatedAt = asset.fileCreatedAt else { continue }

            guard let candidates = byFilename[serverName] else { continue }

            // Filter to entries within tolerance whose localIdentifier
            // is no longer in PhotoKit. Pick the closest creationDate
            // when more than one matches — handles the edge case where
            // a user had two same-named photos with near-identical
            // creation timestamps.
            var bestEntry: LocalAssetMetadata?
            var bestDelta: TimeInterval = .infinity
            for entry in candidates {
                guard let entryDate = entry.creationDate else { continue }
                let delta = abs(entryDate.timeIntervalSince(serverCreatedAt))
                guard delta <= dateTolerance else { continue }
                guard !presentLocalIdentifiers.contains(entry.localIdentifier) else { continue }
                if delta < bestDelta {
                    bestDelta = delta
                    bestEntry = entry
                }
            }

            if let bestEntry {
                out.append(InferredOrphan(serverAsset: asset, matchedMetadata: bestEntry))
            }
        }

        return out
    }
}
