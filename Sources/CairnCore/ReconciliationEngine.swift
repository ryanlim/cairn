import Foundation

/// Identifier for a phone asset that's currently alive in the Photos
/// library, used for an out-of-band safety check against falsely
/// proposing deletions for assets whose bytes diverged between phone
/// and server (edit-revert, re-import, cross-device upload) but where
/// the asset itself is still present on the device.
///
/// The pair `(filename, secondsSince1970)` is sufficient to identify
/// a capture event uniquely in practice — two distinct phone assets
/// almost never share both their original filename and creation
/// timestamp to the second. The engine treats any server asset whose
/// `(originalFileName, fileCreatedAt)` matches an alive phone asset
/// as "still here, bytes differ" rather than "deleted."
public struct AlivePhoneAssetKey: Hashable, Sendable {
    public let filename: String
    public let secondsSince1970: Int

    public init(filename: String, secondsSince1970: Int) {
        self.filename = filename
        self.secondsSince1970 = secondsSince1970
    }
}

/// Everything `ReconciliationEngine.compute` needs to decide which server
/// assets are candidates to trash. Assembled by the caller from four sources:
/// the live server response, a scan of the local photo library, the
/// client-side "ever seen" SHA1 set, and (Wave 4) a map of positively-
/// confirmed deletions plus user exclusions.
public struct ReconciliationInput: Sendable {
    /// Current server state. May include trashed assets; the engine filters
    /// `isTrashed == true` out of the candidate set.
    public let serverAssets: [ServerAsset]
    /// SHA1s of every asset presently in the iPhone's Photos library.
    public let currentLocalChecksums: Set<Checksum>
    /// SHA1s cairn has ever observed on this device. An asset is a deletion
    /// candidate only if its checksum is in this set AND absent from
    /// `currentLocalChecksums` — the "ever seen" gate is what keeps cairn
    /// from reaping photos that were only ever on the server.
    public let observedChecksums: Set<Checksum>
    /// Checksums the user has explicitly excluded. Server assets with these
    /// checksums drop out of the candidate set regardless of signal.
    public let excludedChecksums: Set<Checksum>
    /// Checksums observed as positively deleted on-device (Wave 4 positive
    /// signal, sourced from `PHPhotoLibrary.fetchPersistentChanges`), paired
    /// with the timestamp of first confirmation. The quarantine window is
    /// measured against these timestamps — items confirmed within the last
    /// `quarantineDays` are held for user review; older items are eligible
    /// to trash.
    public let confirmedDeletedAt: [Checksum: Date]
    /// "Now" for quarantine evaluation. Injected so tests drive the clock
    /// deterministically without waiting real seconds.
    public let now: Date
    /// Days a confirmed-deleted checksum must age before it becomes
    /// trashable. `0` disables quarantine (every confirmed entry is
    /// immediately past-quarantine).
    public let quarantineDays: Int
    /// Whether unconfirmed diff candidates (no positive signal) can trash
    /// directly or must wait for manual review. See `DeletionStrictness`.
    public let strictness: DeletionStrictness

    /// Per-checksum album-membership tags, paired with `selectedAlbumScope`
    /// for scope-aware indexing. `nil` (the default) means "no scope filter
    /// — full library mode." When non-nil and `selectedAlbumScope` is also
    /// non-nil, the engine restricts `observedChecksums` to entries whose
    /// tags intersect the scope before running the diff. Untagged entries
    /// (legacy / pre-scope-aware) are excluded under restricted scope —
    /// they get re-tagged on next sync.
    public let observedAlbumTags: [Checksum: Set<String>]?

    /// Active album scope: `Set` of `PHAssetCollection.localIdentifier`
    /// values from `CairnSettings.indexingScope.selectedAlbums`. Pair
    /// with `observedAlbumTags` to enable scope filtering. `nil` for
    /// full-library mode.
    public let selectedAlbumScope: Set<String>?

    /// When the user excluded each checksum. Used to detect "recycled"
    /// exclusions: an excluded checksum whose `confirmedDeletedAt`
    /// post-dates its `addedAt` means the user added the photo back to
    /// the phone after restoring, then deleted it again — overriding
    /// their original "preserve on Immich" intent. The engine routes
    /// these into `recycledExclusionCandidates` for explicit user
    /// review rather than silently keeping them excluded. `nil` (the
    /// default) disables detection — every excluded checksum stays
    /// excluded regardless of new confirmed-delete signals.
    public let excludedAtByChecksum: [Checksum: Date]?

