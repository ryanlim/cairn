import Foundation
import CairnCore

#if canImport(Photos)
import Photos
import CryptoKit

/// PhotoKit-backed `PhotoEnumerator`. Hashes every relevant
/// `PHAssetResource` in the user's Photos library and returns the
/// union as a `Set<Checksum>`.
///
/// **Why one checksum per resource, not per `PHAsset`.** Immich
/// identifies assets by SHA1 of file content. A Live Photo uploads as
/// two Immich assets — the still and the paired motion video — and
/// the server does **not** cascade-trash through `livePhotoVideoId`.
/// Hashing every resource a Live Photo carries (`.photo` +
/// `.pairedVideo`) and emitting both checksums independently keeps
/// the reconciliation pipeline uniform: a deleted `PHAsset` yields
/// two missing checksums on the next diff, and the orchestrator
/// sidesteps the `livePhotoVideoId` special case (see plan
/// §"Phase 2 (iOS): include-hidden view, uniform checksum diff").
///
/// **Resource-type policy** (see `Self.resourcesToHash`). For each
/// `PHAsset` we pick the resource(s) whose bytes match what Immich
/// would have stored on upload:
///   - Unedited photo: `.photo`.
///   - Edited photo: `.fullSizePhoto` (the rendered edit) when
///     present, else `.photo`.
///   - Video: `.fullSizeVideo` when present, else `.video`.
///   - Live Photo motion video: `.fullSizePairedVideo` (rendered
///     edit) when present, else `.pairedVideo`.
///   - Adjustment sidecars (`.adjustmentData`, `.adjustmentBasePhoto`,
///     `.adjustmentBasePairedVideo`, `.adjustmentBaseVideo`) are
///     skipped — they're not uploaded as standalone assets.
///
/// **Permissions.** Assumes the host app has already obtained
/// `.authorized` full-library access. Does not drive the permission
/// flow; `currentChecksums()` throws `Error.notAuthorized` if access
/// isn't granted.
///
/// **Memory.** PhotoKit streams resource bytes through a callback;
/// each chunk feeds a streaming `Insecure.SHA1` accumulator so a
/// multi-GB ProRes video doesn't materialize in RAM. The hash itself
/// is hardware-accelerated on Apple silicon (ARMv8 crypto
/// extensions); I/O dominates.
///
/// **Concurrency.** `currentChecksums()` serializes per-asset. The
/// reconciler does its own `TaskGroup`-based fan-out; this type
/// stays sequential for correctness on its direct CLI-style
/// callers.
public struct PhotoKitPhotoEnumerator: PhotoEnumerator {

    /// Errors specific to the PhotoKit enumerator. Narrow by design
    /// so callers can surface useful UI messages.
    public enum Error: Swift.Error, Sendable, Equatable {
        /// Photos access isn't `.authorized`. Host app drives the
        /// permission flow before invoking this enumerator.
        case notAuthorized(PHAuthorizationStatus)
        /// `PHAssetResourceManager` failed for a specific resource.
        /// Carries the underlying localized description so callers
        /// don't have to mirror PhotoKit's error domain.
        case resourceReadFailed(assetLocalIdentifier: String, message: String)
        /// No resource we knew how to hash — adjustment-only stubs and
        /// similar oddities. Treated as fatal here so a non-zero count
        /// gets noticed; shouldn't happen in normal libraries.
        case noHashableResource(assetLocalIdentifier: String)
    }

    public init() {}

    /// Enumerate every user-library asset and return the full set of
    /// resource-level SHA1 checksums. Throws `Error.notAuthorized` if
    /// Photos access has been revoked.
    ///
    /// Filters to `.typeUserLibrary` because that's the only source
    /// the user can trigger deletions from — iCloud Shared and
    /// iTunes-synced assets can't be trashed and shouldn't drive the
    /// server-side delete.
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
            // No per-asset filter needed here. `PHAsset` has no public
            // `isTrashed` property, and `fetchAssets(with:)` under
            // default options doesn't surface trashed assets. Documented
            // so a future maintainer knows the pass-through isn't a bug.
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

    // The Wave 4 positive-deletion signal lives in
    // `PhotoKitPersistentChangeReconciler`, which subscribes to
    // `PHPhotoLibrary.fetchPersistentChanges(since:)` and tracks
    // `deletedLocalIdentifiers` against a persisted
    // `[localIdentifier: Checksum]` cache. This enumerator deliberately
    // doesn't surface Recently Deleted — Apple never exposed it as a
    // public `PHAssetCollectionSubtype`, so enumeration isn't an option.
    // The reconciler is the only supported path.

    // MARK: - Internal hashing

