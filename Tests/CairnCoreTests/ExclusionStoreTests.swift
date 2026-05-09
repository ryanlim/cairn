import Foundation
import Testing
@testable import CairnCore

@Suite("JSONFileExclusionStore")
struct JSONFileExclusionStoreTests {

    private func tempPath() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "exclusions-\(UUID().uuidString).json")
    }

    private func ck(_ value: String) -> Checksum {
        Checksum(base64: value)
    }

    private func meta(
        _ addedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        runId: String? = nil,
        reason: String? = nil
    ) -> ExclusionMetadata {
        ExclusionMetadata(addedAt: addedAt, fromRunId: runId, reason: reason)
    }

    @Test("missing file reads as empty")
    func missingReadsEmpty() async throws {
        let store = JSONFileExclusionStore(path: tempPath())
        #expect(try await store.snapshot().isEmpty)
    }

    @Test("insert + snapshot roundtrip preserves metadata exactly")
    func insertSnapshotRoundtrip() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileExclusionStore(path: path)
        let a = meta(Date(timeIntervalSince1970: 1_700_000_000), runId: "run-A", reason: "wedding photo")
        let b = meta(Date(timeIntervalSince1970: 1_700_000_100), runId: nil, reason: nil)

        try await store.insert([
            ck("AAA"): a,
            ck("BBB"): b,
        ])

        let snap = try await store.snapshot()
        #expect(snap.count == 2)
        #expect(snap[ck("AAA")] == a)
        #expect(snap[ck("BBB")] == b)
    }

    @Test("isExcluded returns true for inserted checksums, false for others")
    func isExcludedReflectsInserts() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileExclusionStore(path: path)
        try await store.insert([ck("AAA"): meta()])

        #expect(try await store.isExcluded(ck("AAA")) == true)
        #expect(try await store.isExcluded(ck("BBB")) == false)
    }

    @Test("remove is a no-op for checksums not present")
    func removeMissingIsNoop() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileExclusionStore(path: path)
        try await store.insert([ck("AAA"): meta()])
        // No file write should happen — bytes should stay byte-for-byte
        // identical. Comparing bytes is more direct than the prior
        // mtime + Task.sleep shape, which depended on APFS mtime
        // granularity and could flake on busy CI runners.
        let bytesBefore = try Data(contentsOf: path)

        try await store.remove([ck("ZZZ")])

        let bytesAfter = try Data(contentsOf: path)
        #expect(bytesBefore == bytesAfter)
        #expect(try await store.snapshot().count == 1)
    }

    @Test("remove drops present checksums")
    func removePresentDrops() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileExclusionStore(path: path)
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

    @Test("a fresh store survives across instances as long as the path is the same")
    func survivesAcrossInstances() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let first = JSONFileExclusionStore(path: path)
        let m = meta(Date(timeIntervalSince1970: 1_700_000_500), runId: "run-X", reason: "baby's first photo")
        try await first.insert([ck("X"): m, ck("Y"): meta()])

        let second = JSONFileExclusionStore(path: path)
        let snap = try await second.snapshot()
        #expect(snap.count == 2)
        #expect(snap[ck("X")] == m)
    }

    @Test("re-inserting an existing checksum replaces metadata (last-writer-wins)")
    func reinsertReplacesMetadata() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileExclusionStore(path: path)
        let old = meta(Date(timeIntervalSince1970: 1_000_000_000), runId: "old-run", reason: "old reason")
        let new = meta(Date(timeIntervalSince1970: 2_000_000_000), runId: "new-run", reason: "new reason")

        try await store.insert([ck("AAA"): old])
        try await store.insert([ck("AAA"): new])

        let snap = try await store.snapshot()
        #expect(snap.count == 1)
        #expect(snap[ck("AAA")] == new)
    }
}
