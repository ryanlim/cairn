import Foundation
import Testing
@testable import CairnCore

@Suite("ReconciliationEngine")
struct ReconciliationEngineTests {

    private func asset(_ id: String, _ checksum: String, livePhotoVideoId: String? = nil, isTrashed: Bool = false) -> ServerAsset {
        ServerAsset(id: id, checksum: Checksum(base64: checksum), livePhotoVideoId: livePhotoVideoId, isTrashed: isTrashed)
    }

    private func checksums(_ values: String...) -> Set<Checksum> {
        Set(values.map { Checksum(base64: $0) })
    }

    /// Convenience: "confirmed long ago, past any reasonable quarantine window".
    private func pastConfirmed(_ values: String...) -> [Checksum: Date] {
        var out: [Checksum: Date] = [:]
        for v in values {
            out[Checksum(base64: v)] = .distantPast
        }
        return out
    }

    @Test("deletes a server asset whose checksum is in ever-seen but not in current-local")
    func deletesSimpleCase() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B")],
            currentLocalChecksums: checksums("A"),
            everSeenChecksums: checksums("A", "B")
        ))
        #expect(output.deleteCandidates.map(\.id) == ["s2"])
    }

    @Test("never deletes a server asset whose checksum was never on the iPhone — Mac-only uploads are safe")
    func spareServerAssetNeverSeenLocally() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "MAC_ONLY")],
            currentLocalChecksums: checksums("A"),
            everSeenChecksums: checksums("A")
        ))
        #expect(output.deleteCandidates.isEmpty)
    }

    @Test("first run with empty ever-seen set produces no deletions and seeds ever-seen with all current checksums")
    func firstRunSeedsOnly() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B"), asset("s3", "C")],
            currentLocalChecksums: checksums("A", "B"),
            everSeenChecksums: []
        ))
        #expect(output.deleteCandidates.isEmpty)
        #expect(output.newlyObservedChecksums == checksums("A", "B"))
    }

    @Test("empty local library with populated ever-seen would flag everything — engine emits it; safety rails must catch")
    func emptyLocalFlagsEverything() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B")],
            currentLocalChecksums: [],
            everSeenChecksums: checksums("A", "B")
        ))
        #expect(Set(output.deleteCandidates.map(\.id)) == ["s1", "s2"])
    }

    @Test("assets already trashed on server are excluded from candidates and from the ever-seen denominator")
    func ignoresTrashedServerAssets() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A", isTrashed: true), asset("s2", "B")],
            currentLocalChecksums: checksums("B"),
            everSeenChecksums: checksums("A", "B")
        ))
        #expect(output.deleteCandidates.isEmpty)
        #expect(output.assetsInEverSeen == 1)
    }

    @Test("newly observed checksums reflect additions since last ever-seen snapshot")
    func newlyObservedReflectsAdditions() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [],
            currentLocalChecksums: checksums("A", "B", "C"),
            everSeenChecksums: checksums("A")
        ))
        #expect(output.newlyObservedChecksums == checksums("B", "C"))
    }

    @Test("a server asset re-appearing locally (e.g. photo restored from iOS Recently Deleted) is not a delete candidate")
    func restoredLocalNotCandidate() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A")],
            currentLocalChecksums: checksums("A"),
            everSeenChecksums: checksums("A")
        ))
        #expect(output.deleteCandidates.isEmpty)
    }

    @Test("duplicate server entries for the same checksum are all flagged if the content is gone locally")
    func duplicateServerEntriesAllFlagged() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "A")],
            currentLocalChecksums: [],
            everSeenChecksums: checksums("A")
        ))
        #expect(Set(output.deleteCandidates.map(\.id)) == ["s1", "s2"])
    }

    @Test("excluded checksums are filtered out of candidates and reported in excludedCandidateCount")
    func exclusionFiltersOutCandidates() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B"), asset("s3", "C")],
            currentLocalChecksums: [],
            everSeenChecksums: checksums("A", "B", "C"),
            excludedChecksums: checksums("B")
        ))
        #expect(Set(output.deleteCandidates.map(\.id)) == ["s1", "s3"])
        #expect(output.excludedCandidateCount == 1)
    }

    @Test("exclusion has no effect on assets that wouldn't have been candidates anyway")
    func exclusionDoesNotInflateExcludedCount() {
        // X is excluded but not in ever-seen, so it was never a candidate. Excluding
        // it should not bump excludedCandidateCount; that count is for would-be
        // deletions actually saved by the exclusion list.
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "X")],
            currentLocalChecksums: [],
            everSeenChecksums: checksums("A"),
            excludedChecksums: checksums("X")
        ))
        #expect(Set(output.deleteCandidates.map(\.id)) == ["s1"])
        #expect(output.excludedCandidateCount == 0)
    }

    @Test("default excludedChecksums is empty — old call sites continue to work")
    func defaultExclusionEmpty() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A")],
            currentLocalChecksums: [],
            everSeenChecksums: checksums("A")
        ))
        #expect(output.deleteCandidates.map(\.id) == ["s1"])
        #expect(output.excludedCandidateCount == 0)
        #expect(output.pendingReviewCandidates.isEmpty)
    }

    @Test("strict mode: only candidates with past-quarantine confirmed-deleted checksums end up in deleteCandidates; rest are pending")
    func strictModePartitionsCandidates() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B"), asset("s3", "C")],
            currentLocalChecksums: [],
            everSeenChecksums: checksums("A", "B", "C"),
            confirmedDeletedAt: pastConfirmed("A", "B"),
            strictness: .strict
        ))
        #expect(Set(output.deleteCandidates.map(\.id)) == ["s1", "s2"])
        #expect(output.pendingReviewCandidates.map(\.id) == ["s3"])
    }

    @Test("strict mode with empty confirmed-deleted set holds every candidate for review")
    func strictModeEmptyConfirmedHoldsEverything() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B")],
            currentLocalChecksums: [],
            everSeenChecksums: checksums("A", "B"),
            confirmedDeletedAt: [:],
            strictness: .strict
        ))
        #expect(output.deleteCandidates.isEmpty)
        #expect(Set(output.pendingReviewCandidates.map(\.id)) == ["s1", "s2"])
    }

    @Test("trusting mode with empty confirmed-deleted: every diff candidate is eligible (nothing held)")
    func trustingModeIgnoresConfirmed() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B")],
            currentLocalChecksums: [],
            everSeenChecksums: checksums("A", "B"),
            confirmedDeletedAt: [:],
            strictness: .trusting
        ))
        #expect(Set(output.deleteCandidates.map(\.id)) == ["s1", "s2"])
        #expect(output.pendingReviewCandidates.isEmpty)
        #expect(output.heldByQuarantineCandidates.isEmpty)
    }

    @Test("strict + exclusion: excluded candidates are dropped before the strictness gate, never appear in pending-review either")
    func strictAndExclusionInteraction() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B"), asset("s3", "C")],
            currentLocalChecksums: [],
            everSeenChecksums: checksums("A", "B", "C"),
            excludedChecksums: checksums("B"),              // user said: never trash this one
            confirmedDeletedAt: pastConfirmed("A"),          // user deleted A; C status unknown
            strictness: .strict
        ))
        #expect(output.deleteCandidates.map(\.id) == ["s1"])         // confirmed past quarantine
        #expect(output.pendingReviewCandidates.map(\.id) == ["s3"])  // unconfirmed
        #expect(output.excludedCandidateCount == 1)                   // s2 protected
    }

    @Test("default strictness is .trusting — preserves existing behavior of older call sites")
    func defaultStrictnessIsTrusting() {
        // Build the input via the convenience init that doesn't pass strictness.
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A")],
            currentLocalChecksums: [],
            everSeenChecksums: checksums("A")
        ))
        #expect(output.deleteCandidates.map(\.id) == ["s1"])
        #expect(output.pendingReviewCandidates.isEmpty)
    }

    // MARK: - Quarantine

    @Test("strict mode: freshly-confirmed checksums are held by quarantine, not eligible to trash")
    func strictQuarantineHoldsFreshConfirmed() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        // confirmedAt == now: definitely inside any non-zero window.
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B")],
            currentLocalChecksums: [],
            everSeenChecksums: checksums("A", "B"),
            confirmedDeletedAt: [Checksum(base64: "A"): now, Checksum(base64: "B"): now],
            now: now,
            quarantineDays: 14,
            strictness: .strict
        ))
        #expect(output.deleteCandidates.isEmpty)
        #expect(Set(output.heldByQuarantineCandidates.map(\.id)) == ["s1", "s2"])
        // In strict mode, held items flow through pending-review as well.
        #expect(Set(output.pendingReviewCandidates.map(\.id)) == ["s1", "s2"])
    }

    @Test("strict mode: confirmed-deleted past the quarantine window becomes eligible to trash")
    func strictQuarantineElapsesPastWindow() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        // 30 days ago, window is 14 days → past quarantine.
        let past = now.addingTimeInterval(-30 * 86_400)
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A")],
            currentLocalChecksums: [],
            everSeenChecksums: checksums("A"),
            confirmedDeletedAt: [Checksum(base64: "A"): past],
            now: now,
            quarantineDays: 14,
            strictness: .strict
        ))
        #expect(output.deleteCandidates.map(\.id) == ["s1"])
        #expect(output.heldByQuarantineCandidates.isEmpty)
        #expect(output.pendingReviewCandidates.isEmpty)
    }

    @Test("trusting mode: freshly-confirmed items are still held by quarantine; unconfirmed items flow through")
    func trustingModeHeldByQuarantine() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B"), asset("s3", "C")],
            currentLocalChecksums: [],
            everSeenChecksums: checksums("A", "B", "C"),
            confirmedDeletedAt: [Checksum(base64: "A"): now],  // fresh — in quarantine
            now: now,
            quarantineDays: 14,
            strictness: .trusting
        ))
        // A held by quarantine; B and C unconfirmed — trusting lets them trash.
        #expect(Set(output.deleteCandidates.map(\.id)) == ["s2", "s3"])
        #expect(output.heldByQuarantineCandidates.map(\.id) == ["s1"])
        #expect(output.pendingReviewCandidates.map(\.id) == ["s1"])
    }

    @Test("quarantineDays = 0 collapses the held bucket — every confirmed entry is immediately past-quarantine")
    func quarantineDaysZeroCollapsesHeld() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B")],
            currentLocalChecksums: [],
            everSeenChecksums: checksums("A", "B"),
            confirmedDeletedAt: [Checksum(base64: "A"): now, Checksum(base64: "B"): now],
            now: now,
            quarantineDays: 0,
            strictness: .strict
        ))
        #expect(Set(output.deleteCandidates.map(\.id)) == ["s1", "s2"])
        #expect(output.heldByQuarantineCandidates.isEmpty)
        #expect(output.pendingReviewCandidates.isEmpty)
    }

    @Test("heldByQuarantineCandidates is always a proper subset of pendingReviewCandidates")
    func heldIsSubsetOfPending() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        // Mix: A fresh-confirmed (held), B unconfirmed (pending in strict), C past (eligible).
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B"), asset("s3", "C")],
            currentLocalChecksums: [],
            everSeenChecksums: checksums("A", "B", "C"),
            confirmedDeletedAt: [
                Checksum(base64: "A"): now,
                Checksum(base64: "C"): .distantPast,
            ],
            now: now,
            quarantineDays: 14,
            strictness: .strict
        ))
        let pendingIds = Set(output.pendingReviewCandidates.map(\.id))
        let heldIds = Set(output.heldByQuarantineCandidates.map(\.id))
        #expect(heldIds.isSubset(of: pendingIds))
        // A (fresh-confirmed) is held; B (unconfirmed) is pending but not
        // held; C (past-quarantine confirmed) is eligible to trash.
        #expect(heldIds == ["s1"])
        #expect(pendingIds == ["s1", "s2"])
        #expect(output.deleteCandidates.map(\.id) == ["s3"])
    }
}
