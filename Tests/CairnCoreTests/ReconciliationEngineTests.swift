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

    @Test("deletes a server asset whose checksum is in observed but not in current-local")
    func deletesSimpleCase() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B")],
            currentLocalChecksums: checksums("A"),
            observedChecksums: checksums("A", "B")
        ))
        #expect(output.deleteCandidates.map(\.id) == ["s2"])
    }

    @Test("never deletes a server asset whose checksum was never on the iPhone — Mac-only uploads are safe")
    func spareServerAssetNeverObservedLocally() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "MAC_ONLY")],
            currentLocalChecksums: checksums("A"),
            observedChecksums: checksums("A")
        ))
        #expect(output.deleteCandidates.isEmpty)
    }

    @Test("first run with empty observed set produces no deletions and seeds observed with all current checksums")
    func firstRunSeedsOnly() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B"), asset("s3", "C")],
            currentLocalChecksums: checksums("A", "B"),
            observedChecksums: []
        ))
        #expect(output.deleteCandidates.isEmpty)
        #expect(output.newlyObservedChecksums == checksums("A", "B"))
    }

    @Test("empty local library with populated observed would flag everything — engine emits it; safety rails must catch")
    func emptyLocalFlagsEverything() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B")],
            currentLocalChecksums: [],
            observedChecksums: checksums("A", "B")
        ))
        #expect(Set(output.deleteCandidates.map(\.id)) == ["s1", "s2"])
    }

    @Test("assets already trashed on server are excluded from candidates and from the observed denominator")
    func ignoresTrashedServerAssets() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A", isTrashed: true), asset("s2", "B")],
            currentLocalChecksums: checksums("B"),
            observedChecksums: checksums("A", "B")
        ))
        #expect(output.deleteCandidates.isEmpty)
        #expect(output.assetsInObserved == 1)
    }

    @Test("newly observed checksums reflect additions since last observed snapshot")
    func newlyObservedReflectsAdditions() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [],
            currentLocalChecksums: checksums("A", "B", "C"),
            observedChecksums: checksums("A")
        ))
        #expect(output.newlyObservedChecksums == checksums("B", "C"))
    }

    @Test("a server asset re-appearing locally (e.g. photo restored from iOS Recently Deleted) is not a delete candidate")
    func restoredLocalNotCandidate() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A")],
            currentLocalChecksums: checksums("A"),
            observedChecksums: checksums("A")
        ))
        #expect(output.deleteCandidates.isEmpty)
    }

    @Test("duplicate server entries for the same checksum are all flagged if the content is gone locally")
    func duplicateServerEntriesAllFlagged() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "A")],
            currentLocalChecksums: [],
            observedChecksums: checksums("A")
        ))
        #expect(Set(output.deleteCandidates.map(\.id)) == ["s1", "s2"])
    }

    @Test("excluded checksums are filtered out of candidates and reported in excludedCandidateCount")
    func exclusionFiltersOutCandidates() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B"), asset("s3", "C")],
            currentLocalChecksums: [],
            observedChecksums: checksums("A", "B", "C"),
            excludedChecksums: checksums("B")
        ))
        #expect(Set(output.deleteCandidates.map(\.id)) == ["s1", "s3"])
        #expect(output.excludedCandidateCount == 1)
    }

    @Test("exclusion has no effect on assets that wouldn't have been candidates anyway")
    func exclusionDoesNotInflateExcludedCount() {
        // X is excluded but not in observed, so it was never a candidate. Excluding
        // it should not bump excludedCandidateCount; that count is for would-be
        // deletions actually saved by the exclusion list.
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "X")],
            currentLocalChecksums: [],
            observedChecksums: checksums("A"),
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
            observedChecksums: checksums("A")
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
            observedChecksums: checksums("A", "B", "C"),
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
            observedChecksums: checksums("A", "B"),
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
            observedChecksums: checksums("A", "B"),
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
            observedChecksums: checksums("A", "B", "C"),
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
            observedChecksums: checksums("A")
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
            observedChecksums: checksums("A", "B"),
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
            observedChecksums: checksums("A"),
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
            observedChecksums: checksums("A", "B", "C"),
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
            observedChecksums: checksums("A", "B"),
            confirmedDeletedAt: [Checksum(base64: "A"): now, Checksum(base64: "B"): now],
            now: now,
            quarantineDays: 0,
            strictness: .strict
        ))
        #expect(Set(output.deleteCandidates.map(\.id)) == ["s1", "s2"])
        #expect(output.heldByQuarantineCandidates.isEmpty)
        #expect(output.pendingReviewCandidates.isEmpty)
    }

    // MARK: - Autonomous mode

    @Test("autonomous mode: every diff candidate flows straight to deleteCandidates regardless of confirmed-deleted state")
    func autonomousIgnoresConfirmedDeleted() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B"), asset("s3", "C")],
            currentLocalChecksums: [],
            observedChecksums: checksums("A", "B", "C"),
            // Mix of fresh-confirmed, past-confirmed, and unconfirmed.
            // Autonomous should ignore all distinctions.
            confirmedDeletedAt: [
                Checksum(base64: "A"): now,
                Checksum(base64: "C"): .distantPast,
            ],
            now: now,
            quarantineDays: 14,
            strictness: .autonomous
        ))
        #expect(Set(output.deleteCandidates.map(\.id)) == ["s1", "s2", "s3"])
        #expect(output.pendingReviewCandidates.isEmpty)
        #expect(output.heldByQuarantineCandidates.isEmpty)
    }

    @Test("autonomous mode: exclusions still protect candidates from deletion")
    func autonomousRespectsExclusions() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B")],
            currentLocalChecksums: [],
            observedChecksums: checksums("A", "B"),
            excludedChecksums: checksums("A"),
            strictness: .autonomous
        ))
        #expect(output.deleteCandidates.map(\.id) == ["s2"])
        #expect(output.excludedCandidateCount == 1)
    }

    @Test("autonomous mode: server assets never seen locally are still safe (Mac-only uploads not flagged)")
    func autonomousNeverObservedIsStillSafe() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "MAC_ONLY")],
            currentLocalChecksums: [],
            observedChecksums: checksums("A"),
            strictness: .autonomous
        ))
        // s2 was never on the iPhone, so it's not a candidate. Only s1.
        #expect(output.deleteCandidates.map(\.id) == ["s1"])
    }

    @Test("autonomous mode: trashed server assets are not flagged again")
    func autonomousSkipsAlreadyTrashed() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A", isTrashed: true), asset("s2", "B")],
            currentLocalChecksums: [],
            observedChecksums: checksums("A", "B"),
            strictness: .autonomous
        ))
        #expect(output.deleteCandidates.map(\.id) == ["s2"])
    }

    @Test("autonomous mode: assets currently on iPhone are not flagged")
    func autonomousSkipsCurrentLocal() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B")],
            currentLocalChecksums: checksums("A"),
            observedChecksums: checksums("A", "B"),
            strictness: .autonomous
        ))
        #expect(output.deleteCandidates.map(\.id) == ["s2"])
    }

    @Test("heldByQuarantineCandidates is always a proper subset of pendingReviewCandidates")
    func heldIsSubsetOfPending() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        // Mix: A fresh-confirmed (held), B unconfirmed (pending in strict), C past (eligible).
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B"), asset("s3", "C")],
            currentLocalChecksums: [],
            observedChecksums: checksums("A", "B", "C"),
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

    // MARK: - gatedForReview()

    @Test("gatedForReview promotes every deleteCandidate into pendingReviewCandidates")
    func gatedForReviewPromotesAll() {
        // A trusting-mode result: two diff-only candidates, no quarantine.
        // After gating, deleteCandidates is empty and pending holds both.
        let base = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B"), asset("s3", "MAC_ONLY")],
            currentLocalChecksums: [],
            observedChecksums: checksums("A", "B"),
            strictness: .trusting
        ))
        #expect(Set(base.deleteCandidates.map(\.id)) == ["s1", "s2"])
        #expect(base.pendingReviewCandidates.isEmpty)

        let gated = base.gatedForReview()
        #expect(gated.deleteCandidates.isEmpty)
        #expect(Set(gated.pendingReviewCandidates.map(\.id)) == ["s1", "s2"])
        // Other fields pass through unchanged — the gate only moves
        // candidates between two buckets, no other transformation.
        #expect(gated.assetsInObserved == base.assetsInObserved)
        #expect(gated.excludedCandidateCount == base.excludedCandidateCount)
        #expect(gated.heldByQuarantineCandidates.map(\.id) == base.heldByQuarantineCandidates.map(\.id))
    }

    @Test("gatedForReview merges existing pending entries with promoted candidates")
    func gatedForReviewMergesPending() {
        // Strict mode, mixed input: one past-quarantine eligible + one
        // unconfirmed already in pending. After gating, the eligible one
        // joins the unconfirmed in pending.
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let base = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B")],
            currentLocalChecksums: [],
            observedChecksums: checksums("A", "B"),
            confirmedDeletedAt: [Checksum(base64: "A"): .distantPast],
            now: now,
            quarantineDays: 14,
            strictness: .strict
        ))
        #expect(base.deleteCandidates.map(\.id) == ["s1"])
        #expect(base.pendingReviewCandidates.map(\.id) == ["s2"])

        let gated = base.gatedForReview()
        #expect(gated.deleteCandidates.isEmpty)
        #expect(Set(gated.pendingReviewCandidates.map(\.id)) == ["s1", "s2"])
    }

    @Test("gatedForReview is a no-op when deleteCandidates is empty")
    func gatedForReviewNoOpWhenEmpty() {
        // Already-empty candidates: gating returns the same shape.
        let base = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A")],
            currentLocalChecksums: checksums("A"),
            observedChecksums: checksums("A")
        ))
        #expect(base.deleteCandidates.isEmpty)

        let gated = base.gatedForReview()
        #expect(gated.deleteCandidates.isEmpty)
        #expect(gated.pendingReviewCandidates.isEmpty)
    }

    // MARK: - Scope-aware indexing (Wave 5)

    @Test("scope filter excludes Observed entries whose tags don't intersect the active scope")
    func scopeFilterExcludesOutOfScopeEntries() {
        // A and B are both in Observed and absent from current-local —
        // both would be candidates under full library mode. With scope
        // = {album-1} and only A tagged with album-1, only A surfaces.
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B")],
            currentLocalChecksums: [],
            observedChecksums: checksums("A", "B"),
            observedAlbumTags: [
                Checksum(base64: "A"): ["album-1"],
                Checksum(base64: "B"): ["album-2"],
            ],
            selectedAlbumScope: ["album-1"]
        ))
        #expect(output.deleteCandidates.map(\.id) == ["s1"])
    }

    @Test("scope filter: untagged (legacy) Observed entries are out of scope when restricted")
    func scopeFilterExcludesUntaggedEntries() {
        // Empty tags = "untagged / pre-scope-aware" — under any
        // restricted scope, exclude. The user must trigger
        // recordObserved to bring legacy entries into scope.
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B")],
            currentLocalChecksums: [],
            observedChecksums: checksums("A", "B"),
            observedAlbumTags: [
                Checksum(base64: "A"): ["album-1"],
                Checksum(base64: "B"): [],   // legacy / untagged
            ],
            selectedAlbumScope: ["album-1"]
        ))
        #expect(output.deleteCandidates.map(\.id) == ["s1"])
    }

    @Test("scope filter: tags-and-scope intersection means even one matching album is enough")
    func scopeFilterIntersectionAcceptsAnyOverlap() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A")],
            currentLocalChecksums: [],
            observedChecksums: checksums("A"),
            observedAlbumTags: [
                // Tagged in three albums; only one is in scope. Still in scope.
                Checksum(base64: "A"): ["album-1", "album-2", "album-3"],
            ],
            selectedAlbumScope: ["album-2"]
        ))
        #expect(output.deleteCandidates.map(\.id) == ["s1"])
    }

    @Test("scope filter: nil tags or nil scope = full library mode (no filter applied)")
    func scopeFilterNilFallsBackToFullLibrary() {
        // Same input as `scopeFilterExcludesOutOfScopeEntries` but with
        // nil scope. Both candidates survive — full library behavior.
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B")],
            currentLocalChecksums: [],
            observedChecksums: checksums("A", "B"),
            observedAlbumTags: [
                Checksum(base64: "A"): ["album-1"],
                Checksum(base64: "B"): ["album-2"],
            ],
            selectedAlbumScope: nil
        ))
        #expect(Set(output.deleteCandidates.map(\.id)) == ["s1", "s2"])
    }

    @Test("scope filter: assetsInObserved denominator reflects the scoped subset")
    func scopeFilterAdjustsAssetsInObservedCount() {
        // With 3 server assets all in Observed but only one tagged in
        // scope, the denominator drops to 1 — safety rails are evaluated
        // against the scope-restricted universe, not the full library.
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B"), asset("s3", "C")],
            currentLocalChecksums: checksums("A", "B", "C"),
            observedChecksums: checksums("A", "B", "C"),
            observedAlbumTags: [
                Checksum(base64: "A"): ["album-1"],
                Checksum(base64: "B"): ["album-2"],
                Checksum(base64: "C"): [],
            ],
            selectedAlbumScope: ["album-1"]
        ))
        #expect(output.assetsInObserved == 1)
    }

    @Test("scope filter: empty scope means no candidates regardless of tags")
    func scopeFilterEmptyScopeProducesZeroCandidates() {
        // The "user toggled to selected albums but hasn't picked any
        // yet" degraded state. Engine emits zero candidates — no
        // accidental mass-delete during the picking window.
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B")],
            currentLocalChecksums: [],
            observedChecksums: checksums("A", "B"),
            observedAlbumTags: [
                Checksum(base64: "A"): ["album-1"],
                Checksum(base64: "B"): ["album-2"],
            ],
            selectedAlbumScope: []
        ))
        #expect(output.deleteCandidates.isEmpty)
    }

    // MARK: - Recycled exclusions

    @Test("recycled exclusion: excluded checksum with later confirmedDeletedAt routes to recycledExclusionCandidates")
    func recycledExclusionRoutesToBucket() {
        // User excluded "B" at T=10; later (T=20) PhotoKit confirmed
        // "B" was deleted again. The user's original "preserve on
        // Immich" intent has been contradicted by the new explicit
        // delete; surface for review rather than silently keeping.
        let excludedAt: [Checksum: Date] = [
            Checksum(base64: "B"): Date(timeIntervalSince1970: 10),
        ]
        let confirmedAt: [Checksum: Date] = [
            Checksum(base64: "B"): Date(timeIntervalSince1970: 20),
        ]
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B")],
            currentLocalChecksums: [],
            observedChecksums: checksums("A", "B"),
            excludedChecksums: checksums("B"),
            confirmedDeletedAt: confirmedAt,
            now: Date(timeIntervalSince1970: 1_000_000),
            quarantineDays: 0,
            excludedAtByChecksum: excludedAt
        ))
        #expect(output.recycledExclusionCandidates.map(\.id) == ["s2"])
        #expect(output.deleteCandidates.map(\.id) == ["s1"])
        // Recycled aren't double-counted in the excluded count —
        // they're being surfaced, not silently filtered.
        #expect(output.excludedCandidateCount == 0)
    }

    @Test("recycled exclusion: confirmed-delete predates exclusion → stays excluded, not recycled")
    func notRecycledIfConfirmedBeforeExcluded() {
        // User deleted "B", saw it as a confirmed-delete signal at T=10,
        // restored via cairn (which inserts the exclusion at T=20).
        // The exclusion is newer than the confirm — original intent
        // intact, no cycle to surface.
        let excludedAt: [Checksum: Date] = [
            Checksum(base64: "B"): Date(timeIntervalSince1970: 20),
        ]
        let confirmedAt: [Checksum: Date] = [
            Checksum(base64: "B"): Date(timeIntervalSince1970: 10),
        ]
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s2", "B")],
            currentLocalChecksums: [],
            observedChecksums: checksums("B"),
            excludedChecksums: checksums("B"),
            confirmedDeletedAt: confirmedAt,
            now: Date(timeIntervalSince1970: 1_000_000),
            quarantineDays: 0,
            excludedAtByChecksum: excludedAt
        ))
        #expect(output.recycledExclusionCandidates.isEmpty)
        #expect(output.deleteCandidates.isEmpty)
        #expect(output.excludedCandidateCount == 1)
    }

    @Test("recycled exclusion: nil excludedAtByChecksum disables detection (legacy callers preserved)")
    func nilExcludedAtDisablesRecycling() {
        let confirmedAt: [Checksum: Date] = [
            Checksum(base64: "B"): Date(timeIntervalSince1970: 20),
        ]
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s2", "B")],
            currentLocalChecksums: [],
            observedChecksums: checksums("B"),
            excludedChecksums: checksums("B"),
            confirmedDeletedAt: confirmedAt,
            now: Date(timeIntervalSince1970: 1_000_000),
            quarantineDays: 0,
            excludedAtByChecksum: nil
        ))
        #expect(output.recycledExclusionCandidates.isEmpty)
        #expect(output.excludedCandidateCount == 1)
    }

    @Test("recycled exclusion: missing confirmedDeletedAt entry → not recycled (never re-deleted)")
    func notRecycledWithoutConfirmDelete() {
        let excludedAt: [Checksum: Date] = [
            Checksum(base64: "B"): Date(timeIntervalSince1970: 10),
        ]
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s2", "B")],
            currentLocalChecksums: [],
            observedChecksums: checksums("B"),
            excludedChecksums: checksums("B"),
            confirmedDeletedAt: [:],
            now: Date(timeIntervalSince1970: 1_000_000),
            quarantineDays: 0,
            excludedAtByChecksum: excludedAt
        ))
        #expect(output.recycledExclusionCandidates.isEmpty)
        #expect(output.excludedCandidateCount == 1)
    }

    // MARK: - Limited Photos + scope-restricted deletion (user-reported scenario)

    @Test("limited-scope demo: 25-asset album, 5 freshly confirmed → all 5 in held + pending under .strict")
    func limitedScopeFiveDeletesAllHeld() {
        // Reproduces the user-reported flow exactly: cairn restricted
        // to a single album of 25 photos, iOS Photos auth = .limited
        // (which forces .strict in performLiveReconciliation), 5 photos
        // deleted in Photos.app, change-log fired and the iOS-side
        // reconciler stamped 5 checksums into ConfirmedDeletedStore at
        // `now`. Engine input mirrors that post-stamp state.
        //
        // Expected: all 5 land in heldByQuarantineCandidates (and in
        // pendingReviewCandidates as a superset). deleteCandidates is
        // empty because nothing has aged past the quarantine window.
        // If this test ever fails, the engine has regressed; if it
        // passes while the device shows "everything in unconfirmed,"
        // the bug is in the iOS-side stamping path (look at the
        // `[cairn.recon] stamp gate:` log line).
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let albumId = "album-1"
        let scope: Set<String> = [albumId]

        // 25 server assets, all in observed with album-1 tags.
        var server: [ServerAsset] = []
        var ever: Set<Checksum> = []
        var tags: [Checksum: Set<String>] = [:]
        for i in 0..<25 {
            let ck = Checksum(base64: "asset-\(i)")
            server.append(ServerAsset(id: "s\(i)", checksum: ck, livePhotoVideoId: nil, isTrashed: false))
            ever.insert(ck)
            tags[ck] = [albumId]
        }

        // 20 still local (the 5 deleted are gone).
        let currentLocal = Set(server.prefix(20).map(\.checksum))
        // 5 freshly stamped confirmed deletions.
        var confirmedAt: [Checksum: Date] = [:]
        for asset in server.suffix(5) {
            confirmedAt[asset.checksum] = now
        }

        let output = ReconciliationEngine.compute(.init(
            serverAssets: server,
            currentLocalChecksums: currentLocal,
            observedChecksums: ever,
            excludedChecksums: [],
            confirmedDeletedAt: confirmedAt,
            now: now,
            quarantineDays: 14,
            strictness: .strict,
            observedAlbumTags: tags,
            selectedAlbumScope: scope
        ))

        #expect(output.deleteCandidates.isEmpty,
                "Fresh confirmations should be held by quarantine, not eligible to trash.")
        #expect(output.heldByQuarantineCandidates.count == 5,
                "All 5 deletions are within the 14-day window → held.")
        #expect(output.pendingReviewCandidates.count == 5,
                "Under .strict, held items also surface in pending review.")
        // Sanity: the 5 held items are exactly the deleted suffix.
        let expected = Set(server.suffix(5).map(\.id))
        #expect(Set(output.heldByQuarantineCandidates.map(\.id)) == expected)
    }

    @Test("limited-scope demo: 5 missing-from-local but unconfirmed → all 5 in pending only (no held), strict")
    func limitedScopeUnconfirmedAllPending() {
        // Failure-mode mirror of the test above: 5 are missing locally
        // (diff sees them as candidates) but ConfirmedDeletedStore is
        // empty — the iOS reconciler failed to stamp (assetsd hiccup,
        // events lost, requireExplicitDeletionEvent gating an orphan
        // sweep find under .limited, etc). Under .strict, every diff
        // candidate without a positive signal lands in pending review.
        // This is what the user actually saw: 0 held, 5 in pending.
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let albumId = "album-1"

        var server: [ServerAsset] = []
        var ever: Set<Checksum> = []
        var tags: [Checksum: Set<String>] = [:]
        for i in 0..<25 {
            let ck = Checksum(base64: "asset-\(i)")
            server.append(ServerAsset(id: "s\(i)", checksum: ck, livePhotoVideoId: nil, isTrashed: false))
            ever.insert(ck)
            tags[ck] = [albumId]
        }
        let currentLocal = Set(server.prefix(20).map(\.checksum))

        let output = ReconciliationEngine.compute(.init(
            serverAssets: server,
            currentLocalChecksums: currentLocal,
            observedChecksums: ever,
            excludedChecksums: [],
            confirmedDeletedAt: [:],   // nothing stamped — the regression case
            now: now,
            quarantineDays: 14,
            strictness: .strict,
            observedAlbumTags: tags,
            selectedAlbumScope: [albumId]
        ))

        #expect(output.deleteCandidates.isEmpty)
        #expect(output.heldByQuarantineCandidates.isEmpty)
        #expect(output.pendingReviewCandidates.count == 5,
                "Without ConfirmedDeleted stamps, .strict routes the 5 diff candidates to pending only.")
    }

    @Test("recycled exclusion: partial — some excluded re-deleted, others not")
    func recycledPartial() {
        // B is recycled (excluded then re-deleted); C stays excluded
        // (confirm predates the exclusion); D is a normal candidate.
        let excludedAt: [Checksum: Date] = [
            Checksum(base64: "B"): Date(timeIntervalSince1970: 10),
            Checksum(base64: "C"): Date(timeIntervalSince1970: 50),
        ]
        let confirmedAt: [Checksum: Date] = [
            Checksum(base64: "B"): Date(timeIntervalSince1970: 20),
            Checksum(base64: "C"): Date(timeIntervalSince1970: 30),
        ]
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("sB", "B"), asset("sC", "C"), asset("sD", "D")],
            currentLocalChecksums: [],
            observedChecksums: checksums("B", "C", "D"),
            excludedChecksums: checksums("B", "C"),
            confirmedDeletedAt: confirmedAt,
            now: Date(timeIntervalSince1970: 1_000_000),
            quarantineDays: 0,
            excludedAtByChecksum: excludedAt
        ))
        #expect(output.recycledExclusionCandidates.map(\.id) == ["sB"])
        #expect(output.deleteCandidates.map(\.id) == ["sD"])
        #expect(output.excludedCandidateCount == 1) // C stays filtered
    }

    // MARK: - Limbo recovery

    @Test("limbo: SHA1 in observed-not-local-not-confirmed-not-excluded is flagged")
    func limboBasicFlag() {
        let limbo = ReconciliationEngine.limboChecksums(
            observed: Set([Checksum(base64: "A"), Checksum(base64: "B")]),
            currentLocal: Set([Checksum(base64: "A")]),
            confirmedDeleted: [],
            excluded: []
        )
        #expect(limbo == Set([Checksum(base64: "B")]))
    }

    @Test("limbo: SHA1 already in confirmedDeleted is NOT flagged")
    func limboExcludesAlreadyConfirmed() {
        let limbo = ReconciliationEngine.limboChecksums(
            observed: Set([Checksum(base64: "A"), Checksum(base64: "B")]),
            currentLocal: [],
            confirmedDeleted: Set([Checksum(base64: "A")]),
            excluded: []
        )
        // A is already confirmed-deleted; only B is in limbo.
        #expect(limbo == Set([Checksum(base64: "B")]))
    }

    @Test("limbo: excluded checksums are NOT retroactively stamped")
    func limboExcludesExcluded() {
        // Important: a user who has excluded a SHA1 has explicitly said
        // "don't touch this on Immich." Flagging it as limbo would
        // start a quarantine clock that, after 14 days, eventually
        // promotes it to ready-to-trash. The exclude must win.
        let limbo = ReconciliationEngine.limboChecksums(
            observed: Set([Checksum(base64: "A"), Checksum(base64: "B")]),
            currentLocal: [],
            confirmedDeleted: [],
            excluded: Set([Checksum(base64: "A")])
        )
        #expect(limbo == Set([Checksum(base64: "B")]))
    }

    @Test("limbo: SHA1 still in current local is NOT flagged (asset alive)")
    func limboExcludesAlive() {
        let limbo = ReconciliationEngine.limboChecksums(
            observed: Set([Checksum(base64: "A"), Checksum(base64: "B")]),
            currentLocal: Set([Checksum(base64: "A"), Checksum(base64: "B")]),
            confirmedDeleted: [],
            excluded: []
        )
        // Both assets are alive locally — nothing in limbo, even
        // though they're observed.
        #expect(limbo.isEmpty)
    }

    @Test("limbo: empty observed → empty limbo (no false positives from empty store)")
    func limboEmptyObserved() {
        let limbo = ReconciliationEngine.limboChecksums(
            observed: [],
            currentLocal: Set([Checksum(base64: "A")]),
            confirmedDeleted: [],
            excluded: []
        )
        #expect(limbo.isEmpty)
    }

    @Test("limbo: representative real-world case — 6 deleted, 4 stamped, 2 limbo")
    func limboReproducesUserBug() {
        // Mirrors the field report: a user takes 6 photos, deletes all
        // 6, but the original sync only stamps 4 to ConfirmedDeleted
        // (whether via partial mid-loop failure or a re-hash race).
        // The other 2 sit in Observed without a quarantine clock.
        let allSix = (1...6).map { Checksum(base64: "ck-\($0)") }
        let stamped = Set(allSix.prefix(4)) // sha1s 1..4
        let limbo = ReconciliationEngine.limboChecksums(
            observed: Set(allSix),
            currentLocal: [],
            confirmedDeleted: stamped,
            excluded: []
        )
        // Sha1s 5 and 6 are the missing 2 — they're the limbo set.
        #expect(limbo == Set(allSix.suffix(2)))
    }
}
