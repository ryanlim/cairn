import Foundation

public struct ReconciliationInput: Sendable {
    public let serverAssets: [ServerAsset]
    public let currentLocalChecksums: Set<Checksum>
    public let everSeenChecksums: Set<Checksum>
    /// Checksums the user has explicitly excluded from reaping. Server assets
    /// with these checksums are filtered out of the candidate set even if the
    /// reconciliation logic would otherwise flag them. Empty set = no exclusions.
    public let excludedChecksums: Set<Checksum>

    public init(
        serverAssets: [ServerAsset],
        currentLocalChecksums: Set<Checksum>,
        everSeenChecksums: Set<Checksum>,
        excludedChecksums: Set<Checksum> = []
    ) {
        self.serverAssets = serverAssets
        self.currentLocalChecksums = currentLocalChecksums
        self.everSeenChecksums = everSeenChecksums
        self.excludedChecksums = excludedChecksums
    }
}

public struct ReconciliationOutput: Sendable, Equatable {
    public let deleteCandidates: [ServerAsset]
    public let newlyObservedChecksums: Set<Checksum>
    public let assetsInEverSeen: Int
    /// Number of would-be candidates that were filtered out by the exclusion list.
    /// Useful for surfacing "N protected assets were skipped" in the UI.
    public let excludedCandidateCount: Int

    public init(
        deleteCandidates: [ServerAsset],
        newlyObservedChecksums: Set<Checksum>,
        assetsInEverSeen: Int,
        excludedCandidateCount: Int = 0
    ) {
        self.deleteCandidates = deleteCandidates
        self.newlyObservedChecksums = newlyObservedChecksums
        self.assetsInEverSeen = assetsInEverSeen
        self.excludedCandidateCount = excludedCandidateCount
    }
}

public enum ReconciliationEngine {
    public static func compute(_ input: ReconciliationInput) -> ReconciliationOutput {
        let newlyObserved = input.currentLocalChecksums.subtracting(input.everSeenChecksums)

        // Two-pass: first compute would-be candidates ignoring exclusions, then
        // filter — so we can report how many were protected.
        let wouldBeCandidates = input.serverAssets.filter { asset in
            guard !asset.isTrashed else { return false }
            return input.everSeenChecksums.contains(asset.checksum)
                && !input.currentLocalChecksums.contains(asset.checksum)
        }
        let candidates = wouldBeCandidates.filter { !input.excludedChecksums.contains($0.checksum) }
        let excludedCount = wouldBeCandidates.count - candidates.count

        let inEverSeen = input.serverAssets.reduce(into: 0) { count, asset in
            if !asset.isTrashed, input.everSeenChecksums.contains(asset.checksum) {
                count += 1
            }
        }

        return ReconciliationOutput(
            deleteCandidates: candidates,
            newlyObservedChecksums: newlyObserved,
            assetsInEverSeen: inEverSeen,
            excludedCandidateCount: excludedCount
        )
    }
}
