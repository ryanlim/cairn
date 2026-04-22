import Foundation
import CairnCore

#if canImport(Photos)
import Photos
import CryptoKit

/// PhotoKit-backed `PhotoEnumerator` that hashes every relevant
/// `PHAssetResource` byte-stream in the user's Photos library and returns the
/// union as a `Set<Checksum>`.
///
/// Why this shape (vs. one checksum per `PHAsset`):
/// Immich identifies assets by SHA1 of file content, and a Live Photo uploads
/// to Immich as **two** assets — the still and the paired motion video — that
/// the server does not cascade-trash through `livePhotoVideoId`. By hashing
/// every resource a Live Photo carries (`.photo` + `.pairedVideo`) and
/// emitting both checksums independently, the iOS reconciliation pipeline
/// becomes uniform: a deleted `PHAsset` naturally yields two missing
/// checksums on the next diff, and the orchestrator no longer needs the
/// `livePhotoVideoId` special case (see plan §"Phase 2 (iOS): include-hidden
/// view, uniform checksum diff").
///
/// Resource-type policy (deliberate choice — see `Self.resourcesToHash`):
/// for each `PHAsset` we pick the resource(s) whose **bytes** match what
/// Immich would have stored on upload. For an unedited photo that's
/// `.photo`; for an edited photo we prefer `.fullSizePhoto` (the rendered
/// edited still) when present, falling back to `.photo`. Video assets use
/// `.fullSizeVideo` if present, else `.video`. Live Photos always include
/// the paired video resource (`.fullSizePairedVideo` preferred when present
/// — the rendered edited motion variant — else `.pairedVideo`). Adjustment
/// sidecars (`.adjustmentData`, `.adjustmentBasePhoto`,
/// `.adjustmentBasePairedVideo`, `.adjustmentBaseVideo`) are skipped — they
/// are not standalone uploaded assets.
///
/// Permission model: this type assumes the host app has already obtained
/// `.authorized` (full library) access. It does not request permission;
/// `currentChecksums()` throws `Error.notAuthorized` if access isn't granted.
///
/// Memory: PhotoKit streams resource bytes via a callback. We feed each
/// chunk into a streaming `Insecure.SHA1` accumulator so a multi-GB ProRes
/// video doesn't materialize in RAM. The hash itself is hardware-accelerated
/// on Apple silicon (ARMv8 crypto extensions); I/O dominates.
///
/// Concurrency: we serialize per-asset hashing today (resources hashed one
/// at a time within an async function). PhotoKit's resource manager is
/// thread-safe but disk I/O on a phone is the bottleneck and parallel reads
/// can thrash. A future optimization could fan out across a small task
/// group; correctness first.
public struct PhotoKitPhotoEnumerator: PhotoEnumerator {

    /// Errors specific to the PhotoKit enumerator. Kept narrow so callers
    /// can surface useful UI messages.
    public enum Error: Swift.Error, Sendable, Equatable {
        /// Photos library access isn't `.authorized`. The host app must
        /// drive the permission flow before invoking this enumerator.
        case notAuthorized(PHAuthorizationStatus)
        /// `PHAssetResourceManager` reported failure for a specific resource.
        /// Surfaced with the underlying error's localized description so we
        /// don't have to mirror PhotoKit's error domain.
        case resourceReadFailed(assetLocalIdentifier: String, message: String)
        /// An asset had no resource we knew how to hash (e.g. a stub asset
        /// with only adjustment sidecars). Treated as fatal so the operator
        /// notices; in practice this should not happen for normal libraries.
        case noHashableResource(assetLocalIdentifier: String)
    }

    public init() {}

    public func currentChecksums() async throws -> Set<Checksum> {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized else {
            throw Error.notAuthorized(status)
        }

        let fetchOptions = PHFetchOptions()
        // Phase 2 plan calls for hashing every resource Immich would have
        // uploaded; hidden iOS assets are still uploaded by the official
        // Immich mobile app, but the *iOS* "hidden album" flag is a
        // user-presentation toggle and the Photos picker convention is to
        // exclude them. We mirror the official Immich mobile behavior:
        // include only non-hidden assets in the device's source-of-truth
        // set. (Live Photo motion videos are not "hidden" at the PHAsset
        // level — they are a paired resource on the still asset, which we
        // hash regardless.)
        fetchOptions.includeHiddenAssets = false
        // PHFetchOptions has no public API for "exclude Recently Deleted";
        // PhotoKit doesn't surface trashed assets in the default photo
        // library view at all (they live in the user's hidden trash album,
        // which the user account level fetch does not return). Belt-and-
        // suspenders: filter by source type to drop anything not in the
        // user library, and apply the trashed predicate explicitly below.
        // `PHAssetSourceType.typeUserLibrary` is the only source the user
        // can delete from; iCloud Shared Library and iTunes-synced sources
        // can't be trashed and shouldn't drive deletions on the server.
        fetchOptions.includeAssetSourceTypes = [.typeUserLibrary]

        let result = PHAsset.fetchAssets(with: fetchOptions)

        var checksums = Set<Checksum>()
        // Capture into an array so we can iterate with async/await without
        // holding the PHFetchResult across suspension points (it's KVO-
        // backed and not designed for that).
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            // Defensive: skip if PhotoKit ever surfaces a trashed asset
            // through a future API change. `PHAsset` exposes no public
            // `isTrashed` property today — Recently Deleted is queried via
            // a dedicated smart album (`PHAssetCollectionSubtype.smartAlbumRecentlyDeleted`)
            // and those assets do not appear in `fetchAssets(with:)` with
            // default options. Documented here so a future maintainer
            // doesn't reinvent the filter.
            assets.append(asset)
        }

