import Foundation

public struct ReconciliationInput: Sendable {
    public let serverAssets: [ServerAsset]
    public let currentLocalChecksums: Set<Checksum>
    public let everSeenChecksums: Set<Checksum>
    /// Checksums the user has explicitly excluded from reaping. Server assets
    /// with these checksums are filtered out of the candidate set even if the
    /// reconciliation logic would otherwise flag them. Empty set = no exclusions.
    public let excludedChecksums: Set<Checksum>
    /// Checksums positively observed in iOS's Recently Deleted album (Wave 4).
    /// In `.strict` mode, only candidates whose checksums appear here flow
    /// through to trash; the rest are held in `pendingReviewCandidates`.
    /// Empty set in `.trusting` mode is fine — the strictness flag controls
    /// whether this gate fires.
    public let confirmedDeletedChecksums: Set<Checksum>
    /// Whether to require a positive deletion signal before trashing.
    public let strictness: DeletionStrictness

    public init(
        serverAssets: [ServerAsset],
        currentLocalChecksums: Set<Checksum>,
        everSeenChecksums: Set<Checksum>,
        excludedChecksums: Set<Checksum> = [],
        confirmedDeletedChecksums: Set<Checksum> = [],
        strictness: DeletionStrictness = .trusting
    ) {
        self.serverAssets = serverAssets
        self.currentLocalChecksums = currentLocalChecksums
        self.everSeenChecksums = everSeenChecksums
        self.excludedChecksums = excludedChecksums
        self.confirmedDeletedChecksums = confirmedDeletedChecksums
        self.strictness = strictness
    }
}

public struct ReconciliationOutput: Sendable, Equatable {
    /// Assets eligible for trashing right now. In `.strict` mode this only
    /// includes candidates whose checksums are in `confirmedDeletedChecksums`.
    public let deleteCandidates: [ServerAsset]
    public let newlyObservedChecksums: Set<Checksum>
    public let assetsInEverSeen: Int
    /// Number of would-be candidates that were filtered out by the exclusion list.
    public let excludedCandidateCount: Int
    /// In `.strict` mode: candidates that the diff identified but for which
    /// no positive deletion signal has been observed. These should be surfaced
    /// to the user for manual approval rather than trashed silently. Empty in
    /// `.trusting` mode (those candidates are already in `deleteCandidates`).
    public let pendingReviewCandidates: [ServerAsset]

    public init(
        deleteCandidates: [ServerAsset],
        newlyObservedChecksums: Set<Checksum>,
        assetsInEverSeen: Int,
        excludedCandidateCount: Int = 0,
        pendingReviewCandidates: [ServerAsset] = []
    ) {
        self.deleteCandidates = deleteCandidates
        self.newlyObservedChecksums = newlyObservedChecksums
        self.assetsInEverSeen = assetsInEverSeen
        self.excludedCandidateCount = excludedCandidateCount
        self.pendingReviewCandidates = pendingReviewCandidates
    }
}

public enum ReconciliationEngine {
    public static func compute(_ input: ReconciliationInput) -> ReconciliationOutput {
        let newlyObserved = input.currentLocalChecksums.subtracting(input.everSeenChecksums)

        // Pass 1: would-be candidates ignoring exclusions and strictness.
        let wouldBeCandidates = input.serverAssets.filter { asset in
            guard !asset.isTrashed else { return false }
            return input.everSeenChecksums.contains(asset.checksum)
                && !input.currentLocalChecksums.contains(asset.checksum)
        }

        // Pass 2: drop excluded.
        let postExclusion = wouldBeCandidates.filter { !input.excludedChecksums.contains($0.checksum) }
        let excludedCount = wouldBeCandidates.count - postExclusion.count

        // Pass 3: strictness gate. In strict mode, only candidates whose
        // checksums are positively confirmed proceed; the rest are held.
        let candidates: [ServerAsset]
        let pendingReview: [ServerAsset]
        switch input.strictness {
        case .trusting:
            candidates = postExclusion
            pendingReview = []
        case .strict:
            candidates = postExclusion.filter { input.confirmedDeletedChecksums.contains($0.checksum) }
            pendingReview = postExclusion.filter { !input.confirmedDeletedChecksums.contains($0.checksum) }
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
            pendingReviewCandidates: pendingReview
        )
    }
}
