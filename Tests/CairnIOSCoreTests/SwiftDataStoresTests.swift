import Foundation
import Testing
import SwiftData
import CairnCore
@testable import CairnIOSCore

// Each test builds its own in-memory `ModelContainer`. SwiftData's default
// on-disk store would either share state across tests (flaky) or require
// per-test temp paths and cleanup; in-memory containers sidestep both
// problems and let the suite run in parallel safely.

private func makeContainer() throws -> ModelContainer {
    try CairnSwiftDataContainer.make(inMemory: true)
}

private func ck(_ value: String) -> Checksum {
    Checksum(base64: value)
}

private func cks(_ values: String...) -> Set<Checksum> {
    Set(values.map { Checksum(base64: $0) })
}

private func meta(
    _ addedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    runId: String? = nil,
    reason: String? = nil
) -> ExclusionMetadata {
    ExclusionMetadata(addedAt: addedAt, fromRunId: runId, reason: reason)
}

// MARK: - SwiftDataObservedStore

@Suite("SwiftDataObservedStore")
struct SwiftDataObservedStoreTests {

    @Test("empty container snapshot returns empty set")
    func emptyIsEmpty() async throws {
        let container = try makeContainer()
        let store = SwiftDataObservedStore(container: container)
        #expect(try await store.snapshot().isEmpty)
    }

    @Test("union + snapshot roundtrips")
    func unionRoundtrips() async throws {
        let container = try makeContainer()
        let store = SwiftDataObservedStore(container: container)

        try await store.union(cks("A", "B"))
        try await store.union(cks("C"))

        #expect(try await store.snapshot() == cks("A", "B", "C"))
    }

    @Test("union with overlapping checksums is idempotent — no duplicates, no errors")
    func overlapIdempotent() async throws {
        let container = try makeContainer()
        let store = SwiftDataObservedStore(container: container)

        try await store.union(cks("A", "B"))
        try await store.union(cks("B", "C"))
        try await store.union(cks("A", "B", "C"))

        #expect(try await store.snapshot() == cks("A", "B", "C"))
    }

    @Test("two stores sharing one container see each other's writes")
    func sharedContainerCrossVisibility() async throws {
        let container = try makeContainer()
        let writer = SwiftDataObservedStore(container: container)
        let reader = SwiftDataObservedStore(container: container)

        try await writer.union(cks("X", "Y", "Z"))

        #expect(try await reader.snapshot() == cks("X", "Y", "Z"))
    }

    @Test("empty union is a no-op")
    func emptyUnionNoop() async throws {
        let container = try makeContainer()
        let store = SwiftDataObservedStore(container: container)

        try await store.union([])
        #expect(try await store.snapshot().isEmpty)
    }

    // MARK: - Scope-aware tag API

    @Test("recordObserved persists album tags retrievable via snapshotWithTags")
    func recordObservedPersistsTags() async throws {
        let container = try makeContainer()
        let store = SwiftDataObservedStore(container: container)

        try await store.recordObserved([
            ck("A"): ["album-1", "album-2"],
            ck("B"): ["album-1"],
        ])
        let snap = try await store.snapshotWithTags()
        #expect(snap[ck("A")] == ["album-1", "album-2"])
        #expect(snap[ck("B")] == ["album-1"])
    }

    @Test("recordObserved replaces tags on re-observation — accommodates album moves")
    func recordObservedReplaces() async throws {
        let container = try makeContainer()
        let store = SwiftDataObservedStore(container: container)

        try await store.recordObserved([ck("A"): ["album-1"]])
        try await store.recordObserved([ck("A"): ["album-2"]])
        let snap = try await store.snapshotWithTags()
        #expect(snap[ck("A")] == ["album-2"])
    }

    @Test("setTags bulk-replaces tags only on existing entries; missing checksums skip")
    func setTagsBulkSafe() async throws {
        let container = try makeContainer()
        let store = SwiftDataObservedStore(container: container)

        try await store.recordObserved([
            ck("A"): ["old"],
            ck("B"): ["old"],
        ])
        try await store.setTags(for: cks("A", "B", "MISSING"), tags: ["fresh"])
        let snap = try await store.snapshotWithTags()
        #expect(snap[ck("A")] == ["fresh"])
        #expect(snap[ck("B")] == ["fresh"])
        #expect(snap[ck("MISSING")] == nil)
    }

    @Test("legacy union() preserves tags on existing entries; new entries get empty tags")
    func unionPreservesTags() async throws {
        let container = try makeContainer()
        let store = SwiftDataObservedStore(container: container)

        try await store.recordObserved([ck("A"): ["album-1"]])
        try await store.union(cks("A", "B"))
        let snap = try await store.snapshotWithTags()
        #expect(snap[ck("A")] == ["album-1"])    // preserved
        #expect(snap[ck("B")] == [])              // new = empty
    }

    @Test("CSV codec round-trips: empty, one, many tags")
    func csvCodecRoundTrips() {
        #expect(SwiftDataObservedStore.parseAlbumCSV("") == [])
        #expect(SwiftDataObservedStore.parseAlbumCSV("A") == ["A"])
        #expect(SwiftDataObservedStore.parseAlbumCSV("A,B,C") == ["A", "B", "C"])
        #expect(SwiftDataObservedStore.formatAlbumCSV([]) == "")
        #expect(SwiftDataObservedStore.formatAlbumCSV(["B", "A", "C"]) == "A,B,C")  // sorted
    }
}

// MARK: - SwiftDataExclusionStore

@Suite("SwiftDataExclusionStore")
struct SwiftDataExclusionStoreTests {

    @Test("empty snapshot is empty dict")
    func emptyIsEmpty() async throws {
        let container = try makeContainer()
        let store = SwiftDataExclusionStore(container: container)
        #expect(try await store.snapshot().isEmpty)
    }

    @Test("insert + snapshot preserves all metadata fields")
    func insertSnapshotRoundtrip() async throws {
        let container = try makeContainer()
        let store = SwiftDataExclusionStore(container: container)

        let a = meta(Date(timeIntervalSince1970: 1_700_000_000), runId: "run-A", reason: "wedding photo")
        let b = meta(Date(timeIntervalSince1970: 1_700_000_100), runId: nil, reason: nil)
        let c = meta(Date(timeIntervalSince1970: 1_700_000_200), runId: "run-C", reason: nil)

        try await store.insert([
            ck("AAA"): a,
            ck("BBB"): b,
            ck("CCC"): c,
        ])

        let snap = try await store.snapshot()
        #expect(snap.count == 3)
        #expect(snap[ck("AAA")] == a)
        #expect(snap[ck("BBB")] == b)
        #expect(snap[ck("CCC")] == c)
    }

    @Test("isExcluded returns true for inserted checksums, false for others")
    func isExcludedTrueFalse() async throws {
        let container = try makeContainer()
        let store = SwiftDataExclusionStore(container: container)

        try await store.insert([ck("AAA"): meta()])

        #expect(try await store.isExcluded(ck("AAA")) == true)
        #expect(try await store.isExcluded(ck("BBB")) == false)
    }

    @Test("remove is a no-op for absent checksums")
    func removeMissingIsNoop() async throws {
        let container = try makeContainer()
        let store = SwiftDataExclusionStore(container: container)

        try await store.insert([ck("AAA"): meta()])
        try await store.remove([ck("ZZZ"), ck("YYY")])

        let snap = try await store.snapshot()
        #expect(snap.count == 1)
        #expect(snap[ck("AAA")] != nil)
    }

    @Test("remove drops present checksums and ignores absent ones in the same call")
    func removeMixedAbsentAndPresent() async throws {
        let container = try makeContainer()
        let store = SwiftDataExclusionStore(container: container)

        try await store.insert([
            ck("AAA"): meta(),
            ck("BBB"): meta(),
            ck("CCC"): meta(),
        ])
        try await store.remove([ck("AAA"), ck("CCC"), ck("NOT-THERE")])

        let snap = try await store.snapshot()
        #expect(snap.count == 1)
        #expect(snap[ck("BBB")] != nil)
    }

