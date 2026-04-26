import Testing
import Foundation
import CairnCore
@testable import CairnIOSCore

#if canImport(Photos)

/// Unit tests for `PhotoKitPersistentChangeReconciler`'s pure helpers.
///
/// The full `runIncremental` path needs a live `PHPhotoLibrary` and
/// real `PHPersistentChangeToken`s, which `swift test` can't supply on
/// macOS. The semantically load-bearing piece of the duplicate-SHA1
/// fix — "filter the raw removed-checksum set against the post-purge
/// cache before stamping `ConfirmedDeletedStore`" — is factored into
/// `confirmableDeletions(removed:stillLocal:)` so we can exercise it
/// directly. End-to-end coverage of the enclosing pipeline lives in
/// the manual test plan in `PhotoKitPhotoEnumeratorTests`.
@Suite("PhotoKitPersistentChangeReconciler")
struct PhotoKitPersistentChangeReconcilerTests {

    private static let shaA = Checksum(base64: "AAAA")
    private static let shaB = Checksum(base64: "BBBB")
    private static let shaC = Checksum(base64: "CCCC")

    @Test("duplicate SHA1 still cached under another id is filtered out")
    func filtersDuplicateChecksum() {
        // id1 and id2 both held shaA; id1 was deleted. After purging
        // id1's cache row, shaA is still locally present via id2.
        let removed: Set<Checksum> = [Self.shaA]
        let stillLocal: Set<Checksum> = [Self.shaA]
        let trulyAbsent = PhotoKitPersistentChangeReconciler.confirmableDeletions(
            removed: removed,
            stillLocal: stillLocal
        )
        #expect(trulyAbsent.isEmpty)
    }

    @Test("checksum absent from cache flows through unchanged")
    func passesThroughWhenAbsent() {
        // id1 held shaA; deletion purged its cache row; no other id
        // holds shaA, so it's truly absent and must be confirmed.
        let removed: Set<Checksum> = [Self.shaA]
        let stillLocal: Set<Checksum> = []
        let trulyAbsent = PhotoKitPersistentChangeReconciler.confirmableDeletions(
            removed: removed,
            stillLocal: stillLocal
        )
        #expect(trulyAbsent == [Self.shaA])
    }

    @Test("partial overlap keeps only the absent subset")
    func partialOverlap() {
        // shaA was held by both id1 (deleted) and id3 (still present);
        // shaB was held only by id2 (deleted). Only shaB is truly gone.
        let removed: Set<Checksum> = [Self.shaA, Self.shaB]
        let stillLocal: Set<Checksum> = [Self.shaA, Self.shaC]
        let trulyAbsent = PhotoKitPersistentChangeReconciler.confirmableDeletions(
            removed: removed,
            stillLocal: stillLocal
        )
        #expect(trulyAbsent == [Self.shaB])
    }

    @Test("unarchiveToken returns nil on empty data — drives .tokenExpired path")
    @MainActor
    func unarchiveEmptyData() {
        // The runDeletionScan flow treats nil-from-unarchive identically
        // to a real PHPhotosError.persistentChangeTokenExpired: clear the
        // saved token, run full enumeration with cause = .tokenExpired.
        // The cause is what gates the iOS-side review promotion, so we
        // pin the precondition here even though we can't drive the full
        // PhotoKit pipeline from a unit test.
        let token = PhotoKitPersistentChangeReconciler.unarchiveToken(Data())
        #expect(token == nil)
    }

    @Test("unarchiveToken returns nil on random bytes — drives .tokenExpired path")
    @MainActor
    func unarchiveGarbageBytes() {
        // Mirrors the OS-upgrade-changed-archive-format scenario: legacy
        // bytes that no longer decode as a PHPersistentChangeToken.
        let garbage = Data([0xFF, 0xFE, 0x00, 0x01, 0x42, 0x42])
        let token = PhotoKitPersistentChangeReconciler.unarchiveToken(garbage)
        #expect(token == nil)
    }

    @Test("FullEnumerationCause is Equatable and distinguishes both cases")
    func fullEnumerationCauseEquatable() {
        // The iOS-side gate is a == comparison against .tokenExpired —
        // pin the case shape so a future rename surfaces here loudly.
        let firstRun = PhotoKitPersistentChangeReconciler.FullEnumerationCause.firstRun
        let expired = PhotoKitPersistentChangeReconciler.FullEnumerationCause.tokenExpired
        #expect(firstRun != expired)
        #expect(firstRun == .firstRun)
        #expect(expired == .tokenExpired)
    }