    /// `(filename, fileCreatedAt-second)` keys for every PHAsset
    /// currently alive in the user's Photos library. The engine uses
    /// this as an out-of-band safety check: a server asset whose
    /// `(originalFileName, fileCreatedAt)` matches an alive phone
    /// asset can't be a deletion candidate — the user hasn't deleted
    /// it; its phone-side bytes just diverged (e.g. an edit was
    /// uploaded then reverted on the phone). Suppresses both the
    /// candidate proposal in `compute()` and the upstream limbo stamp.
    ///
    /// `nil` (the default) disables the check — preserves prior
    /// behavior for callers that don't yet supply the alive-asset
    /// snapshot. Tests that don't care can omit it.
    public let alivePhoneAssetKeys: Set<AlivePhoneAssetKey>?

    public init(
        serverAssets: [ServerAsset],
        currentLocalChecksums: Set<Checksum>,
        observedChecksums: Set<Checksum>,
        excludedChecksums: Set<Checksum> = [],
        confirmedDeletedAt: [Checksum: Date] = [:],
        now: Date = Date(),
        quarantineDays: Int = 14,
        strictness: DeletionStrictness = .trusting,
        observedAlbumTags: [Checksum: Set<String>]? = nil,
        selectedAlbumScope: Set<String>? = nil,
        excludedAtByChecksum: [Checksum: Date]? = nil,
        alivePhoneAssetKeys: Set<AlivePhoneAssetKey>? = nil
    ) {
        self.serverAssets = serverAssets
        self.currentLocalChecksums = currentLocalChecksums
        self.observedChecksums = observedChecksums
        self.excludedChecksums = excludedChecksums
        self.confirmedDeletedAt = confirmedDeletedAt
        self.now = now
        self.quarantineDays = quarantineDays
        self.strictness = strictness
        self.observedAlbumTags = observedAlbumTags
        self.selectedAlbumScope = selectedAlbumScope
        self.excludedAtByChecksum = excludedAtByChecksum
        self.alivePhoneAssetKeys = alivePhoneAssetKeys
    }
}

/// Three-bucket classification of server assets after reconciliation:
/// eligible-to-trash, pending manual review, and (a subset of pending) held
/// solely by the quarantine clock. The caller hands `deleteCandidates` to
/// `SafetyRails.evaluate` and then to `TrashOrchestrator.run`; the pending
/// buckets drive the in-app review UI.
public struct ReconciliationOutput: Sendable, Equatable {
    /// Assets eligible for trashing right now, after exclusions, quarantine,
    /// and strictness have all been applied.
    public let deleteCandidates: [ServerAsset]
    /// Checksums present locally that have never been seen before. Caller is
    /// expected to union these into the persistent `ObservedStore`.
    public let newlyObservedChecksums: Set<Checksum>
    /// Count of non-trashed server assets whose checksum is in the observed
    /// set. Used as the denominator for `SafetyRails`'s percent cap so
    /// libraries that are partially-synced don't trip the rail.
    public let assetsInObserved: Int
    /// Count of would-be candidates filtered out by `excludedChecksums`.
    /// Informational; surfaced in the dry-run summary.
    public let excludedCandidateCount: Int
    /// Candidates the diff flagged but which aren't eligible to trash yet —
    /// either unconfirmed (no positive signal under strict mode) or still
    /// inside the quarantine window. Shown to the user for manual approval.
    public let pendingReviewCandidates: [ServerAsset]
    /// Subset of `pendingReviewCandidates` held solely because their
    /// quarantine window has not yet elapsed. Separated from the unconfirmed
    /// holdbacks so the UI can render "eligible in N days" instead of a
    /// generic "pending" label.
    public let heldByQuarantineCandidates: [ServerAsset]
    /// Excluded checksums the user appears to have re-deleted on the
    /// phone after restoring them via cairn — `confirmedDeletedAt`
    /// post-dates the exclusion's `addedAt`. Surfaced for explicit user
    /// review (Status banner → PendingReview) rather than silently
    /// trashed: the user originally said "preserve on Immich," and that
    /// preference shouldn't be reversed without confirmation. Approving
    /// here clears the exclusion and proceeds to trash; dismissing
    /// keeps the exclusion (and stamps a fresh `addedAt` so the same
    /// signal doesn't re-fire next sync).
    public let recycledExclusionCandidates: [ServerAsset]
    /// Count of would-be candidates filtered out by the alive-phone
    /// safety check (a server asset whose `(originalFileName,
    /// fileCreatedAt)` matched a currently-alive phone asset).
    /// Informational; surfaces the edit-revert protection in
    /// telemetry without exposing user filenames.
    public let aliveOnPhoneCandidateCount: Int

