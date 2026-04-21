import Foundation

public struct SafetyConfig: Sendable {
    public let maxDeletePercent: Double
    /// Threshold-percent abort fires only when the candidate count also exceeds this floor.
    /// Without it, the percent rail is unusable for small libraries (1/22 already exceeds 1%).
    /// `emptyLocalLibrary` still catches the catastrophic case at any size.
    public let minDeleteCountForThreshold: Int
    public let abortIfServerReturnsZero: Bool
    public let abortOnEmptyLocalLibrary: Bool
    public let firstRunMustBeDryRun: Bool

    public init(
        maxDeletePercent: Double = 0.01,
        minDeleteCountForThreshold: Int = 5,
        abortIfServerReturnsZero: Bool = true,
        abortOnEmptyLocalLibrary: Bool = true,
        firstRunMustBeDryRun: Bool = true
    ) {
        self.maxDeletePercent = maxDeletePercent
        self.minDeleteCountForThreshold = minDeleteCountForThreshold
        self.abortIfServerReturnsZero = abortIfServerReturnsZero
        self.abortOnEmptyLocalLibrary = abortOnEmptyLocalLibrary
        self.firstRunMustBeDryRun = firstRunMustBeDryRun
    }
}

public enum SafetyDecision: Sendable, Equatable {
    case proceed
    case abort(reason: AbortReason)

    public enum AbortReason: Sendable, Equatable, CustomStringConvertible {
        case emptyServerResponse
        case emptyLocalLibrary
        case thresholdExceeded(candidateCount: Int, assetsInEverSeen: Int, percent: Double, limit: Double)
        case firstRunNotDryRun

        public var description: String {
            switch self {
            case .emptyServerResponse:
                return "emptyServerResponse — server returned 0 assets, refusing to act on what looks like a transient API problem"
            case .emptyLocalLibrary:
                return "emptyLocalLibrary — local checksum set is empty (Photos permission revoked? Library not loaded?)"
            case .firstRunNotDryRun:
                return "firstRunNotDryRun — the first run on a fresh ever-seen store must be a dry-run"
            case .thresholdExceeded(let candidates, let total, let percent, let limit):
                let p = String(format: "%.2f", percent * 100)
                let l = String(format: "%.2f", limit * 100)
                return "thresholdExceeded — would delete \(candidates) of \(total) in-purview assets (\(p)%); limit is \(l)%"
            }
        }
    }
}

public enum SafetyRails {
    public static func evaluate(
        reconciliation: ReconciliationOutput,
        totalServerAssets: Int,
        currentLocalCount: Int,
        isFirstRun: Bool,
        isDryRun: Bool,
        config: SafetyConfig
    ) -> SafetyDecision {
        if config.abortIfServerReturnsZero, totalServerAssets == 0 {
            return .abort(reason: .emptyServerResponse)
        }

        if config.abortOnEmptyLocalLibrary, currentLocalCount == 0 {
            return .abort(reason: .emptyLocalLibrary)
        }

        if config.firstRunMustBeDryRun, isFirstRun, !isDryRun {
            return .abort(reason: .firstRunNotDryRun)
        }

        let denominator = reconciliation.assetsInEverSeen
        let candidateCount = reconciliation.deleteCandidates.count
        if denominator > 0, candidateCount > config.minDeleteCountForThreshold {
            let percent = Double(candidateCount) / Double(denominator)
            if percent > config.maxDeletePercent {
                return .abort(reason: .thresholdExceeded(
                    candidateCount: candidateCount,
                    assetsInEverSeen: denominator,
                    percent: percent,
                    limit: config.maxDeletePercent
                ))
            }
        }

        return .proceed
    }
}