    @Test("partitionRetiredByFirstObserved: protected = retired ∩ firstObserved")
    func partitionProtectsOriginal() {
        // Edit-then-revert round-trip: retired = {SHA1_E1} (the post-
        // edit SHA1 the revert displaced); firstObserved = {SHA1_O}
        // (still the original anchor). Intersection is empty, so the
        // entire retired set is intermediate and goes to quarantine.
        // Pin the rule so a future refactor doesn't accidentally
        // protect intermediate edits.
        let parts = PhotoKitPersistentChangeReconciler.partitionRetiredByFirstObserved(
            retired: [Self.shaB],
            firstObserved: [Self.shaA]
        )
        #expect(parts.protected.isEmpty)
        #expect(parts.intermediate == [Self.shaB])
    }

    @Test("partitionRetiredByFirstObserved: edit-of-original protects firstObserved SHA1")
    func partitionEditOfOriginalProtects() {
        // First edit: retired = {SHA1_O} (original displaced by edit);
        // firstObserved = {SHA1_O} (the anchor). The retired SHA1 IS
        // the anchor, so protect it — no quarantine. This is the load-
        // bearing rule of the whole feature: original-content SHA1 is
        // sacred while the id is alive.
        let parts = PhotoKitPersistentChangeReconciler.partitionRetiredByFirstObserved(
            retired: [Self.shaA],
            firstObserved: [Self.shaA]
        )
        #expect(parts.protected == [Self.shaA])
        #expect(parts.intermediate.isEmpty)
    }

    @Test("partitionRetiredByFirstObserved: mixed retired set splits cleanly")
    func partitionMixedSet() {
        // shaA is the anchor (protect); shaB is an intermediate edit
        // (quarantine). Both retired in the same pass — partition
        // must route them to opposite buckets.
        let parts = PhotoKitPersistentChangeReconciler.partitionRetiredByFirstObserved(
            retired: [Self.shaA, Self.shaB],
            firstObserved: [Self.shaA]
        )
        #expect(parts.protected == [Self.shaA])
        #expect(parts.intermediate == [Self.shaB])
    }

    @Test("partitionRetiredByFirstObserved: empty retired set yields empty buckets")
    func partitionEmptyRetired() {
        let parts = PhotoKitPersistentChangeReconciler.partitionRetiredByFirstObserved(
            retired: [],
            firstObserved: [Self.shaA, Self.shaB]
        )
        #expect(parts.protected.isEmpty)
        #expect(parts.intermediate.isEmpty)
    }

    @Test("partitionRetiredByFirstObserved: missing anchor → everything intermediate")
    func partitionMissingAnchor() {
        // Edge case: an id was observed before the EditRetirementStore
        // existed (legacy install) and never got an anchor. Without
        // firstObserved there's nothing to protect — all retired SHA1s
        // are intermediate. This is the safe fallback: any retired SHA1
        // we can't prove is the anchor flows through quarantine, where
        // the user still gets review time.
        let parts = PhotoKitPersistentChangeReconciler.partitionRetiredByFirstObserved(
            retired: [Self.shaA, Self.shaB],
            firstObserved: []
        )
        #expect(parts.protected.isEmpty)
        #expect(parts.intermediate == [Self.shaA, Self.shaB])
    }

    @Test("untrackedFromLibrary: empty inputs yield empty result")
    func untrackedEmptyInputs() {
        // No library, no cache, no queue — the gap is trivially zero.
        // Pin the no-op shape so the foreground sync stays cheap when
        // there's nothing to discover.
        let untracked = PhotoKitPersistentChangeReconciler.untrackedFromLibrary(
            liveIds: [],
            cacheIds: [],
            deferredIds: []
        )
        #expect(untracked.isEmpty)
    }

    @Test("untrackedFromLibrary: library ⊆ cache yields empty result")
    func untrackedFullyCovered() {
        // Steady state on a closed gap: every visible PHAsset already
        // hashed. The sweep must return empty so the existing pipeline
        // sees zero synthetic inserts.
        let untracked = PhotoKitPersistentChangeReconciler.untrackedFromLibrary(
            liveIds: ["id1", "id2"],
            cacheIds: ["id1", "id2", "id3"],
            deferredIds: []
        )
        #expect(untracked.isEmpty)
    }