    public init(
        deleteCandidates: [ServerAsset],
        newlyObservedChecksums: Set<Checksum>,
        assetsInObserved: Int,
        excludedCandidateCount: Int = 0,
        pendingReviewCandidates: [ServerAsset] = [],
        heldByQuarantineCandidates: [ServerAsset] = [],
        recycledExclusionCandidates: [ServerAsset] = [],
        aliveOnPhoneCandidateCount: Int = 0
    ) {
        self.deleteCandidates = deleteCandidates
        self.newlyObservedChecksums = newlyObservedChecksums
        self.assetsInObserved = assetsInObserved
        self.excludedCandidateCount = excludedCandidateCount
        self.pendingReviewCandidates = pendingReviewCandidates
        self.heldByQuarantineCandidates = heldByQuarantineCandidates
        self.recycledExclusionCandidates = recycledExclusionCandidates
        self.aliveOnPhoneCandidateCount = aliveOnPhoneCandidateCount
    }

    /// Move every `deleteCandidate` into `pendingReviewCandidates`. Used
    /// when the platform-side reconciler signals that this scan rebuilt
    /// the index after losing prior state (e.g. iOS persistent-change
    /// token expired) — any candidate this pass arrived without a
    /// quarantine clock, so user review is required regardless of
    /// strictness. Pure transform; lives here so the eventual Kotlin
    /// port reuses it.
    public func gatedForReview() -> ReconciliationOutput {
        guard !deleteCandidates.isEmpty else { return self }
        return ReconciliationOutput(
            deleteCandidates: [],
            newlyObservedChecksums: newlyObservedChecksums,
            assetsInObserved: assetsInObserved,
            excludedCandidateCount: excludedCandidateCount,
            pendingReviewCandidates: deleteCandidates + pendingReviewCandidates,
            heldByQuarantineCandidates: heldByQuarantineCandidates,
            recycledExclusionCandidates: recycledExclusionCandidates,
            aliveOnPhoneCandidateCount: aliveOnPhoneCandidateCount
        )
    }
}

/// Pure function that maps a `ReconciliationInput` to a
/// `ReconciliationOutput`. No I/O, no state, no platform APIs — the test
/// suite is the conformance spec, and this is the piece a Kotlin port would
/// re-implement first.
public enum ReconciliationEngine {
    /// Find SHA1s in a "limbo" state: present in `ObservedStore` (cairn
    /// has hashed them before), absent from the current local library
    /// (the asset is no longer on the device), and **never recorded in
    /// `ConfirmedDeletedStore`** (no deletion was ever stamped). Also
    /// excludes user-protected checksums so excluded items don't get
    /// retroactively stamped.
    ///
    /// In normal operation these sets should be empty — the
    /// reconciler's change-log + orphan-sweep paths stamp every
    /// observed-then-deleted SHA1 with `now` so the quarantine clock
    /// can run. But several edge cases can produce limbo entries:
    ///
    /// - A reconciler scan that wrote to `LocalHashStore` for some ids,
    ///   then was interrupted (app suspension, task cancellation) before
    ///   the batch `commitObservations` paired write completed for the
    ///   in-flight id; the next scan finds the asset deleted with no
    ///   matching cache entry to stamp from.
    /// - `LocalHashStore.set(_:for:modificationDate:)` deleting prior
    ///   rows during a re-hash while the reconciler's `retiredByEdit`
    ///   accounting races; the prior bytes leave the cache without
    ///   going through the edit-retirement quarantine path.
    /// - A `deletedLocalIdentifier` event arriving for an id whose
    ///   `LocalHashStore[id]` was already cleared by some earlier
    ///   path; the deletion handler sees an empty cached set and stamps
    ///   nothing.
    ///
    /// The recovery strategy: stamp limbo SHA1s into `ConfirmedDeleted`
    /// with `now`, starting their quarantine clock fresh. In `.trusting`
    /// mode this turns "instantly ready to trash (unconfirmed)" into
    /// "held for 14 days, then ready to trash" — the user gets a window
    /// to catch and exclude before propagation. Safe: these checksums
    /// have already been judged "absent from device," so stamping
    /// preserves the engine's existing semantics, it just routes them
    /// through the held bucket first.
    ///
    /// Run once per sync just before building the engine input.
    public static func limboChecksums(
        observed: Set<Checksum>,
        currentLocal: Set<Checksum>,
        confirmedDeleted: Set<Checksum>,
        excluded: Set<Checksum>
    ) -> Set<Checksum> {
        observed
            .subtracting(currentLocal)
            .subtracting(confirmedDeleted)
            .subtracting(excluded)
    }