    /// Stream a `PHAssetResource`'s bytes through `Insecure.SHA1` and
    /// return the resulting checksum. Bridges `PHAssetResourceManager`'s
    /// callback API into async/await and honors cooperative
    /// cancellation — a cancelled surrounding Task (timeout or user
    /// action) invokes `cancelDataRequest` to unblock a stuck iCloud
    /// fetch rather than leaking it.
    ///
    /// `isNetworkAccessAllowed = true` so iCloud-Optimized resources
    /// download on demand. Completion errors that reduce to
    /// `NSUserCancelledError` surface as `CancellationError` so the
    /// Swift concurrency runtime routes them naturally.
    static func hash(
        resource: PHAssetResource,
        assetLocalIdentifier: String,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Checksum {
        // Cancellation plumbing: the request ID returned synchronously
        // from `requestData` is what PhotoKit wants back for cancellation.
        // Stash it in a class box so `onCancel` can read it regardless
        // of when the continuation fires vs when the Task was cancelled.
        final class RequestBox: @unchecked Sendable {
            var id: PHAssetResourceDataRequestID = PHInvalidAssetResourceDataRequestID
        }
        let requestBox = RequestBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Checksum, Swift.Error>) in
                let options = PHAssetResourceRequestOptions()
                // Allow iCloud download — without this, resources stored only in
                // iCloud (common on devices with optimized storage) fail the
                // request. The host app should ideally pre-warm via a
                // PHCachingImageManager, but we tolerate slow paths.
                options.isNetworkAccessAllowed = true
                // PhotoKit only invokes this for iCloud fetches — locally-
                // available resources skip the download phase entirely so
                // the handler stays silent. Fraction is 0…1.
                if let progressHandler {
                    options.progressHandler = { progress in
                        progressHandler(progress)
                    }
                }

                // Hasher is mutated only inside the data-received callback,
                // which PhotoKit serializes per request. Wrap in a class to
                // give the closures a stable reference.
                final class HasherBox: @unchecked Sendable {
                    var hasher = Insecure.SHA1()
                }
                let box = HasherBox()

                let id = PHAssetResourceManager.default().requestData(
                    for: resource,
                    options: options,
                    dataReceivedHandler: { chunk in
                        box.hasher.update(data: chunk)
                    },
                    completionHandler: { error in
                        if let error {
                            // A cancelled request completes with
                            // NSCocoaErrorDomain / NSUserCancelledError.
                            // Surface it as CancellationError so the
                            // Swift concurrency runtime routes it
                            // naturally.
                            let ns = error as NSError
                            if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError {
                                continuation.resume(throwing: CancellationError())
                            } else {
                                continuation.resume(throwing: Error.resourceReadFailed(
                                    assetLocalIdentifier: assetLocalIdentifier,
                                    message: error.localizedDescription
                                ))
                            }
                            return
                        }
                        let digest = box.hasher.finalize()
                        let checksum = Checksum(base64: Data(digest).base64EncodedString())
                        continuation.resume(returning: checksum)
                    }
                )
                requestBox.id = id
            }
        } onCancel: {
            let id = requestBox.id
            guard id != PHInvalidAssetResourceDataRequestID else { return }
            PHAssetResourceManager.default().cancelDataRequest(id)
        }
    }

    /// Cheap file-size lookup — no bytes download to answer. Uses a
    /// KVC key because `PHAssetResource.fileSize` only became public in
    /// iOS 18 and the deployment target is iOS 17. The KVC path has
    /// worked for many releases. Returns `nil` if the key disappears
    /// in a future SDK.
    public static func resourceFileSize(_ resource: PHAssetResource) -> Int64? {
        (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
    }

    /// Whether the resource's bytes are already on-device (not
    /// iCloud-only). Same KVC-for-deployment-target reason as
    /// `resourceFileSize(_:)`. `nil` means "unknown" — callers
    /// should treat as remote to be safe.
    static func resourceIsLocallyAvailable(_ resource: PHAssetResource) -> Bool? {
        (resource.value(forKey: "locallyAvailable") as? NSNumber)?.boolValue
    }

    // MARK: - Resource selection (pure, testable)

    /// Ordered list of resources to hash for a `PHAsset`. Thin wrapper
    /// around `PHAssetResource.assetResources(for:)` plus the pure
    /// selection logic in `selectResourcesToHash(from:)`.
    static func resourcesToHash(for asset: PHAsset) -> [PHAssetResource] {
        let all = PHAssetResource.assetResources(for: asset)
        return selectResourcesToHash(from: all)
    }

    /// Selection logic factored out of PhotoKit so tests can drive it
    /// with fixture data. Algorithm:
    ///   1. Primary still: prefer `.fullSizePhoto` (rendered edit) over
    ///      `.photo`.
    ///   2. Primary video: prefer `.fullSizeVideo` over `.video`.
    ///   3. Live Photo motion video: prefer `.fullSizePairedVideo`
    ///      (rendered edit) over `.pairedVideo`.
    ///
    /// Returns resources in deterministic order (still, video,
    /// paired) so hashing sequences are reproducible for debugging.
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

    /// Pick the single "primary" resource for metadata purposes —
    /// matches the hash pipeline's first choice. For photos this is
    /// the rendered edit (`.fullSizePhoto`) when present, falling back
    /// to the original (`.photo`); for videos, `.fullSizeVideo` then
    /// `.video`. Used so the filename and file-size cairn records in
    /// `LocalAssetMetadataStore` agree with what cairn hashes — and
    /// what Immich uploads via its own `isCurrent` selection — so
    /// `OrphanReconciler` matches by filename can succeed for edited
    /// photos.
    public static func selectPrimaryResource(from resources: [PHAssetResource]) -> PHAssetResource? {
        selectResourcesToHash(from: resources).first
    }
}

#endif
