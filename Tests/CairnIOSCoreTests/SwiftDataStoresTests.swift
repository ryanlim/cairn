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

// MARK: - SwiftDataEverSeenStore

@Suite("SwiftDataEverSeenStore")
struct SwiftDataEverSeenStoreTests {

    @Test("empty container snapshot returns empty set")
    func emptyIsEmpty() async throws {
        let container = try makeContainer()
        let store = SwiftDataEverSeenStore(container: container)
        #expect(try await store.snapshot().isEmpty)
    }

    @Test("union + snapshot roundtrips")
    func unionRoundtrips() async throws {
        let container = try makeContainer()
        let store = SwiftDataEverSeenStore(container: container)

        try await store.union(cks("A", "B"))
        try await store.union(cks("C"))

        #expect(try await store.snapshot() == cks("A", "B", "C"))
    }

    @Test("union with overlapping checksums is idempotent — no duplicates, no errors")
    func overlapIdempotent() async throws {
        let container = try makeContainer()
        let store = SwiftDataEverSeenStore(container: container)

        try await store.union(cks("A", "B"))
        try await store.union(cks("B", "C"))
        try await store.union(cks("A", "B", "C"))

        #expect(try await store.snapshot() == cks("A", "B", "C"))
    }

    @Test("two stores sharing one container see each other's writes")
    func sharedContainerCrossVisibility() async throws {
        let container = try makeContainer()
        let writer = SwiftDataEverSeenStore(container: container)
        let reader = SwiftDataEverSeenStore(container: container)

        try await writer.union(cks("X", "Y", "Z"))

        #expect(try await reader.snapshot() == cks("X", "Y", "Z"))
    }

    @Test("empty union is a no-op")
    func emptyUnionNoop() async throws {
        let container = try makeContainer()
        let store = SwiftDataEverSeenStore(container: container)

        try await store.union([])
        #expect(try await store.snapshot().isEmpty)
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
        ])
        let snap = try await store.snapshot()
        let byId = Dictionary(uniqueKeysWithValues: snap.map { ($0.localIdentifier, $0.reason) })
        #expect(byId["A"] == .tooLarge)
        #expect(byId["B"] == .timedOut)
        #expect(byId["C"] == .noHashableResources)
    }
}
