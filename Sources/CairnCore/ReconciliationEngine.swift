import Foundation

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
    public let everSeenChecksums: Set<Checksum>
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

    public init(
        serverAssets: [ServerAsset],
        currentLocalChecksums: Set<Checksum>,
        everSeenChecksums: Set<Checksum>,
        excludedChecksums: Set<Checksum> = [],
        confirmedDeletedAt: [Checksum: Date] = [:],
        now: Date = Date(),
        quarantineDays: Int = 14,
        strictness: DeletionStrictness = .trusting
    ) {
        self.serverAssets = serverAssets
        self.currentLocalChecksums = currentLocalChecksums
        self.everSeenChecksums = everSeenChecksums
        self.excludedChecksums = excludedChecksums
        self.confirmedDeletedAt = confirmedDeletedAt
        self.now = now
        self.quarantineDays = quarantineDays
        self.strictness = strictness
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
    /// expected to union these into the persistent `EverSeenStore`.
    public let newlyObservedChecksums: Set<Checksum>
    /// Count of non-trashed server assets whose checksum is in the ever-seen
    /// set. Used as the denominator for `SafetyRails`'s percent cap so
    /// libraries that are partially-synced don't trip the rail.
    public let assetsInEverSeen: Int
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

    public init(
        deleteCandidates: [ServerAsset],
        newlyObservedChecksums: Set<Checksum>,
        assetsInEverSeen: Int,
        excludedCandidateCount: Int = 0,
        pendingReviewCandidates: [ServerAsset] = [],
        heldByQuarantineCandidates: [ServerAsset] = []
    ) {
        self.deleteCandidates = deleteCandidates
        self.newlyObservedChecksums = newlyObservedChecksums
        self.assetsInEverSeen = assetsInEverSeen
        self.excludedCandidateCount = excludedCandidateCount
        self.pendingReviewCandidates = pendingReviewCandidates
        self.heldByQuarantineCandidates = heldByQuarantineCandidates
    }
}

/// Pure function that maps a `ReconciliationInput` to a
/// `ReconciliationOutput`. No I/O, no state, no platform APIs — the test
/// suite is the conformance spec, and this is the piece a Kotlin port would
/// re-implement first.
public enum ReconciliationEngine {
    /// Four-pass classification:
    ///
    ///   1. Diff: pick non-trashed server assets whose checksum is in
    ///      ever-seen but NOT in current-local (the negative signal).
    ///   2. Exclusions: drop anything the user has explicitly protected.
    ///   3. Quarantine: split confirmed-deleted checksums into in-window
    ///      vs past-window using `input.now` and `quarantineDays`.
    ///   4. Strictness + quarantine gate: route each surviving candidate
    ///      into `deleteCandidates`, `pendingReviewCandidates`, or
    ///      `heldByQuarantineCandidates`.
    public static func compute(_ input: ReconciliationInput) -> ReconciliationOutput {
        let newlyObserved = input.currentLocalChecksums.subtracting(input.everSeenChecksums)

        // Pass 1: would-be candidates, ignoring exclusions/quarantine/strictness.
        let wouldBeCandidates = input.serverAssets.filter { asset in
            guard !asset.isTrashed else { return false }
            return input.everSeenChecksums.contains(asset.checksum)
                && !input.currentLocalChecksums.contains(asset.checksum)
        }

        // Pass 2: drop excluded checksums.
        let postExclusion = wouldBeCandidates.filter { !input.excludedChecksums.contains($0.checksum) }
        let excludedCount = wouldBeCandidates.count - postExclusion.count

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
        // *unconfirmed* diff candidates (in ever-seen, absent locally, but
        // never surfaced by `fetchPersistentChanges`) are handled:
        //   - `.trusting`: unconfirmed candidates flow straight to
        //     `deleteCandidates`. The ever-seen negative signal alone is
        //     enough. Pending = held-by-quarantine only.
        //   - `.strict`: unconfirmed candidates also land in pending.
        //     Trashing requires both the positive signal AND an elapsed
        //     quarantine. `pending` = held ∪ unconfirmed.
        let candidates: [ServerAsset]
        let pending: [ServerAsset]
        let held: [ServerAsset]
        switch input.strictness {
        case .trusting:
            held = postExclusion.filter { inQuarantine.contains($0.checksum) }
            candidates = postExclusion.filter { !inQuarantine.contains($0.checksum) }
            pending = held
        case .strict:
            held = postExclusion.filter { inQuarantine.contains($0.checksum) }
            candidates = postExclusion.filter { pastQuarantine.contains($0.checksum) }
            // Strict-mode pending = held (confirmed-but-fresh) plus
            // unconfirmed (never positively signalled). Expressed as the
            // negation of `pastQuarantine` so both groups fall in together.
            pending = postExclusion.filter { !pastQuarantine.contains($0.checksum) }
        }

        let inEverSeen = input.serverAssets.reduce(into: 0) { count, asset in
            if !asset.isTrashed, input.everSeenChecksums.contains(asset.checksum) {
                count += 1
            }
        }

        return ReconciliationOutput(
            deleteCandidates: candidates,
            newlyObservedChecksums: newlyObserved,
            assetsInEverSeen: inEverSeen,
            excludedCandidateCount: excludedCount,
            pendingReviewCandidates: pending,
            heldByQuarantineCandidates: held
        )
    }
}
