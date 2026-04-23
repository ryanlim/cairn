import Foundation

/// Tunable thresholds for `SafetyRails.evaluate`. Defaults match Phase 1 CLI
/// behavior (1% cap, 5-asset floor, first-run-must-be-dry-run on); tests and
/// advanced users can override per-call.
public struct SafetyConfig: Sendable {
    /// Fraction of in-purview assets that may be trashed in one run before
    /// the percent rail fires. Default 0.01 (1%).
    public let maxDeletePercent: Double
    /// Floor below which the percent rail is suppressed. Without this,
    /// `maxDeletePercent` is unusable for small libraries — 1 of 22 already
    /// exceeds 1%. `emptyLocalLibrary` still catches the catastrophic case
    /// (zero local assets) at any size, so small users aren't unprotected.
    public let minDeleteCountForThreshold: Int
    /// Abort if the server returns zero assets — almost always a transient
    /// API problem rather than a truly empty library.
    public let abortIfServerReturnsZero: Bool
    /// Abort if the local checksum set is empty. Usually means Photos
    /// permission was revoked or the library hasn't finished loading.
    public let abortOnEmptyLocalLibrary: Bool
    /// Require the first run against a fresh ever-seen store to be a
    /// dry-run. Forces the user to eyeball the candidate list before
    /// anything destructive happens.
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

/// Outcome of `SafetyRails.evaluate`. `.proceed` means the caller may hand
/// the candidate list to `TrashOrchestrator`; `.abort` means refuse the run
/// and surface `reason.description` to the user.
public enum SafetyDecision: Sendable, Equatable {
    case proceed
    case abort(reason: AbortReason)

    /// Mutually-exclusive reasons a run can be refused. Descriptions are
    /// written for direct display to the user — no further formatting is
    /// expected of the caller.
    public enum AbortReason: Sendable, Equatable, CustomStringConvertible {
        /// Server returned 0 assets. Treated as a transient API problem, not
        /// as a truly empty library.
        case emptyServerResponse
        /// Local checksum set is empty. Photos permission revoked or the
        /// library scan hasn't completed.
        case emptyLocalLibrary
        /// Candidate count exceeds the percent cap, and is past the floor
        /// that suppresses the rail for tiny libraries.
        case thresholdExceeded(candidateCount: Int, assetsInEverSeen: Int, percent: Double, limit: Double)
        /// First run against a fresh ever-seen store wasn't a dry-run.
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

/// Pre-flight sanity checks the caller runs immediately before
/// `TrashOrchestrator.run`. Pure function — the rails exist to turn
/// catastrophic mistakes (empty library, stale server response, runaway
/// delete count) into clean aborts rather than data loss.
public enum SafetyRails {
    /// Evaluate the run against the configured rails. Checks fire in a fixed
    /// order, and the first one that trips short-circuits — so an empty
    /// server response is reported even if the percent rail would also fire.
    ///
    /// The percent rail uses `reconciliation.assetsInEverSeen` (not the raw
    /// server total) as its denominator, so libraries that are partially
    /// unsynced don't look like candidate-heavy deletions.
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

        // Percent rail. Guarded by the floor so that a library with, say,
        // 22 ever-seen assets doesn't trip on a single legitimate delete
        // (1/22 ≈ 4.5% > 1% default). The floor is strict-greater-than, so
        // `minDeleteCountForThreshold = 5` means counts of 6+ are gated.
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