    @Test("untrackedFromLibrary: live id absent from both stores → discovered")
    func untrackedDiscovered() {
        // The empirical case: a PHAsset visible in PhotoKit but missing
        // from both stores (never hashed, never queued). The sweep must
        // surface it so the caller can fold it into the insert pipeline.
        let untracked = PhotoKitPersistentChangeReconciler.untrackedFromLibrary(
            liveIds: ["id1", "id2"],
            cacheIds: ["id1"],
            deferredIds: []
        )
        #expect(untracked == ["id2"])
    }

    @Test("untrackedFromLibrary: deferred id is NOT untracked")
    func untrackedAlreadyDeferred() {
        // An id that's already queued for a later re-hash (above the
        // soft limit, awaiting BG slot) is being tracked — the sweep
        // must not double-route it through the insert pipeline. Models
        // the user's "215 above-cap-deferred" bucket.
        let untracked = PhotoKitPersistentChangeReconciler.untrackedFromLibrary(
            liveIds: ["id1", "id2"],
            cacheIds: ["id1"],
            deferredIds: ["id2"]
        )
        #expect(untracked.isEmpty)
    }

    @Test("untrackedFromLibrary: cached id is NOT untracked")
    func untrackedAlreadyCached() {
        // The "indexed" bucket: cache lookup wins over the sweep so we
        // don't waste a re-hash on a steady-state asset.
        let untracked = PhotoKitPersistentChangeReconciler.untrackedFromLibrary(
            liveIds: ["id1"],
            cacheIds: ["id1"],
            deferredIds: []
        )
        #expect(untracked.isEmpty)
    }

    @Test("first-write-wins quarantine timestamp survives flap")
    func flappingPreservesOriginalTimestamp() async throws {
        // Models the integration semantic: the reconciler's filter
        // produces the input to ConfirmedDeletedStore.union, and union
        // is first-write-wins on the timestamp. A SHA1 deleted at t0,
        // restored, then deleted again at t1 must keep t0 — protects
        // flapping libraries from quarantine-clock resets.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cairn-recon-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = JSONFileConfirmedDeletedStore(path: dir.appendingPathComponent("cd.json"))
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let t1 = Date(timeIntervalSince1970: 1_500_000)

        // First deletion: shaA truly absent, gets stamped at t0.
        let firstAbsent = PhotoKitPersistentChangeReconciler.confirmableDeletions(
            removed: [Self.shaA],
            stillLocal: []
        )
        try await store.union(firstAbsent, at: t0)

        // Restoration removes the entry — fresh clock allowed.
        try await store.remove([Self.shaA])
        var snap = try await store.snapshot()
        #expect(snap[Self.shaA] == nil)

        // Re-confirm: stamps at t1 (post-removal, so this is the new clock).
        try await store.union([Self.shaA], at: t1)
        snap = try await store.snapshot()
        #expect(snap[Self.shaA] == t1)

        // Without an intervening remove, a re-union at t1 is a no-op
        // on the timestamp — first-write-wins.
        try await store.union([Self.shaA], at: Date(timeIntervalSince1970: 2_000_000))
        snap = try await store.snapshot()
        #expect(snap[Self.shaA] == t1)
    }

    @Test("DeferReason exposes all four expected cases with stable raw values")
    func deferReasonCasesAreStable() {
        // Pin the rawValue strings — SwiftData stores rows by rawValue
        // (`StoredDeferredHash.reasonRaw`), so renaming any of these
        // would silently break decode of existing rows on upgrade.
        // Adding cases is fine; bump the test when the list grows.
        let all: [DeferredHashEntry.DeferReason] = [
            .tooLarge,
            .timedOut,
            .noHashableResources,
            .aboveHardCeiling,
        ]
        let raws = Set(all.map(\.rawValue))
        #expect(raws == ["tooLarge", "timedOut", "noHashableResources", "aboveHardCeiling"])
        // Round-trip every case through its rawValue to catch typos.
        for reason in all {
            #expect(DeferredHashEntry.DeferReason(rawValue: reason.rawValue) == reason)
        }
    }
}

#endif