    @Test("re-insert of an existing checksum updates metadata (last-writer-wins)")
    func reinsertUpdatesMetadata() async throws {
        let container = try makeContainer()
        let store = SwiftDataExclusionStore(container: container)

        let old = meta(Date(timeIntervalSince1970: 1_000_000_000), runId: "old-run", reason: "old reason")
        let new = meta(Date(timeIntervalSince1970: 2_000_000_000), runId: "new-run", reason: "new reason")

        try await store.insert([ck("AAA"): old])
        try await store.insert([ck("AAA"): new])

        let snap = try await store.snapshot()
        #expect(snap.count == 1)
        #expect(snap[ck("AAA")] == new)
    }

    @Test("two stores sharing one container see each other's writes")
    func sharedContainerCrossVisibility() async throws {
        let container = try makeContainer()
        let writer = SwiftDataExclusionStore(container: container)
        let reader = SwiftDataExclusionStore(container: container)

        let m = meta(Date(timeIntervalSince1970: 1_700_000_777), runId: "run-shared", reason: "across actors")
        try await writer.insert([ck("X"): m])

        #expect(try await reader.isExcluded(ck("X")) == true)
        #expect(try await reader.snapshot()[ck("X")] == m)
    }
}

// MARK: - SwiftDataConfirmedDeletedStore

@Suite("SwiftDataConfirmedDeletedStore")
struct SwiftDataConfirmedDeletedStoreTests {
    @Test("empty container snapshot is empty")
    func emptySnapshot() async throws {
        let container = try makeContainer()
        let store = SwiftDataConfirmedDeletedStore(container: container)
        #expect(try await store.snapshot().isEmpty)
    }

    @Test("union + snapshot roundtrip carries per-entry timestamps")
    func unionRoundTrip() async throws {
        let container = try makeContainer()
        let store = SwiftDataConfirmedDeletedStore(container: container)
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.union(cks("A", "B"), at: t1)
        try await store.union(cks("B", "C"), at: t2)

        let snap = try await store.snapshot()
        #expect(Set(snap.keys) == cks("A", "B", "C"))
        #expect(snap[ck("A")] == t1)
        // B was first written at t1; first-write-wins means the later union
        // does not reset its clock.
        #expect(snap[ck("B")] == t1)
        #expect(snap[ck("C")] == t2)
    }

    @Test("union with overlapping checksums is idempotent — first-write-wins on timestamp")
    func unionIsIdempotent() async throws {
        let container = try makeContainer()
        let store = SwiftDataConfirmedDeletedStore(container: container)
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.union(cks("A", "B"), at: t1)
        try await store.union(cks("A", "B"), at: t2)
        let snap = try await store.snapshot()
        #expect(Set(snap.keys) == cks("A", "B"))
        #expect(snap.count == 2)
        #expect(snap[ck("A")] == t1)
        #expect(snap[ck("B")] == t1)
    }

    @Test("remove drops present entries and ignores absent ones")
    func removeDropsEntries() async throws {
        let container = try makeContainer()
        let store = SwiftDataConfirmedDeletedStore(container: container)
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.union(cks("A", "B", "C"), at: t)

        try await store.remove(cks("B", "ZZZ"))

        let snap = try await store.snapshot()
        #expect(Set(snap.keys) == cks("A", "C"))
    }

    @Test("remove with no overlap is a silent no-op")
    func removeNoOpOnMissing() async throws {
        let container = try makeContainer()
        let store = SwiftDataConfirmedDeletedStore(container: container)
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.union(cks("A"), at: t)

        try await store.remove(cks("Z"))

        let snap = try await store.snapshot()
        #expect(Set(snap.keys) == cks("A"))
    }

    @Test("two stores sharing a container see each other's writes")
    func sharedContainerVisibility() async throws {
        let container = try makeContainer()
        let writer = SwiftDataConfirmedDeletedStore(container: container)
        let reader = SwiftDataConfirmedDeletedStore(container: container)
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        try await writer.union(cks("A", "B"), at: t)
        let snap = try await reader.snapshot()
        #expect(Set(snap.keys) == cks("A", "B"))
        #expect(snap[ck("A")] == t)
        #expect(snap[ck("B")] == t)
    }
}

// MARK: - SwiftDataLocalHashStore

