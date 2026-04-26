import Foundation
import Testing
@testable import CairnCore

@Suite("JSONFileDeletionSourceStore")
struct JSONFileDeletionSourceStoreTests {

    private func tempPath() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "deletion-source-\(UUID().uuidString).json")
    }

    private func ck(_ value: String) -> Checksum {
        Checksum(base64: value)
    }

    @Test("missing file reads as empty")
    func missingReadsEmpty() async throws {
        let store = JSONFileDeletionSourceStore(path: tempPath())
        #expect(try await store.snapshot().isEmpty)
    }

    @Test("record + snapshot round-trips")
    func recordRoundTrips() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileDeletionSourceStore(path: path)
        try await store.record([ck("A"): "id-1", ck("B"): "id-2"])

        let snap = try await store.snapshot()
        #expect(snap.count == 2)
        #expect(snap[ck("A")] == "id-1")
        #expect(snap[ck("B")] == "id-2")
    }

    @Test("record overwrites existing entries (last write wins)")
    func recordOverwrites() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileDeletionSourceStore(path: path)
        try await store.record([ck("A"): "id-old"])
        try await store.record([ck("A"): "id-new"])

        let snap = try await store.snapshot()
        #expect(snap[ck("A")] == "id-new")
    }

    @Test("re-recording an unchanged entry is a no-op — preserves mtime")
    func recordIdempotentNoOp() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileDeletionSourceStore(path: path)
        try await store.record([ck("A"): "id-1", ck("B"): "id-2"])
        let mtimeBefore = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date

        try await Task.sleep(nanoseconds: 20_000_000)
        try await store.record([ck("A"): "id-1", ck("B"): "id-2"])

        let mtimeAfter = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date
        #expect(mtimeBefore == mtimeAfter)
    }

    @Test("remove drops present entries and is a silent no-op on missing ones")
    func removeDropsEntries() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileDeletionSourceStore(path: path)
        try await store.record([ck("A"): "id-1", ck("B"): "id-2", ck("C"): "id-3"])

        try await store.remove([ck("B"), ck("ZZZ")])

        let snap = try await store.snapshot()
        #expect(Set(snap.keys) == Set([ck("A"), ck("C")]))
    }

    @Test("clear wipes every entry")
    func clearWipes() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileDeletionSourceStore(path: path)
        try await store.record([ck("A"): "id-1", ck("B"): "id-2"])
        try await store.clear()

        #expect(try await store.snapshot().isEmpty)
    }

    @Test("survives across instances at the same path")
    func survivesAcrossInstances() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let first = JSONFileDeletionSourceStore(path: path)
        try await first.record([ck("X"): "id-X", ck("Y"): "id-Y"])

        let second = JSONFileDeletionSourceStore(path: path)
        let snap = try await second.snapshot()
        #expect(snap[ck("X")] == "id-X")
        #expect(snap[ck("Y")] == "id-Y")
    }
}
