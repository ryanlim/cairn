import Foundation
import Photos
import CairnCore

/// Static helper that resolves a `IndexingScope` to a
/// concrete `[localIdentifier: Set<albumLocalIdentifier>]` membership
/// map. The reconciler uses this map at scan start to:
///
///   - Restrict the set of `PHAsset`s it enumerates and hashes
///     (`.selectedAlbums` mode → only walk selected albums)
///   - Tag `EverSeenStore` writes with current album membership so the
///     engine's `tags ∩ scope` filter has fresh ground truth
///
/// Kept separate from `PhotoKitPersistentChangeReconciler` so the
/// scoping concern is testable in isolation and the reconciler stays
/// focused on change-token / orphan-sweep semantics.
public enum PhotoKitScopeEnumerator {

    /// Return value for `.selectedAlbums(...)` resolution.
    ///
    /// `localIdToAlbums` is the per-asset album membership; `localIds`
    /// is the union (avoids re-deriving with a hashed pass at the
    /// caller). Empty when the scope contains no albums or none of the
    /// albums resolve (deleted in Photos.app since the user picked
    /// them).
    public struct Membership: Sendable {
        public let localIdToAlbums: [String: Set<String>]
        public let localIds: Set<String>

        public static let empty = Membership(localIdToAlbums: [:], localIds: [])

        public init(localIdToAlbums: [String: Set<String>], localIds: Set<String>) {
            self.localIdToAlbums = localIdToAlbums
            self.localIds = localIds
        }
    }

    /// Build the membership map for the given scope. Returns `nil` for
    /// `.fullLibrary` — the caller is expected to fall back to a
    /// full-library `PHAsset.fetchAssets` walk in that case (no map
    /// needed; tags aren't applied; engine bypasses the scope filter).
    ///
    /// `nonisolated` and PhotoKit-only — safe to call from a detached
    /// task.
    public nonisolated static func membershipMap(for scope: IndexingScope) -> Membership? {
        switch scope {
        case .fullLibrary:
            return nil
        case .selectedAlbums(let albumIds):
            return resolveSelectedAlbums(albumIds: albumIds)
        }
    }

    /// Resolves a set of `PHAssetCollection.localIdentifier`s into the
    /// inverted membership map. Albums that no longer exist (deleted in
    /// Photos.app since the user picked them) are silently skipped —
    /// the Settings UI surfaces a "missing album" warning separately;
    /// the reconciler shouldn't crash or stall.
    private nonisolated static func resolveSelectedAlbums(albumIds: Set<String>) -> Membership {
        guard !albumIds.isEmpty else { return .empty }

        let collections = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: Array(albumIds),
            options: nil
        )

        var localIdToAlbums: [String: Set<String>] = [:]
        var allLocalIds: Set<String> = []

        // Per-album asset enumeration. `PHAsset.fetchAssets(in:options:)`
        // is the scope-aware fetch we want — it returns only assets
        // attached to the given collection. Live Photo motion videos
        // (which live in `.hidden` visibility) are NOT included by
        // default; we add `includeHiddenAssets = true` to mirror the
        // orphan-sweep enumerator so a Live Photo's still + motion both
        // get tagged with the album membership.
        let opts = PHFetchOptions()
        opts.includeHiddenAssets = true
        opts.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared]

        collections.enumerateObjects { collection, _, _ in
            let albumId = collection.localIdentifier
            let assets = PHAsset.fetchAssets(in: collection, options: opts)
            assets.enumerateObjects { asset, _, _ in
                let localId = asset.localIdentifier
                allLocalIds.insert(localId)
                localIdToAlbums[localId, default: []].insert(albumId)
            }
        }

        return Membership(localIdToAlbums: localIdToAlbums, localIds: allLocalIds)
    }
}
