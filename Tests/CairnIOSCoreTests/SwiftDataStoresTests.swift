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

    @Test("union + snapshot roundtrip")
    func unionRoundTrip() async throws {
        let container = try makeContainer()
        let store = SwiftDataConfirmedDeletedStore(container: container)
        try await store.union(cks("A", "B"))
        try await store.union(cks("B", "C"))
        #expect(try await store.snapshot() == cks("A", "B", "C"))
    }

    @Test("union with overlapping checksums is idempotent")
    func unionIsIdempotent() async throws {
        let container = try makeContainer()
        let store = SwiftDataConfirmedDeletedStore(container: container)
        try await store.union(cks("A", "B"))
        try await store.union(cks("A", "B"))
        let snap = try await store.snapshot()
        #expect(snap == cks("A", "B"))
        #expect(snap.count == 2)
    }

    @Test("two stores sharing a container see each other's writes")
    func sharedContainerVisibility() async throws {
        let container = try makeContainer()
        let writer = SwiftDataConfirmedDeletedStore(container: container)
        let reader = SwiftDataConfirmedDeletedStore(container: container)
        try await writer.union(cks("A", "B"))
        #expect(try await reader.snapshot() == cks("A", "B"))
    }
}