@Suite("SwiftDataLocalHashStore")
struct SwiftDataLocalHashStoreTests {
    @Test("empty container snapshot is empty and checksums(for:) returns empty")
    func emptyContainer() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalHashStore(container: container)
        #expect(try await store.snapshot().isEmpty)
        #expect(try await store.checksums(for: "unknown").isEmpty)
    }

    @Test("set then checksums(for:) returns the set")
    func setThenRead() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalHashStore(container: container)

        try await store.set(cks("A", "B"), for: "id-1")
        #expect(try await store.checksums(for: "id-1") == cks("A", "B"))
    }

    @Test("calling set twice replaces the previous set — does not merge")
    func setReplaces() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalHashStore(container: container)

        try await store.set(cks("A", "B"), for: "id-1")
        try await store.set(cks("C"), for: "id-1")

        // B and A should be gone; only C remains. A Live Photo edit that
        // rewrites content must not carry the stale hashes forward.
        #expect(try await store.checksums(for: "id-1") == cks("C"))
    }

    @Test("removeAll(for:) drops entries for the specified identifiers only")
    func removeAllDrops() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalHashStore(container: container)

        try await store.set(cks("A"), for: "id-1")
        try await store.set(cks("B"), for: "id-2")
        try await store.set(cks("C"), for: "id-3")

        try await store.removeAll(for: ["id-1", "id-3", "id-absent"])

        #expect(try await store.checksums(for: "id-1").isEmpty)
        #expect(try await store.checksums(for: "id-3").isEmpty)
        // id-2 untouched.
        #expect(try await store.checksums(for: "id-2") == cks("B"))
    }

    @Test("snapshot returns the full identifier → checksums map")
    func snapshotReturnsFullMap() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalHashStore(container: container)

        try await store.set(cks("A", "B"), for: "id-1")
        try await store.set(cks("C"), for: "id-2")

        let snap = try await store.snapshot()
        #expect(snap.count == 2)
        #expect(snap["id-1"] == cks("A", "B"))
        #expect(snap["id-2"] == cks("C"))
    }

    @Test("empty removeAll is a no-op")
    func emptyRemoveAllIsNoop() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalHashStore(container: container)

        try await store.set(cks("A"), for: "id-1")
        try await store.removeAll(for: [])
        #expect(try await store.checksums(for: "id-1") == cks("A"))
    }

    @Test("modificationDate round-trips when set")
    func modificationDateRoundTrips() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalHashStore(container: container)

        let modDate = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.set(cks("A", "B"), for: "id-1", modificationDate: modDate)
        #expect(try await store.modificationDate(for: "id-1") == modDate)
    }

    @Test("modificationDate returns nil for unknown id")
    func modificationDateUnknownReturnsNil() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalHashStore(container: container)
        #expect(try await store.modificationDate(for: "never-set") == nil)
    }

    @Test("modificationDate returns nil when legacy set(_:for:) was used (no date)")
    func modificationDateNilFromLegacySet() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalHashStore(container: container)

        // Default extension that omits modificationDate → stored as nil.
        try await store.set(cks("A"), for: "id-1")
        #expect(try await store.modificationDate(for: "id-1") == nil)
        // But the checksums are still intact.
        #expect(try await store.checksums(for: "id-1") == cks("A"))
    }

    @Test("re-setting overrides both checksums and modificationDate")
    func reSetOverridesDate() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalHashStore(container: container)

        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let second = Date(timeIntervalSince1970: 1_700_999_999)
        try await store.set(cks("A"), for: "id-1", modificationDate: first)
        try await store.set(cks("B", "C"), for: "id-1", modificationDate: second)

        #expect(try await store.checksums(for: "id-1") == cks("B", "C"))
        #expect(try await store.modificationDate(for: "id-1") == second)
    }

    @Test("allLocalIdentifiers returns just the keys without checksum values")
    func allLocalIdentifiersReturnsKeys() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalHashStore(container: container)

        try await store.set(cks("A", "B"), for: "id-1")
        try await store.set(cks("C"), for: "id-2")
        try await store.set(cks("D"), for: "id-3")

        let ids = try await store.allLocalIdentifiers()
        #expect(ids == ["id-1", "id-2", "id-3"])
    }

    @Test("allLocalIdentifiers on empty store returns empty set")
    func allLocalIdentifiersEmpty() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalHashStore(container: container)
        #expect(try await store.allLocalIdentifiers().isEmpty)
    }

    @Test("allChecksums flattens Live Photo pairs into a single set")
    func allChecksumsFlattens() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalHashStore(container: container)

        // Live Photo: still + motion video share one localIdentifier.
        try await store.set(cks("A", "A_motion"), for: "id-1")
        try await store.set(cks("B"), for: "id-2")

        let all = try await store.allChecksums()
        #expect(all == cks("A", "A_motion", "B"))
    }

    @Test("entries(forIdentifiers:) batch-fetches matching ids only")
    func entriesForIdentifiersBatch() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalHashStore(container: container)

        let modDate = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.set(cks("A", "B"), for: "id-1", modificationDate: modDate)
        try await store.set(cks("C"), for: "id-2", modificationDate: nil)
        try await store.set(cks("D"), for: "id-3")

        let result = try await store.entries(forIdentifiers: ["id-1", "id-3", "id-absent"])
        #expect(result.count == 2)
        #expect(result["id-1"]?.checksums == cks("A", "B"))
        #expect(result["id-1"]?.modificationDate == modDate)
        #expect(result["id-3"]?.checksums == cks("D"))
        #expect(result["id-3"]?.modificationDate == nil)
        #expect(result["id-absent"] == nil)
        // id-2 was not in the request set, must not appear
        #expect(result["id-2"] == nil)
    }

    @Test("entries(forIdentifiers:) on empty input returns empty dict")
    func entriesForIdentifiersEmptyInput() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalHashStore(container: container)
        try await store.set(cks("A"), for: "id-1")
        let result = try await store.entries(forIdentifiers: [])
        #expect(result.isEmpty)
    }

    // MARK: - Fast initial scan (imputed flag)

    @Test("setImputed marks the entry as imputed")
    func setImputedMarksImputed() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalHashStore(container: container)

        try await store.setImputed([Checksum(base64: "A")], for: "id-1", modificationDate: nil)
        #expect(try await store.isImputed(for: "id-1") == true)
        // Cached checksum reads back identically — imputed entries
        // participate in the normal lookup path.
        #expect(try await store.checksums(for: "id-1") == cks("A"))
    }

    @Test("set clears the imputed flag (verify-on-touch contract)")
    func setClearsImputedFlag() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalHashStore(container: container)

        try await store.setImputed([Checksum(base64: "A")], for: "id-1", modificationDate: nil)
        #expect(try await store.isImputed(for: "id-1") == true)

        // The hashing path (set) is treated as "this value was just
        // computed locally" — imputed flag must drop to false.
        try await store.set(cks("A"), for: "id-1", modificationDate: nil)
        #expect(try await store.isImputed(for: "id-1") == false)
    }

    @Test("set on a fresh id leaves imputed false")
    func setOnFreshIdNotImputed() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalHashStore(container: container)

        try await store.set(cks("A"), for: "id-1", modificationDate: nil)
        #expect(try await store.isImputed(for: "id-1") == false)
    }

    @Test("isImputed returns false for unknown identifiers")
    func isImputedForUnknownIdIsFalse() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalHashStore(container: container)
        #expect(try await store.isImputed(for: "ghost") == false)
    }

    @Test("imputedCount and imputedIdentifiers reflect imputed entries only")
    func imputedCountAndIdentifiersFilterCorrectly() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalHashStore(container: container)

        try await store.setImputed([Checksum(base64: "A")], for: "id-1", modificationDate: nil)
        try await store.setImputed([Checksum(base64: "B")], for: "id-2", modificationDate: nil)
        try await store.set(cks("C"), for: "id-3", modificationDate: nil)

        #expect(try await store.imputedCount() == 2)
        let imputed = try await store.imputedIdentifiers()
        #expect(imputed == ["id-1", "id-2"])
    }

    @Test("setImputed replaces any prior entries for the identifier")
    func setImputedReplacesPriorEntries() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalHashStore(container: container)

        try await store.set(cks("A", "B"), for: "id-1", modificationDate: nil)
        try await store.setImputed([Checksum(base64: "C")], for: "id-1", modificationDate: nil)

        // Old A and B gone; only the imputed C remains.
        #expect(try await store.checksums(for: "id-1") == cks("C"))
        #expect(try await store.isImputed(for: "id-1") == true)
    }

    // MARK: - Export / restore round-trip

    @Test("exportableRows materializes every row with metadata + imputed flag")
    func exportableRowsReturnsAllRowsWithMetadata() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalHashStore(container: container)
        let modDate = Date(timeIntervalSince1970: 1_700_000_000)

        // One id with two checksums (Live Photo), one id imputed.
        try await store.set(cks("A", "B"), for: "id-1", modificationDate: modDate)
        try await store.setImputed([Checksum(base64: "C")], for: "id-2", modificationDate: nil)

        let rows = try await store.exportableRows()
        #expect(rows.count == 3)
        // Two rows for id-1 (verified, with modDate), one for id-2 (imputed).
        let id1Rows = rows.filter { $0.localId == "id-1" }
        #expect(id1Rows.count == 2)
        #expect(id1Rows.allSatisfy { !$0.imputed })
        #expect(id1Rows.allSatisfy { $0.modificationDate == modDate })
        let id2Rows = rows.filter { $0.localId == "id-2" }
        #expect(id2Rows.count == 1)
        #expect(id2Rows[0].imputed == true)
        #expect(id2Rows[0].checksum == Checksum(base64: "C"))
    }

    @Test("restoreFromExport rebuilds an equivalent store from exported rows")
    func restoreFromExportRoundTrips() async throws {
        // Build a source store, snapshot it, restore into a clean
        // store, compare. This is the end-to-end path the
        // Settings → Export → Import flow uses.
        let modDate = Date(timeIntervalSince1970: 1_700_000_000)
        let source = SwiftDataLocalHashStore(container: try makeContainer())
        try await source.set(cks("A", "B"), for: "id-1", modificationDate: modDate)
        try await source.setImputed([Checksum(base64: "C")], for: "id-2", modificationDate: nil)
        try await source.set(cks("D"), for: "id-3", modificationDate: modDate)

        let rows = try await source.exportableRows()

        let dest = SwiftDataLocalHashStore(container: try makeContainer())
        try await dest.restoreFromExport(rows)

        // Each id round-trips with the right checksums and imputed flag.
        #expect(try await dest.checksums(for: "id-1") == cks("A", "B"))
        #expect(try await dest.isImputed(for: "id-1") == false)
        #expect(try await dest.checksums(for: "id-2") == cks("C"))
        #expect(try await dest.isImputed(for: "id-2") == true)
        #expect(try await dest.checksums(for: "id-3") == cks("D"))
        #expect(try await dest.isImputed(for: "id-3") == false)
        #expect(try await dest.modificationDate(for: "id-1") == modDate)
        #expect(try await dest.modificationDate(for: "id-2") == nil)
    }

    @Test("restoreFromExport on an empty input is a no-op")
    func restoreFromExportEmptyInput() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalHashStore(container: container)
        try await store.set(cks("A"), for: "id-1")
        try await store.restoreFromExport([])
        // Existing entries untouched.
        #expect(try await store.checksums(for: "id-1") == cks("A"))
    }
}

// MARK: - SwiftDataPersistentChangeTokenStore

@Suite("SwiftDataPersistentChangeTokenStore")
struct SwiftDataPersistentChangeTokenStoreTests {
    @Test("empty container load returns nil")
    func emptyLoadReturnsNil() async throws {
        let container = try makeContainer()
        let store = SwiftDataPersistentChangeTokenStore(container: container)
        #expect(try await store.load() == nil)
    }

