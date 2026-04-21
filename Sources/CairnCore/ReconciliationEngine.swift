import Foundation

public struct ReconciliationInput: Sendable {
    public let serverAssets: [ServerAsset]
    public let currentLocalChecksums: Set<Checksum>
    public let everSeenChecksums: Set<Checksum>

    public init(
        serverAssets: [ServerAsset],
        currentLocalChecksums: Set<Checksum>,
        everSeenChecksums: Set<Checksum>
    ) {
        self.serverAssets = serverAssets
        self.currentLocalChecksums = currentLocalChecksums
        self.everSeenChecksums = everSeenChecksums
    }
}

public struct ReconciliationOutput: Sendable, Equatable {
    public let deleteCandidates: [ServerAsset]
    public let newlyObservedChecksums: Set<Checksum>
    public let assetsInEverSeen: Int

    public init(
        deleteCandidates: [ServerAsset],
        newlyObservedChecksums: Set<Checksum>,
        assetsInEverSeen: Int
    ) {
        self.deleteCandidates = deleteCandidates
        self.newlyObservedChecksums = newlyObservedChecksums
        self.assetsInEverSeen = assetsInEverSeen
    }
}

public enum ReconciliationEngine {
    public static func compute(_ input: ReconciliationInput) -> ReconciliationOutput {
        let newlyObserved = input.currentLocalChecksums.subtracting(input.everSeenChecksums)

        let candidates = input.serverAssets.filter { asset in
            guard !asset.isTrashed else { return false }
            return input.everSeenChecksums.contains(asset.checksum)
                && !input.currentLocalChecksums.contains(asset.checksum)
        }

        let inEverSeen = input.serverAssets.reduce(into: 0) { count, asset in
            if !asset.isTrashed, input.everSeenChecksums.contains(asset.checksum) {
                count += 1
            }
        }

        return ReconciliationOutput(
            deleteCandidates: candidates,
            newlyObservedChecksums: newlyObserved,
            assetsInEverSeen: inEverSeen
        )
    }
}