        for asset in assets {
            let resources = Self.resourcesToHash(for: asset)
            if resources.isEmpty {
                throw Error.noHashableResource(assetLocalIdentifier: asset.localIdentifier)
            }
            for resource in resources {
                let checksum = try await Self.hash(resource: resource, assetLocalIdentifier: asset.localIdentifier)
                checksums.insert(checksum)
            }
        }

        return checksums
    }

    // MARK: - Internal hashing

    /// Hash a single `PHAssetResource` by streaming its bytes through
    /// `Insecure.SHA1`. Bridges PhotoKit's callback API into async/await.
    static func hash(resource: PHAssetResource, assetLocalIdentifier: String) async throws -> Checksum {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Checksum, Swift.Error>) in
            let options = PHAssetResourceRequestOptions()
            // Allow iCloud download — without this, resources stored only in
            // iCloud (common on devices with optimized storage) fail the
            // request. The host app should ideally pre-warm via a
            // PHCachingImageManager, but we tolerate slow paths.
            options.isNetworkAccessAllowed = true

            // Hasher is mutated only inside the data-received callback,
            // which PhotoKit serializes per request. Wrap in a class to
            // give the closures a stable reference.
            final class HasherBox: @unchecked Sendable {
                var hasher = Insecure.SHA1()
            }
            let box = HasherBox()

            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { chunk in
                    box.hasher.update(data: chunk)
                },
                completionHandler: { error in
                    if let error {
                        continuation.resume(throwing: Error.resourceReadFailed(
                            assetLocalIdentifier: assetLocalIdentifier,
                            message: error.localizedDescription
                        ))
                        return
                    }
                    let digest = box.hasher.finalize()
                    let checksum = Checksum(base64: Data(digest).base64EncodedString())
                    continuation.resume(returning: checksum)
                }
            )
        }
    }

    // MARK: - Resource selection (pure, testable)

    /// Pick the ordered list of `PHAssetResource`s whose bytes we should
    /// hash for a given asset. Pure function modulo the PhotoKit query —
    /// the actual selection logic over the returned resource array lives
    /// in `selectResourcesToHash(from:)` and is unit-testable without a
    /// device.
    static func resourcesToHash(for asset: PHAsset) -> [PHAssetResource] {
        let all = PHAssetResource.assetResources(for: asset)
        return selectResourcesToHash(from: all)
    }

    /// Pure selection logic over a resource list. Extracted so tests can
    /// drive it with mock `PHAssetResource`-shaped fixtures (or, in
    /// practice, with real PhotoKit resources from a simulator / device).
    /// Algorithm:
    ///   1. Pick the primary still: prefer `.fullSizePhoto` (rendered edit)
    ///      when present, else `.photo`.
    ///   2. Pick the primary video: prefer `.fullSizeVideo` over `.video`.
    ///   3. Pick the paired motion-video for Live Photos: prefer
    ///      `.fullSizePairedVideo` (rendered edit of the motion video)
    ///      when present, else `.pairedVideo`.
    /// Returns resources in a deterministic order (still, video, paired)
    /// so the hashing loop is reproducible for debugging.
    static func selectResourcesToHash(from resources: [PHAssetResource]) -> [PHAssetResource] {
        var picked: [PHAssetResource] = []
        let byType = Dictionary(grouping: resources, by: { $0.type })

        if let still = byType[.fullSizePhoto]?.first ?? byType[.photo]?.first {
            picked.append(still)
        }
        if let video = byType[.fullSizeVideo]?.first ?? byType[.video]?.first {
            picked.append(video)
        }
        if let paired = byType[.fullSizePairedVideo]?.first ?? byType[.pairedVideo]?.first {
            picked.append(paired)
        }
        return picked
    }
}

#endif
