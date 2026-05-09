import Foundation
import Testing
@testable import CairnCore

@Suite("JSONFileObservedStore")
struct JSONFileObservedStoreTests {

    private func tempPath() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "observed-\(UUID().uuidString).json")
    }

    private func cks(_ values: String...) -> Set<Checksum> {
        Set(values.map { Checksum(base64: $0) })
    }

    @Test("missing file reads as empty")
    func missingReadsEmpty() async throws {
        let store = JSONFileObservedStore(path: tempPath())
        #expect(try await store.snapshot().isEmpty)
    }

    @Test("union writes and round-trips")
    func unionRoundTrips() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileObservedStore(path: path)
        try await store.union(cks("A", "B"))
        try await store.union(cks("B", "C"))
        #expect(try await store.snapshot() == cks("A", "B", "C"))
    }

    @Test("union with a subset of existing values is a no-op — no needless disk write")
    func unionSubsetNoOp() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileObservedStore(path: path)
        try await store.union(cks("A", "B", "C"))
        let bytesBefore = try Data(contentsOf: path)

        try await store.union(cks("A"))

        // Compare bytes rather than mtime — direct check of "the
        // no-op didn't write" without depending on APFS mtime
        // granularity or Task.sleep timing.
        let bytesAfter = try Data(contentsOf: path)
        #expect(bytesBefore == bytesAfter)
    }

    @Test("a fresh store survives across instances as long as the path is the same")
    func survivesAcrossInstances() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let first = JSONFileObservedStore(path: path)
        try await first.union(cks("X", "Y"))

        let second = JSONFileObservedStore(path: path)
        #expect(try await second.snapshot() == cks("X", "Y"))
    }

    // MARK: - Scope-aware tag API

    @Test("recordObserved writes album tags; snapshotWithTags reads them")
    func recordObservedWritesTags() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileObservedStore(path: path)
        try await store.recordObserved([
            Checksum(base64: "A"): ["album-1", "album-2"],
            Checksum(base64: "B"): ["album-1"],
        ])
        let snap = try await store.snapshotWithTags()
        #expect(snap[Checksum(base64: "A")] == ["album-1", "album-2"])
        #expect(snap[Checksum(base64: "B")] == ["album-1"])
        #expect(snap.count == 2)
    }

    @Test("recordObserved replaces tags rather than merging — moves between albums work")
    func recordObservedReplacesTags() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileObservedStore(path: path)
        try await store.recordObserved([Checksum(base64: "A"): ["album-1"]])
        try await store.recordObserved([Checksum(base64: "A"): ["album-2"]])
        // Tags from album-1 are gone — moves between albums correctly
        // surface in the new tag set rather than accumulating.
        let snap = try await store.snapshotWithTags()
        #expect(snap[Checksum(base64: "A")] == ["album-2"])
    }

    @Test("setTags bulk-replaces tags on a set of checksums; missing checksums are no-ops")
    func setTagsBulkReplaces() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileObservedStore(path: path)
        try await store.recordObserved([
            Checksum(base64: "A"): ["old"],
            Checksum(base64: "B"): ["old"],
        ])
        // setTags only operates on existing checksums — "C" is silently
        // skipped because the store has no entry for it (use
        // recordObserved to insert).
        try await store.setTags(for: cks("A", "B", "C"), tags: ["new"])
        let snap = try await store.snapshotWithTags()
        #expect(snap[Checksum(base64: "A")] == ["new"])
        #expect(snap[Checksum(base64: "B")] == ["new"])
        #expect(snap[Checksum(base64: "C")] == nil)
    }

    @Test("legacy union() preserves existing tags; new entries get empty tags")
    func unionPreservesTagsAndAddsEmpty() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileObservedStore(path: path)
        try await store.recordObserved([Checksum(base64: "A"): ["album-1"]])
        try await store.union(cks("A", "B"))
        let snap = try await store.snapshotWithTags()
        #expect(snap[Checksum(base64: "A")] == ["album-1"])    // preserved
        #expect(snap[Checksum(base64: "B")] == [])              // new = empty
    }

    @Test("legacy v1 [String] JSON loads with empty tags — forward-compatible")
    func legacyV1ArrayShapeMigrates() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        // Hand-write a v1 file (flat array of base64s) — what cairn 0.1.x
        // would have written. Loading should treat each entry as having
        // empty tags; no throw.
        let v1JSON = #"["A","B","C"]"#
        try Data(v1JSON.utf8).write(to: path)

        let store = JSONFileObservedStore(path: path)
        let snap = try await store.snapshotWithTags()
        #expect(snap.count == 3)
        for tags in snap.values {
            #expect(tags.isEmpty)
        }

        // After a write, the file is upgraded to v2 (object) shape so
        // subsequent reads round-trip through the v2 path.
        try await store.recordObserved([Checksum(base64: "A"): ["X"]])
        let json = try String(contentsOf: path, encoding: .utf8)
        #expect(json.contains("{") || json.hasPrefix("{")) // v2 is object-shaped
    }

    @Test("snapshotWithTags is consistent with snapshot — same checksum set")
    func snapshotConsistentWithTaggedSnapshot() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileObservedStore(path: path)
        try await store.recordObserved([
            Checksum(base64: "A"): ["x"],
            Checksum(base64: "B"): [],
        ])
        let plain = try await store.snapshot()
        let tagged = try await store.snapshotWithTags()
        #expect(plain == Set(tagged.keys))
    }
}