    /// Four-pass classification:
    ///
    ///   1. Diff: pick non-trashed server assets whose checksum is in
    ///      observed but NOT in current-local (the negative signal).
    ///   2. Exclusions: drop anything the user has explicitly protected.
    ///   3. Quarantine: split confirmed-deleted checksums into in-window
    ///      vs past-window using `input.now` and `quarantineDays`.
    ///   4. Strictness + quarantine gate: route each surviving candidate
    ///      into `deleteCandidates`, `pendingReviewCandidates`, or
    ///      `heldByQuarantineCandidates`.
    public static func compute(_ input: ReconciliationInput) -> ReconciliationOutput {
        // Scope filter (Wave 5: scope-aware indexing). When the user has
        // restricted cairn to specific Photos albums, only Observed
        // entries whose album tags intersect the scope are considered.
        // Out-of-scope entries (and untagged-legacy ones) drop out
        // before the diff runs — they don't become candidates and they
        // don't count toward `assetsInObserved` (the safety-rails
        // denominator). When either side of the pair is nil we fall
        // back to full-library behavior.
        let effectiveObserved: Set<Checksum>
        if let tags = input.observedAlbumTags, let scope = input.selectedAlbumScope {
            effectiveObserved = input.observedChecksums.filter { ck in
                guard let entryTags = tags[ck] else { return false }
                return !entryTags.isDisjoint(with: scope)
            }
        } else {
            effectiveObserved = input.observedChecksums
        }

        let newlyObserved = input.currentLocalChecksums.subtracting(effectiveObserved)

        // Pass 1: would-be candidates, ignoring exclusions/quarantine/strictness.
        // Includes the alive-on-phone safety check: when the caller
        // supplies `alivePhoneAssetKeys`, a server asset whose
        // `(originalFileName, fileCreatedAt)` matches a currently-alive
        // phone asset is treated as "still here, bytes diverged" rather
        // than deleted. This is the defense against false-positive
        // candidates that arise when an upload-time-edit was later
        // reverted on the phone — server has the rendered bytes, phone
        // has the original bytes, neither has actually been deleted.
        let aliveProtectedKeys = input.alivePhoneAssetKeys
        let wouldBeCandidatesRaw = input.serverAssets.filter { asset in
            guard !asset.isTrashed else { return false }
            return effectiveObserved.contains(asset.checksum)
                && !input.currentLocalChecksums.contains(asset.checksum)
        }
        let wouldBeCandidates: [ServerAsset]
        let aliveProtectedCount: Int
        if let aliveProtectedKeys {
            var kept: [ServerAsset] = []
            kept.reserveCapacity(wouldBeCandidatesRaw.count)
            var dropped = 0
            for asset in wouldBeCandidatesRaw {
                if let filename = asset.originalFileName, !filename.isEmpty,
                   let created = asset.fileCreatedAt,
                   aliveProtectedKeys.contains(
                       AlivePhoneAssetKey(
                           filename: filename,
                           secondsSince1970: Int(created.timeIntervalSince1970)
                       )
                   )
                {
                    dropped += 1
                } else {
                    kept.append(asset)
                }
            }
            wouldBeCandidates = kept
            aliveProtectedCount = dropped
        } else {
            wouldBeCandidates = wouldBeCandidatesRaw
            aliveProtectedCount = 0
        }

        // Pass 2a: detect "recycled" exclusions — checksums the user
        // excluded (typically via "restore via cairn" → auto-exclude),
        // but which a later confirmed-delete signal post-dates. The
        // user effectively re-cycled the photo: restored, re-added to
        // the phone, then deleted again. Their original "preserve on
        // Immich" preference is contradicted by the new explicit
        // delete; surface for review rather than silently keeping
        // the exclusion.
        let recycledChecksums: Set<Checksum>
        if let excludedAt = input.excludedAtByChecksum {
            var recycled = Set<Checksum>()
            for ck in input.excludedChecksums {
                guard let added = excludedAt[ck],
                      let confirmed = input.confirmedDeletedAt[ck],
                      confirmed > added else { continue }
                recycled.insert(ck)
            }
            recycledChecksums = recycled
        } else {
            recycledChecksums = []
        }

        let recycledCandidates = wouldBeCandidates.filter { recycledChecksums.contains($0.checksum) }

        // Pass 2b: drop excluded checksums (including the recycled
        // ones — those flow into their own bucket and aren't
        // double-counted in delete/pending pipelines).
        let postExclusion = wouldBeCandidates.filter { !input.excludedChecksums.contains($0.checksum) }
        let excludedCount = wouldBeCandidates.count - postExclusion.count - recycledCandidates.count

        // Pass 3: partition the confirmed-deleted map into in-quarantine vs
        // past-quarantine. `quarantineDays <= 0` collapses everything to
        // past-quarantine (held bucket is always empty).
        let quarantineInterval = TimeInterval(max(0, input.quarantineDays) * 86_400)
        var inQuarantine: Set<Checksum> = []
        var pastQuarantine: Set<Checksum> = []
        inQuarantine.reserveCapacity(input.confirmedDeletedAt.count)
        pastQuarantine.reserveCapacity(input.confirmedDeletedAt.count)
        for (checksum, confirmedAt) in input.confirmedDeletedAt {
            if confirmedAt.addingTimeInterval(quarantineInterval) > input.now {
                inQuarantine.insert(checksum)
            } else {
                pastQuarantine.insert(checksum)
            }
        }

        // Pass 4: strictness + quarantine gate.
        //
        // Held-by-quarantine is common to both modes — a freshly-confirmed
        // deletion always waits out the window. Strictness governs how
        // *unconfirmed* diff candidates (in observed, absent locally, but
        // never surfaced by `fetchPersistentChanges`) are handled:
        //   - `.trusting`: unconfirmed candidates flow straight to
        //     `deleteCandidates`. The observed negative signal alone is
        //     enough. Pending = held-by-quarantine only.
        //   - `.strict`: unconfirmed candidates also land in pending.
        //     Trashing requires both the positive signal AND an elapsed
        //     quarantine. `pending` = held ∪ unconfirmed.
        let candidates: [ServerAsset]
        let pending: [ServerAsset]
        let held: [ServerAsset]
        switch input.strictness {
        case .autonomous:
            candidates = postExclusion
            pending = []
            held = []
        case .trusting:
            held = postExclusion.filter { inQuarantine.contains($0.checksum) }
            candidates = postExclusion.filter { !inQuarantine.contains($0.checksum) }
            pending = held
        case .strict:
            held = postExclusion.filter { inQuarantine.contains($0.checksum) }
            candidates = postExclusion.filter { pastQuarantine.contains($0.checksum) }
            pending = postExclusion.filter { !pastQuarantine.contains($0.checksum) }
        }

        let inObserved = input.serverAssets.reduce(into: 0) { count, asset in
            if !asset.isTrashed, effectiveObserved.contains(asset.checksum) {
                count += 1
            }
        }

        return ReconciliationOutput(
            deleteCandidates: candidates,
            newlyObservedChecksums: newlyObserved,
            assetsInObserved: inObserved,
            excludedCandidateCount: excludedCount,
            pendingReviewCandidates: pending,
            heldByQuarantineCandidates: held,
            recycledExclusionCandidates: recycledCandidates,
            aliveOnPhoneCandidateCount: aliveProtectedCount
        )
    }
}