    @Test("save then load round-trips bytes and savedAt")
    func saveThenLoadRoundTrips() async throws {
        let container = try makeContainer()
        let store = SwiftDataPersistentChangeTokenStore(container: container)

        let bytes = Data([0x01, 0x02, 0x03, 0xff, 0x00])
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.save(StoredToken(data: bytes, savedAt: savedAt))

        let loaded = try await store.load()
        #expect(loaded?.data == bytes)
        #expect(loaded?.savedAt == savedAt)
    }

    @Test("save twice upserts the singleton — only the second write survives")
    func saveTwiceUpserts() async throws {
        let container = try makeContainer()
        let store = SwiftDataPersistentChangeTokenStore(container: container)

        try await store.save(StoredToken(
            data: Data([0x01]),
            savedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try await store.save(StoredToken(
            data: Data([0x02, 0x03]),
            savedAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))

        let loaded = try await store.load()
        #expect(loaded?.data == Data([0x02, 0x03]))
        #expect(loaded?.savedAt == Date(timeIntervalSince1970: 1_800_000_000))

        // And there is only one row under the covers — a fresh reader instance
        // observes the same singleton, not a pair of competing rows.
        let reader = SwiftDataPersistentChangeTokenStore(container: container)
        let readerLoaded = try await reader.load()
        #expect(readerLoaded?.data == Data([0x02, 0x03]))
    }

    @Test("clear removes the saved token — subsequent load returns nil")
    func clearRemovesToken() async throws {
        let container = try makeContainer()
        let store = SwiftDataPersistentChangeTokenStore(container: container)

        try await store.save(StoredToken(
            data: Data([0x01, 0x02]),
            savedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        #expect(try await store.load() != nil)

        try await store.clear()
        #expect(try await store.load() == nil)
    }

    @Test("clear on empty store is a safe no-op")
    func clearOnEmptyIsNoop() async throws {
        let container = try makeContainer()
        let store = SwiftDataPersistentChangeTokenStore(container: container)
        try await store.clear()  // must not throw
        #expect(try await store.load() == nil)
    }
}

// MARK: - SwiftDataDeferredHashStore

@Suite("SwiftDataDeferredHashStore")
struct SwiftDataDeferredHashStoreTests {

    private func entry(
        _ id: String,
        reason: DeferredHashEntry.DeferReason = .tooLarge,
        size: Int64? = 200 * 1024 * 1024,
        at seconds: TimeInterval = 1_700_000_000
    ) -> DeferredHashEntry {
        DeferredHashEntry(
            localIdentifier: id,
            reason: reason,
            sizeBytes: size,
            firstDeferredAt: Date(timeIntervalSince1970: seconds)
        )
    }

    @Test("empty store returns empty snapshot and count 0")
    func emptyStoreIsEmpty() async throws {
        let container = try makeContainer()
        let store = SwiftDataDeferredHashStore(container: container)
        #expect(try await store.snapshot().isEmpty)
        #expect(try await store.count() == 0)
    }

    @Test("upsert inserts new rows; snapshot returns all entries")
    func upsertInsertsNew() async throws {
        let container = try makeContainer()
        let store = SwiftDataDeferredHashStore(container: container)
        try await store.upsert([
            entry("asset-A"),
            entry("asset-B", reason: .timedOut, size: nil),
        ])
        let snap = try await store.snapshot()
        #expect(snap.count == 2)
        #expect(Set(snap.map(\.localIdentifier)) == ["asset-A", "asset-B"])
        #expect(try await store.count() == 2)
    }

    @Test("upsert preserves firstDeferredAt on existing rows (first-write-wins)")
    func upsertPreservesFirstDeferredAt() async throws {
        let container = try makeContainer()
        let store = SwiftDataDeferredHashStore(container: container)
        let original = entry("asset-A", at: 1_700_000_000)
        try await store.upsert([original])

        // Re-upsert same id with a *newer* timestamp and different size.
        // Reason + size should overwrite; firstDeferredAt should NOT.
        let retried = entry(
            "asset-A",
            reason: .timedOut,
            size: 999,
            at: 1_700_090_000
        )
        try await store.upsert([retried])

        let snap = try await store.snapshot()
        #expect(snap.count == 1)
        let row = snap[0]
        #expect(row.firstDeferredAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(row.reason == .timedOut)
        #expect(row.sizeBytes == 999)
    }

    @Test("remove drops entries; unknown ids are silent no-ops")
    func removeDropsEntries() async throws {
        let container = try makeContainer()
        let store = SwiftDataDeferredHashStore(container: container)
        try await store.upsert([entry("A"), entry("B"), entry("C")])

        try await store.remove(["B", "ghost"])
        let snap = try await store.snapshot()
        #expect(Set(snap.map(\.localIdentifier)) == ["A", "C"])
    }

    @Test("clear nukes every entry")
    func clearWipesAll() async throws {
        let container = try makeContainer()
        let store = SwiftDataDeferredHashStore(container: container)
        try await store.upsert([entry("A"), entry("B")])
        try await store.clear()
        #expect(try await store.snapshot().isEmpty)
        #expect(try await store.count() == 0)
    }

    @Test("reasons round-trip through SwiftData as their raw value")
    func reasonsRoundTrip() async throws {
        let container = try makeContainer()
        let store = SwiftDataDeferredHashStore(container: container)
        try await store.upsert([
            entry("A", reason: .tooLarge),
            entry("B", reason: .timedOut, size: nil),
            entry("C", reason: .noHashableResources, size: nil),
            entry("D", reason: .aboveHardCeiling, size: 4_000_000_000),
        ])
        let snap = try await store.snapshot()
        let byId = Dictionary(uniqueKeysWithValues: snap.map { ($0.localIdentifier, $0.reason) })
        #expect(byId["A"] == .tooLarge)
        #expect(byId["B"] == .timedOut)
        #expect(byId["C"] == .noHashableResources)
        #expect(byId["D"] == .aboveHardCeiling)
    }

    @Test("aboveHardCeiling row preserves size + firstDeferredAt across upsert")
    func aboveHardCeilingPersists() async throws {
        // The whole point of persisting these rows is so they show up
        // in the deferred-queue UI with their download size — verify
        // that the size and the deferred timestamp survive the
        // SwiftData round-trip and a re-upsert from a later sync
        // doesn't clobber the original timestamp.
        let container = try makeContainer()
        let store = SwiftDataDeferredHashStore(container: container)
        let original = entry(
            "huge-asset",
            reason: .aboveHardCeiling,
            size: 3_500_000_000,
            at: 1_700_000_000
        )
        try await store.upsert([original])

        // Second sync re-observes the same id at a different time —
        // first-write-wins on the timestamp, but the size + reason
        // come through.
        let reobserved = entry(
            "huge-asset",
            reason: .aboveHardCeiling,
            size: 3_500_000_000,
            at: 1_700_090_000
        )
        try await store.upsert([reobserved])

        let snap = try await store.snapshot()
        #expect(snap.count == 1)
        let row = snap[0]
        #expect(row.reason == .aboveHardCeiling)
        #expect(row.sizeBytes == 3_500_000_000)
        #expect(row.firstDeferredAt == Date(timeIntervalSince1970: 1_700_000_000))
    }
}

// MARK: - SwiftDataLocalAssetMetadataStore

@Suite("SwiftDataLocalAssetMetadataStore")
struct SwiftDataLocalAssetMetadataStoreTests {
    private func entry(
        _ id: String,
        filename: String? = "IMG_0001.HEIC",
        creation: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        modification: Date? = nil,
        size: Int64? = 1024
    ) -> LocalAssetMetadata {
        LocalAssetMetadata(
            localIdentifier: id,
            originalFileName: filename,
            creationDate: creation,
            modificationDate: modification,
            fileSize: size,
            observedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
    }

    @Test("empty container returns nil for any id")
    func emptyContainer() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalAssetMetadataStore(container: container)
        #expect(try await store.metadata(for: "anything") == nil)
    }

    @Test("record then metadata(for:) round-trips all fields")
    func recordRoundTrips() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalAssetMetadataStore(container: container)

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let modified = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.record(LocalAssetMetadata(
            localIdentifier: "id-1",
            originalFileName: "IMG_0001.HEIC",
            creationDate: created,
            modificationDate: modified,
            fileSize: 12345,
            observedAt: now
        ))

        let got = try await store.metadata(for: "id-1")
        #expect(got?.localIdentifier == "id-1")
        #expect(got?.originalFileName == "IMG_0001.HEIC")
        #expect(got?.creationDate == created)
        #expect(got?.modificationDate == modified)
        #expect(got?.fileSize == 12345)
        #expect(got?.observedAt == now)
    }

    @Test("record bulk overload writes every entry")
    func recordBulkWritesAll() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalAssetMetadataStore(container: container)
        try await store.record([
            entry("id-1", filename: "a.heic"),
            entry("id-2", filename: "b.heic"),
            entry("id-3", filename: "c.heic"),
        ])
        #expect(try await store.metadata(for: "id-1")?.originalFileName == "a.heic")
        #expect(try await store.metadata(for: "id-2")?.originalFileName == "b.heic")
        #expect(try await store.metadata(for: "id-3")?.originalFileName == "c.heic")
    }

    @Test("re-recording the same id replaces fields except observedAt")
    func reRecordReplaces() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalAssetMetadataStore(container: container)

        let firstObserved = Date(timeIntervalSince1970: 2_000_000_000)
        let secondObserved = Date(timeIntervalSince1970: 2_500_000_000)

        try await store.record(LocalAssetMetadata(
            localIdentifier: "id-1",
            originalFileName: "old.heic",
            creationDate: nil, modificationDate: nil, fileSize: 100,
            observedAt: firstObserved
        ))
        try await store.record(LocalAssetMetadata(
            localIdentifier: "id-1",
            originalFileName: "new.heic",
            creationDate: nil, modificationDate: nil, fileSize: 200,
            observedAt: secondObserved
        ))

        let got = try await store.metadata(for: "id-1")
        #expect(got?.originalFileName == "new.heic")
        #expect(got?.fileSize == 200)
        // observedAt is "first observation" — must not advance on re-record.
        #expect(got?.observedAt == firstObserved)
    }

    @Test("remove drops the requested entries only")
    func removeDropsEntries() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalAssetMetadataStore(container: container)
        try await store.record([
            entry("id-1"), entry("id-2"), entry("id-3"),
        ])
        try await store.remove(["id-1", "id-3", "id-absent"])
        #expect(try await store.metadata(for: "id-1") == nil)
        #expect(try await store.metadata(for: "id-3") == nil)
        #expect(try await store.metadata(for: "id-2") != nil)
    }

