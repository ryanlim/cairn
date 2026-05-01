import Testing
@testable import CairnCore

@Suite("SafetyRails")
struct SafetyRailsTests {

    private func output(candidates: Int, inObserved: Int) -> ReconciliationOutput {
        let fakes = (0..<candidates).map {
            ServerAsset(id: "c\($0)", checksum: Checksum(base64: "X\($0)"))
        }
        return ReconciliationOutput(
            deleteCandidates: fakes,
            newlyObservedChecksums: [],
            assetsInObserved: inObserved
        )
    }

    @Test("proceeds under the threshold")
    func proceedsUnderThreshold() {
        let decision = SafetyRails.evaluate(
            reconciliation: output(candidates: 5, inObserved: 1000),
            totalServerAssets: 1200,
            currentLocalCount: 995,
            isFirstRun: false,
            isDryRun: false,
            config: .init(maxDeletePercent: 0.01)
        )
        #expect(decision == .proceed)
    }

    @Test("aborts above the threshold (both percent and absolute floor exceeded)")
    func abortsAboveThreshold() {
        let decision = SafetyRails.evaluate(
            reconciliation: output(candidates: 50, inObserved: 1000),
            totalServerAssets: 1200,
            currentLocalCount: 950,
            isFirstRun: false,
            isDryRun: false,
            config: .init(maxDeletePercent: 0.01)
        )
        if case .abort(.thresholdExceeded) = decision { } else {
            Issue.record("expected thresholdExceeded, got \(decision)")
        }
    }

    @Test("small absolute deletions proceed even when percent exceeds the limit (small-library protection)")
    func smallAbsoluteCountBypassesPercent() {
        // 3 of 22 = 13.6% — way over 1% — but 3 ≤ 5 floor, so percent rail does not fire.
        let decision = SafetyRails.evaluate(
            reconciliation: output(candidates: 3, inObserved: 22),
            totalServerAssets: 22,
            currentLocalCount: 19,
            isFirstRun: false,
            isDryRun: false,
            config: .init(maxDeletePercent: 0.01, minDeleteCountForThreshold: 5)
        )
        #expect(decision == .proceed)
    }

    @Test("just above the absolute floor with high percent aborts")
    func justAboveFloorAborts() {
        // 6 of 100 = 6% over 1%, and 6 > 5 floor → abort.
        let decision = SafetyRails.evaluate(
            reconciliation: output(candidates: 6, inObserved: 100),
            totalServerAssets: 100,
            currentLocalCount: 94,
            isFirstRun: false,
            isDryRun: false,
            config: .init(maxDeletePercent: 0.01, minDeleteCountForThreshold: 5)
        )
        if case .abort(.thresholdExceeded) = decision { } else {
            Issue.record("expected thresholdExceeded, got \(decision)")
        }
    }

    @Test("at-the-floor count proceeds (floor is exclusive: only counts STRICTLY above abort)")
    func atFloorProceeds() {
        // 5 of 50 = 10% over 1%, but 5 == 5 floor (not strictly greater) → proceed.
        let decision = SafetyRails.evaluate(
            reconciliation: output(candidates: 5, inObserved: 50),
            totalServerAssets: 50,
            currentLocalCount: 45,
            isFirstRun: false,
            isDryRun: false,
            config: .init(maxDeletePercent: 0.01, minDeleteCountForThreshold: 5)
        )
        #expect(decision == .proceed)
    }

    @Test("emptyLocalLibrary still fires regardless of floor — catastrophic case wins")
    func emptyLocalBeatsFloor() {
        // candidates=200 over a floor of 5, but local==0 should abort with emptyLocalLibrary first.
        let decision = SafetyRails.evaluate(
            reconciliation: output(candidates: 200, inObserved: 200),
            totalServerAssets: 200,
            currentLocalCount: 0,
            isFirstRun: false,
            isDryRun: false,
            config: .init(maxDeletePercent: 0.01, minDeleteCountForThreshold: 5)
        )
        #expect(decision == .abort(reason: .emptyLocalLibrary))
    }

    @Test("aborts when server returns zero assets")
    func abortsOnEmptyServer() {
        let decision = SafetyRails.evaluate(
            reconciliation: output(candidates: 0, inObserved: 0),
            totalServerAssets: 0,
            currentLocalCount: 500,
            isFirstRun: false,
            isDryRun: false,
            config: .init()
        )
        #expect(decision == .abort(reason: .emptyServerResponse))
    }

    @Test("aborts when the local library is empty — prevents nuking the whole server if Photos permission is borked")
    func abortsOnEmptyLocal() {
        let decision = SafetyRails.evaluate(
            reconciliation: output(candidates: 1000, inObserved: 1000),
            totalServerAssets: 1000,
            currentLocalCount: 0,
            isFirstRun: false,
            isDryRun: false,
            config: .init()
        )
        #expect(decision == .abort(reason: .emptyLocalLibrary))
    }

    @Test("first-ever run must be dry-run")
    func firstRunMustBeDryRun() {
        let decision = SafetyRails.evaluate(
            reconciliation: output(candidates: 0, inObserved: 0),
            totalServerAssets: 500,
            currentLocalCount: 500,
            isFirstRun: true,
            isDryRun: false,
            config: .init()
        )
        #expect(decision == .abort(reason: .firstRunNotDryRun))
    }

    @Test("first-run dry-run passes")
    func firstRunDryRunPasses() {
        let decision = SafetyRails.evaluate(
            reconciliation: output(candidates: 0, inObserved: 0),
            totalServerAssets: 500,
            currentLocalCount: 500,
            isFirstRun: true,
            isDryRun: true,
            config: .init()
        )
        #expect(decision == .proceed)
    }

    @Test("zero observed assets means no denominator — threshold check is skipped, empty-local still fires first")
    func zeroDenominatorSkipsThreshold() {
        let decision = SafetyRails.evaluate(
            reconciliation: output(candidates: 0, inObserved: 0),
            totalServerAssets: 100,
            currentLocalCount: 100,
            isFirstRun: false,
            isDryRun: true,
            config: .init()
        )
        #expect(decision == .proceed)
    }
}