    @Test("clear wipes the store")
    func clearWipes() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalAssetMetadataStore(container: container)
        try await store.record([entry("id-1"), entry("id-2")])
        try await store.clear()
        #expect(try await store.metadata(for: "id-1") == nil)
        #expect(try await store.metadata(for: "id-2") == nil)
    }

    @Test("nullable fields round-trip nil correctly")
    func nullableFieldsRoundTripNil() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalAssetMetadataStore(container: container)
        try await store.record(LocalAssetMetadata(
            localIdentifier: "id-1",
            originalFileName: nil,
            creationDate: nil,
            modificationDate: nil,
            fileSize: nil,
            observedAt: Date()
        ))
        let got = try await store.metadata(for: "id-1")
        #expect(got != nil)
        #expect(got?.originalFileName == nil)
        #expect(got?.creationDate == nil)
        #expect(got?.modificationDate == nil)
        #expect(got?.fileSize == nil)
    }

    @Test("empty remove + empty record are no-ops")
    func emptyOpsAreNoops() async throws {
        let container = try makeContainer()
        let store = SwiftDataLocalAssetMetadataStore(container: container)
        try await store.record([])
        try await store.remove([])
        try await store.record([entry("id-1")])
        #expect(try await store.metadata(for: "id-1") != nil)
    }
}

// MARK: - SwiftDataEditRetirementStore

@Suite("SwiftDataEditRetirementStore")
struct SwiftDataEditRetirementStoreTests {

    @Test("empty container reads as empty for any id")
    func emptyContainer() async throws {
        let container = try makeContainer()
        let store = SwiftDataEditRetirementStore(container: container)
        #expect(try await store.firstObserved(for: "id-X") == [])
        #expect(try await store.snapshot().isEmpty)
    }

    @Test("recordFirstObserved + read round-trips Live-Photo-style sets")
    func recordRoundTrip() async throws {
        let container = try makeContainer()
        let store = SwiftDataEditRetirementStore(container: container)
        try await store.recordFirstObserved(cks("STILL", "MOTION"), for: "id-live")
        #expect(try await store.firstObserved(for: "id-live") == cks("STILL", "MOTION"))
    }

    @Test("recordFirstObserved is first-write-wins — second call cannot overwrite")
    func firstWriteWins() async throws {
        let container = try makeContainer()
        let store = SwiftDataEditRetirementStore(container: container)
        try await store.recordFirstObserved(cks("ORIGINAL"), for: "id-1")
        // Same id, different (post-edit) checksums must NOT win.
        try await store.recordFirstObserved(cks("EDITED"), for: "id-1")
        #expect(try await store.firstObserved(for: "id-1") == cks("ORIGINAL"))
    }

    @Test("empty checksum set is a no-op")
    func emptyRecordIsNoOp() async throws {
        let container = try makeContainer()
        let store = SwiftDataEditRetirementStore(container: container)
        try await store.recordFirstObserved([], for: "id-1")
        #expect(try await store.firstObserved(for: "id-1") == [])
        // The slot is still claimable.
        try await store.recordFirstObserved(cks("REAL"), for: "id-1")
        #expect(try await store.firstObserved(for: "id-1") == cks("REAL"))
    }

    @Test("snapshot returns every id with its full checksum set")
    func snapshotContents() async throws {
        let container = try makeContainer()
        let store = SwiftDataEditRetirementStore(container: container)
        try await store.recordFirstObserved(cks("A"), for: "id-1")
        try await store.recordFirstObserved(cks("B", "C"), for: "id-2")

        let snap = try await store.snapshot()
        #expect(snap.count == 2)
        #expect(snap["id-1"] == cks("A"))
        #expect(snap["id-2"] == cks("B", "C"))
    }

    @Test("remove drops the requested ids and silently skips absent ones")
    func removeDropsEntries() async throws {
        let container = try makeContainer()
        let store = SwiftDataEditRetirementStore(container: container)
        try await store.recordFirstObserved(cks("A"), for: "id-1")
        try await store.recordFirstObserved(cks("B"), for: "id-2")

        try await store.remove(for: ["id-2", "id-MISSING"])

        #expect(try await store.firstObserved(for: "id-1") == cks("A"))
        #expect(try await store.firstObserved(for: "id-2") == [])
    }

    @Test("clear wipes every entry")
    func clearWipes() async throws {
        let container = try makeContainer()
        let store = SwiftDataEditRetirementStore(container: container)
        try await store.recordFirstObserved(cks("A"), for: "id-1")
        try await store.recordFirstObserved(cks("B"), for: "id-2")

        try await store.clear()
        #expect(try await store.snapshot().isEmpty)
    }

    @Test("two stores sharing one container see each other's writes")
    func sharedContainerCrossVisibility() async throws {
        let container = try makeContainer()
        let writer = SwiftDataEditRetirementStore(container: container)
        let reader = SwiftDataEditRetirementStore(container: container)

        try await writer.recordFirstObserved(cks("X", "Y"), for: "id-shared")
        #expect(try await reader.firstObserved(for: "id-shared") == cks("X", "Y"))
    }

    @Test("re-record after explicit remove DOES seed a fresh anchor")
    func reseedAfterRemove() async throws {
        // The "first-write-wins" rule is scoped to the lifetime of an
        // entry. Once removed (id genuinely deleted), a later
        // observation under the same id should be allowed to seed
        // again — otherwise a re-imported asset (same localIdentifier
        // recycled, theoretically possible across a restore-from-iCloud
        // window) would lose protection forever.
        let container = try makeContainer()
        let store = SwiftDataEditRetirementStore(container: container)
        try await store.recordFirstObserved(cks("A"), for: "id-1")
        try await store.remove(for: ["id-1"])
        try await store.recordFirstObserved(cks("B"), for: "id-1")
        #expect(try await store.firstObserved(for: "id-1") == cks("B"))
    }
}

// MARK: - SwiftDataDeletionSourceStore

@Suite("SwiftDataDeletionSourceStore")
struct SwiftDataDeletionSourceStoreTests {

    @Test("empty container snapshot is empty")
    func emptySnapshot() async throws {
        let container = try makeContainer()
        let store = SwiftDataDeletionSourceStore(container: container)
        #expect(try await store.snapshot().isEmpty)
    }

    @Test("record + snapshot round-trips per-checksum localIdentifier")
    func recordRoundTrip() async throws {
        let container = try makeContainer()
        let store = SwiftDataDeletionSourceStore(container: container)
        try await store.record([ck("A"): "id-1", ck("B"): "id-2"])

        let snap = try await store.snapshot()
        #expect(snap.count == 2)
        #expect(snap[ck("A")] == "id-1")
        #expect(snap[ck("B")] == "id-2")
    }

    @Test("record overwrites the localIdentifier on collision (last write wins)")
    func recordOverwrites() async throws {
        let container = try makeContainer()
        let store = SwiftDataDeletionSourceStore(container: container)
        try await store.record([ck("A"): "id-old"])
        try await store.record([ck("A"): "id-new"])

        let snap = try await store.snapshot()
        #expect(snap.count == 1)
        #expect(snap[ck("A")] == "id-new")
    }

    @Test("remove drops present entries and silently skips absent ones")
    func removeDropsEntries() async throws {
        let container = try makeContainer()
        let store = SwiftDataDeletionSourceStore(container: container)
        try await store.record([ck("A"): "id-1", ck("B"): "id-2", ck("C"): "id-3"])
        try await store.remove([ck("B"), ck("ZZZ")])

        let snap = try await store.snapshot()
        #expect(Set(snap.keys) == Set([ck("A"), ck("C")]))
    }

    @Test("clear wipes every entry")
    func clearWipes() async throws {
        let container = try makeContainer()
        let store = SwiftDataDeletionSourceStore(container: container)
        try await store.record([ck("A"): "id-1", ck("B"): "id-2"])
        try await store.clear()
        #expect(try await store.snapshot().isEmpty)
    }

    @Test("empty record / remove is a no-op")
    func emptyOpsAreNoOps() async throws {
        let container = try makeContainer()
        let store = SwiftDataDeletionSourceStore(container: container)
        try await store.record([:])
        try await store.remove([])
        #expect(try await store.snapshot().isEmpty)
    }

    @Test("two stores sharing one container see each other's writes")
    func sharedContainerCrossVisibility() async throws {
        let container = try makeContainer()
        let writer = SwiftDataDeletionSourceStore(container: container)
        let reader = SwiftDataDeletionSourceStore(container: container)

        try await writer.record([ck("X"): "id-X"])
        let snap = try await reader.snapshot()
        #expect(snap[ck("X")] == "id-X")
    }
}

// MARK: - SwiftDataStatusSnapshotStore

@Suite("SwiftDataStatusSnapshotStore")
struct SwiftDataStatusSnapshotStoreTests {

    private func sample(_ computedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> StatusSnapshot {
        StatusSnapshot(
            deleteCandidatesCount: 14,
            matchedCount: 4_102,
            pendingReviewCount: 3,
            inferredOrphanCount: 1,
            computedAt: computedAt
        )
    }

    @Test("empty container loads as nil")
    func emptyLoadsNil() async throws {
        let container = try makeContainer()
        let store = SwiftDataStatusSnapshotStore(container: container)
        #expect(try await store.load() == nil)
    }

    @Test("save + load round-trips every field")
    func saveLoadRoundTrip() async throws {
        let container = try makeContainer()
        let store = SwiftDataStatusSnapshotStore(container: container)
        let snap = sample()
        try await store.save(snap)

        let loaded = try await store.load()
        #expect(loaded?.deleteCandidatesCount == 14)
        #expect(loaded?.matchedCount == 4_102)
        #expect(loaded?.pendingReviewCount == 3)
        #expect(loaded?.inferredOrphanCount == 1)
        #expect(loaded?.computedAt == snap.computedAt)
    }

    @Test("save is upsert — second save overwrites the first")
    func saveUpserts() async throws {
        let container = try makeContainer()
        let store = SwiftDataStatusSnapshotStore(container: container)

        try await store.save(sample())
        let updated = StatusSnapshot(
            deleteCandidatesCount: 99,
            matchedCount: 9_999,
            pendingReviewCount: 0,
            inferredOrphanCount: 0,
            computedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await store.save(updated)

        let loaded = try await store.load()
        #expect(loaded?.deleteCandidatesCount == 99)
        #expect(loaded?.matchedCount == 9_999)
    }

    @Test("clear wipes the row — subsequent load is nil")
    func clearWipes() async throws {
        let container = try makeContainer()
        let store = SwiftDataStatusSnapshotStore(container: container)
        try await store.save(sample())
        try await store.clear()
        #expect(try await store.load() == nil)
    }

    @Test("clear on empty container is a no-op (no throw)")
    func clearNoOpOnEmpty() async throws {
        let container = try makeContainer()
        let store = SwiftDataStatusSnapshotStore(container: container)
        try await store.clear()
        #expect(try await store.load() == nil)
    }

    @Test("two stores sharing one container see each other's writes")
    func sharedContainerCrossVisibility() async throws {
        let container = try makeContainer()
        let writer = SwiftDataStatusSnapshotStore(container: container)
        let reader = SwiftDataStatusSnapshotStore(container: container)

        try await writer.save(sample())
        let loaded = try await reader.load()
        #expect(loaded?.deleteCandidatesCount == 14)
    }
}

// MARK: - SwiftDataPendingTrashIntentStore

@Suite("SwiftDataPendingTrashIntentStore")
struct SwiftDataPendingTrashIntentStoreTests {

    private func asset(_ id: String, ck: String) -> ServerAsset {
        ServerAsset(
            id: id,
            checksum: Checksum(base64: ck),
            livePhotoVideoId: nil,
            isTrashed: false,
            originalFileName: "\(id).jpg",
            fileCreatedAt: nil
        )
    }

    private func intent(
        runId: String = "run-X",
        assets: [ServerAsset],
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> PendingTrashIntent {
        PendingTrashIntent(
            createdAt: createdAt,
            runId: runId,
            assets: assets,
            assetsInPurview: assets.count
        )
    }

    @Test("empty container snapshot is empty and count is 0")
    func emptyIsEmpty() async throws {
        let container = try makeContainer()
        let store = SwiftDataPendingTrashIntentStore(container: container)
        #expect(try await store.snapshot().isEmpty)
        #expect(try await store.count() == 0)
    }

    @Test("enqueue + snapshot round-trips assets through SwiftData JSON blob")
    func enqueueRoundtrip() async throws {
        let container = try makeContainer()
        let store = SwiftDataPendingTrashIntentStore(container: container)

        let i = intent(assets: [asset("A", ck: "ck-A"), asset("B", ck: "ck-B")])
        try await store.enqueue(i)

        let snap = try await store.snapshot()
        #expect(snap.count == 1)
        #expect(snap.first?.id == i.id)
        #expect(snap.first?.assets.map(\.id) == ["A", "B"])
        #expect(snap.first?.assets.map(\.checksum.base64) == ["ck-A", "ck-B"])
    }

    @Test("snapshot returns intents sorted by createdAt ascending")
    func snapshotSorted() async throws {
        let container = try makeContainer()
        let store = SwiftDataPendingTrashIntentStore(container: container)

        try await store.enqueue(intent(
            runId: "later",
            assets: [asset("B", ck: "ck-B")],
            createdAt: Date(timeIntervalSince1970: 2_000)
        ))
        try await store.enqueue(intent(
            runId: "earlier",
            assets: [asset("A", ck: "ck-A")],
            createdAt: Date(timeIntervalSince1970: 1_000)
        ))

        let snap = try await store.snapshot()
        #expect(snap.map(\.runId) == ["earlier", "later"])
    }

    @Test("update mutates retry metadata; missing id is silent no-op")
    func updateApplies() async throws {
        let container = try makeContainer()
        let store = SwiftDataPendingTrashIntentStore(container: container)

        let i = intent(assets: [asset("A", ck: "ck-A")])
        try await store.enqueue(i)

        let stamp = Date(timeIntervalSince1970: 1_700_001_000)
        try await store.update(i.id, lastAttemptedAt: stamp, attemptCount: 3, lastError: "URLError(-1009)")

        let snap = try await store.snapshot()
        #expect(snap.first?.lastAttemptedAt == stamp)
        #expect(snap.first?.attemptCount == 3)
        #expect(snap.first?.lastError == "URLError(-1009)")

        // Unknown id: no throw, no change.
        try await store.update(UUID(), lastAttemptedAt: stamp, attemptCount: 99, lastError: "ignored")
        let snap2 = try await store.snapshot()
        #expect(snap2.first?.attemptCount == 3)
    }

    @Test("remove(_:) drops by id; remove(matchingRunId:) drops every intent under a runId")
    func removeByIdAndRunId() async throws {
        let container = try makeContainer()
        let store = SwiftDataPendingTrashIntentStore(container: container)

        let a = intent(runId: "shared", assets: [asset("A", ck: "ck-A")])
        let b = intent(runId: "shared", assets: [asset("B", ck: "ck-B")])
        let c = intent(runId: "other", assets: [asset("C", ck: "ck-C")])
        try await store.enqueue(a)
        try await store.enqueue(b)
        try await store.enqueue(c)

        try await store.remove(a.id)
        #expect(try await store.count() == 2)

        try await store.remove(matchingRunId: "shared")
        let snap = try await store.snapshot()
        #expect(snap.map(\.runId) == ["other"])
    }

    @Test("removeIntents(containingAnyOf:) drops the whole intent if any of its checksums match")
    func removeByChecksumIntersection() async throws {
        let container = try makeContainer()
        let store = SwiftDataPendingTrashIntentStore(container: container)

        let multi = intent(runId: "multi", assets: [
            asset("A1", ck: "ck-A1"),
            asset("A2", ck: "ck-A2"),
        ])
        let single = intent(runId: "single", assets: [asset("B1", ck: "ck-B1")])
        try await store.enqueue(multi)
        try await store.enqueue(single)

        try await store.removeIntents(containingAnyOf: [Checksum(base64: "ck-A2")])

        let snap = try await store.snapshot()
        #expect(snap.map(\.runId) == ["single"])
    }

    @Test("two stores sharing one container see each other's writes")
    func sharedContainerCrossVisibility() async throws {
        let container = try makeContainer()
        let writer = SwiftDataPendingTrashIntentStore(container: container)
        let reader = SwiftDataPendingTrashIntentStore(container: container)

        try await writer.enqueue(intent(assets: [asset("A", ck: "ck-A")]))
        let snap = try await reader.snapshot()
        #expect(snap.count == 1)
    }
}

// MARK: - SwiftDataServerAssetCacheStore

@Suite("SwiftDataServerAssetCacheStore")
struct SwiftDataServerAssetCacheStoreTests {

    /// Build a SyncAssetV1 with a unique id + checksum and sensible defaults
    /// for the fields cairn cares about.
    private func asset(
        id: String,
        ck: String,
        livePhotoVideoId: String? = nil,
        visibility: String = "timeline",
        deletedAt: Date? = nil
    ) -> SyncAssetV1 {
        SyncAssetV1(
            id: id,
            ownerId: "u1",
            originalFileName: "\(id).HEIC",
            checksum: ck,
            livePhotoVideoId: livePhotoVideoId,
            deletedAt: deletedAt,
            visibility: visibility,
            isFavorite: false,
            type: "image",
            fileCreatedAt: nil,
            fileModifiedAt: nil,
            width: nil,
            height: nil
        )
    }

    @Test("empty cache snapshots as empty and size 0")
    func emptyIsEmpty() async throws {
        let store = SwiftDataServerAssetCacheStore(container: try makeContainer())
        #expect(try await store.snapshot().isEmpty)
        #expect(try await store.size() == 0)
    }

    @Test("applyEvents inserts new assets, snapshot returns them with correct fields")
    func appliesNewAssets() async throws {
        let store = SwiftDataServerAssetCacheStore(container: try makeContainer())
        let events: [SyncEvent] = [
            .asset(asset(id: "a1", ck: "AAAA"), ack: "ack1"),
            .asset(asset(id: "a2", ck: "BBBB", livePhotoVideoId: "v9"), ack: "ack2"),
        ]
        let summary = try await store.applyEvents(events)
        #expect(summary == ApplyEventsSummary(upserted: 2, deleted: 0, ignored: 0))

        let snap = try await store.snapshot()
        #expect(snap.count == 2)
        let byId = Dictionary(uniqueKeysWithValues: snap.map { ($0.id, $0) })
        #expect(byId["a1"]?.checksum.base64 == "AAAA")
        #expect(byId["a2"]?.livePhotoVideoId == "v9")
    }

    @Test("thumbhash round-trips through cache → snapshot")
    func thumbhashRoundTrips() async throws {
        let store = SwiftDataServerAssetCacheStore(container: try makeContainer())
        let withHash = SyncAssetV1(
            id: "with-hash",
            ownerId: "u1",
            originalFileName: "x.HEIC",
            checksum: "AAAA",
            thumbhash: "Bw0KFw...",
            visibility: "timeline",
            isFavorite: false,
            type: "image"
        )
        let withoutHash = SyncAssetV1(
            id: "no-hash",
            ownerId: "u1",
            originalFileName: "y.HEIC",
            checksum: "BBBB",
            thumbhash: nil,
            visibility: "timeline",
            isFavorite: false,
            type: "image"
        )
        _ = try await store.applyEvents([
            .asset(withHash, ack: "a"),
            .asset(withoutHash, ack: "b"),
        ])
        let snap = try await store.snapshot()
        let byId = Dictionary(uniqueKeysWithValues: snap.map { ($0.id, $0) })
        #expect(byId["with-hash"]?.thumbhash == "Bw0KFw...")
        #expect(byId["no-hash"]?.thumbhash == nil)
    }

    @Test("applyEvents upserts existing assets — same id, overwriting fields")
    func upsertsExisting() async throws {
        let store = SwiftDataServerAssetCacheStore(container: try makeContainer())
        _ = try await store.applyEvents([
            .asset(asset(id: "a1", ck: "OLD"), ack: "ack-old"),
        ])
        let summary = try await store.applyEvents([
            .asset(asset(id: "a1", ck: "NEW"), ack: "ack-new"),
        ])
        #expect(summary == ApplyEventsSummary(upserted: 1, deleted: 0, ignored: 0))

        let snap = try await store.snapshot()
        #expect(snap.count == 1)
        #expect(snap.first?.checksum.base64 == "NEW")
    }

    @Test("applyEvents deletes by serverAssetId via AssetDeleteV1")
    func deletesByAssetId() async throws {
        let store = SwiftDataServerAssetCacheStore(container: try makeContainer())
        _ = try await store.applyEvents([
            .asset(asset(id: "a1", ck: "AAAA"), ack: "ack1"),
            .asset(asset(id: "a2", ck: "BBBB"), ack: "ack2"),
        ])
        let summary = try await store.applyEvents([
            .assetDeleted(SyncAssetDeleteV1(assetId: "a1"), ack: "del-ack"),
        ])
        #expect(summary == ApplyEventsSummary(upserted: 0, deleted: 1, ignored: 0))

        let snap = try await store.snapshot()
        #expect(snap.count == 1)
        #expect(snap.first?.id == "a2")
    }

    @Test("delete tombstone for an unknown id is counted as ignored, not throws")
    func deleteUnknownIsIgnored() async throws {
        let store = SwiftDataServerAssetCacheStore(container: try makeContainer())
        let summary = try await store.applyEvents([
            .assetDeleted(SyncAssetDeleteV1(assetId: "never-cached"), ack: "ack"),
        ])
        #expect(summary == ApplyEventsSummary(upserted: 0, deleted: 0, ignored: 1))
    }

    @Test("complete + ignored events count as ignored")
    func completeAndIgnoredAreIgnored() async throws {
        let store = SwiftDataServerAssetCacheStore(container: try makeContainer())
        let summary = try await store.applyEvents([
            .complete(type: .syncCompleteV1, ack: "c"),
            .ignored(type: "SyncFutureV2", ack: "i"),
        ])
        #expect(summary == ApplyEventsSummary(upserted: 0, deleted: 0, ignored: 2))
    }

    @Test("empty applyEvents returns .empty without persisting anything")
    func emptyApplyIsNoOp() async throws {
        let store = SwiftDataServerAssetCacheStore(container: try makeContainer())
        let summary = try await store.applyEvents([])
        #expect(summary == .empty)
        #expect(try await store.size() == 0)
    }

    @Test("snapshot excludes server-trashed assets (deletedAt != nil) to match listAllAssets default")
    func snapshotExcludesTrashed() async throws {
        let store = SwiftDataServerAssetCacheStore(container: try makeContainer())
        _ = try await store.applyEvents([
            .asset(asset(id: "a1", ck: "AAAA", deletedAt: Date(timeIntervalSince1970: 1_700_000_000)), ack: "ack"),
            .asset(asset(id: "a2", ck: "BBBB"), ack: "ack"),
        ])
        let snap = try await store.snapshot()
        let ids = Set(snap.map(\.id))
        // Trashed asset is filtered out; non-trashed remains.
        // size() still counts both rows — the filter is read-side only.
        #expect(ids == ["a2"])
        #expect(try await store.size() == 2)
    }

    @Test("snapshot excludes hidden + locked visibility — matches default listAllAssets")
    func snapshotExcludesHiddenAndLocked() async throws {
        let store = SwiftDataServerAssetCacheStore(container: try makeContainer())
        let hidden = SyncAssetV1(
            id: "live-motion",
            ownerId: "u1",
            originalFileName: "MOV.MOV",
            checksum: "MOTION",
            livePhotoVideoId: nil,
            deletedAt: nil,
            visibility: "hidden",
            isFavorite: false,
            type: "video",
            fileCreatedAt: nil,
            fileModifiedAt: nil,
            width: nil,
            height: nil
        )
        let locked = SyncAssetV1(
            id: "locked-one",
            ownerId: "u1",
            originalFileName: "LOCKED.HEIC",
            checksum: "LOCKED",
            livePhotoVideoId: nil,
            deletedAt: nil,
            visibility: "locked",
            isFavorite: false,
            type: "image",
            fileCreatedAt: nil,
            fileModifiedAt: nil,
            width: nil,
            height: nil
        )
        _ = try await store.applyEvents([
            .asset(asset(id: "a1", ck: "AAAA"), ack: "ack1"),
            .asset(hidden, ack: "ack2"),
            .asset(locked, ack: "ack3"),
        ])
        let snap = try await store.snapshot()
        let ids = Set(snap.map(\.id))
        #expect(ids == ["a1"])
    }

    @Test("reset wipes every row")
    func resetWipes() async throws {
        let store = SwiftDataServerAssetCacheStore(container: try makeContainer())
        _ = try await store.applyEvents([
            .asset(asset(id: "a1", ck: "AAAA"), ack: "ack1"),
            .asset(asset(id: "a2", ck: "BBBB"), ack: "ack2"),
            .asset(asset(id: "a3", ck: "CCCC"), ack: "ack3"),
        ])
        #expect(try await store.size() == 3)
        try await store.reset()
        #expect(try await store.size() == 0)
        #expect(try await store.snapshot().isEmpty)
    }

    @Test("applyEvents is idempotent — replaying the same batch is a no-op semantically")
    func idempotentReplay() async throws {
        let store = SwiftDataServerAssetCacheStore(container: try makeContainer())
        let batch: [SyncEvent] = [
            .asset(asset(id: "a1", ck: "AAAA"), ack: "ack1"),
            .asset(asset(id: "a2", ck: "BBBB"), ack: "ack2"),
        ]
        _ = try await store.applyEvents(batch)
        _ = try await store.applyEvents(batch)

        // Same two assets in the snapshot — re-applying the same
        // ack doesn't create duplicate rows. This is the property
        // that lets the coordinator safely ack-after-apply.
        #expect(try await store.size() == 2)
    }

    @Test("two stores sharing one container see each other's writes")
    func twoStoresShareContainer() async throws {
        let container = try makeContainer()
        let writer = SwiftDataServerAssetCacheStore(container: container)
        let reader = SwiftDataServerAssetCacheStore(container: container)

        _ = try await writer.applyEvents([
            .asset(asset(id: "a1", ck: "AAAA"), ack: "ack")
        ])
        #expect(try await reader.size() == 1)
    }
}

// MARK: - SwiftDataSyncAckStore

@Suite("SwiftDataSyncAckStore")
struct SwiftDataSyncAckStoreTests {

    @Test("empty store returns nil for any type and empty allAcks")
    func emptyIsEmpty() async throws {
        let store = SwiftDataSyncAckStore(container: try makeContainer())
        #expect(try await store.ack(for: .assetV1) == nil)
        #expect(try await store.allAcks().isEmpty)
    }

    @Test("setAck + ack round-trips per-type")
    func setAndGet() async throws {
        let store = SwiftDataSyncAckStore(container: try makeContainer())
        try await store.setAck("a-cursor", for: .assetV1)
        try await store.setAck("d-cursor", for: .assetDeleteV1)

        #expect(try await store.ack(for: .assetV1) == "a-cursor")
        #expect(try await store.ack(for: .assetDeleteV1) == "d-cursor")
        #expect(try await store.ack(for: .syncCompleteV1) == nil)
    }

    @Test("setAck overwrites on second call for the same type")
    func setAckOverwrites() async throws {
        let store = SwiftDataSyncAckStore(container: try makeContainer())
        try await store.setAck("first", for: .assetV1)
        try await store.setAck("second", for: .assetV1)
        #expect(try await store.ack(for: .assetV1) == "second")
        #expect(try await store.allAcks().count == 1)
    }

    @Test("setAck with the same value is a no-op (no extra row, no failed save)")
    func setAckSameValueIsNoOp() async throws {
        let store = SwiftDataSyncAckStore(container: try makeContainer())
        try await store.setAck("a", for: .assetV1)
        try await store.setAck("a", for: .assetV1)
        try await store.setAck("a", for: .assetV1)
        #expect(try await store.allAcks().count == 1)
    }

    @Test("allAcks returns every persisted cursor")
    func allAcksReturnsAll() async throws {
        let store = SwiftDataSyncAckStore(container: try makeContainer())
        try await store.setAck("a", for: .assetV1)
        try await store.setAck("d", for: .assetDeleteV1)
        let acks = try await store.allAcks()
        #expect(Set(acks) == Set([
            SyncAckRecord(type: .assetV1, ack: "a"),
            SyncAckRecord(type: .assetDeleteV1, ack: "d"),
        ]))
    }

    @Test("clearAll wipes every row")
    func clearWipes() async throws {
        let store = SwiftDataSyncAckStore(container: try makeContainer())
        try await store.setAck("a", for: .assetV1)
        try await store.setAck("d", for: .assetDeleteV1)
        try await store.clearAll()
        #expect(try await store.allAcks().isEmpty)
    }

    @Test("two stores sharing one container see each other's writes")
    func twoStoresShareContainer() async throws {
        let container = try makeContainer()
        let writer = SwiftDataSyncAckStore(container: container)
        let reader = SwiftDataSyncAckStore(container: container)

        try await writer.setAck("a-cursor", for: .assetV1)
        #expect(try await reader.ack(for: .assetV1) == "a-cursor")
    }
}
