import Foundation
import Testing
@testable import CairnCore

@Suite("JSONFileEditRetirementStore")
struct JSONFileEditRetirementStoreTests {

    private func tempPath() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "edit-retire-\(UUID().uuidString).json")
    }

    private func cks(_ values: String...) -> Set<Checksum> {
        Set(values.map { Checksum(base64: $0) })
    }

    @Test("missing file reads as empty for any id and snapshot()")
    func missingReadsEmpty() async throws {
        let store = JSONFileEditRetirementStore(path: tempPath())
        #expect(try await store.firstObserved(for: "id-X") == [])
        #expect(try await store.snapshot().isEmpty)
    }

    @Test("recordFirstObserved + read round-trips the full set")
    func recordRoundTrip() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileEditRetirementStore(path: path)
        // Live Photos: still + motion video both anchor the id.
        try await store.recordFirstObserved(cks("STILL", "MOTION"), for: "id-live")

        #expect(try await store.firstObserved(for: "id-live") == cks("STILL", "MOTION"))
    }

    @Test("recordFirstObserved is first-write-wins — a second call cannot overwrite")
    func firstWriteWins() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileEditRetirementStore(path: path)
        try await store.recordFirstObserved(cks("ORIGINAL"), for: "id-1")
        // Same id, different (post-edit) checksums: must NOT overwrite.
        // This is the load-bearing rule. If a later observation could
        // stomp the original, edited photos lose their anchor.
        try await store.recordFirstObserved(cks("EDITED"), for: "id-1")

        #expect(try await store.firstObserved(for: "id-1") == cks("ORIGINAL"))
    }

    @Test("empty checksum set is a no-op — does not seed an empty entry")
    func emptyRecordIsNoOp() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileEditRetirementStore(path: path)
        try await store.recordFirstObserved([], for: "id-1")
        #expect(try await store.firstObserved(for: "id-1") == [])
        // A subsequent real record still writes — empty was nothing,
        // not "claim the slot."
        try await store.recordFirstObserved(cks("REAL"), for: "id-1")
        #expect(try await store.firstObserved(for: "id-1") == cks("REAL"))
    }

    @Test("snapshot returns every id with its full checksum set")
    func snapshotContents() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileEditRetirementStore(path: path)
        try await store.recordFirstObserved(cks("A"), for: "id-1")
        try await store.recordFirstObserved(cks("B", "C"), for: "id-2")

        let snap = try await store.snapshot()
        #expect(snap.count == 2)
        #expect(snap["id-1"] == cks("A"))
        #expect(snap["id-2"] == cks("B", "C"))
    }

    @Test("remove drops the requested ids and is silent on absent ones")
    func removeDropsEntries() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileEditRetirementStore(path: path)
        try await store.recordFirstObserved(cks("A"), for: "id-1")
        try await store.recordFirstObserved(cks("B"), for: "id-2")
        try await store.recordFirstObserved(cks("C"), for: "id-3")

        try await store.remove(for: ["id-2", "id-NOT-PRESENT"])

        #expect(try await store.firstObserved(for: "id-1") == cks("A"))
        #expect(try await store.firstObserved(for: "id-2") == [])
        #expect(try await store.firstObserved(for: "id-3") == cks("C"))
    }

    @Test("clear wipes every entry and survives a fresh instance")
    func clearWipes() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileEditRetirementStore(path: path)
        try await store.recordFirstObserved(cks("A"), for: "id-1")
        try await store.recordFirstObserved(cks("B"), for: "id-2")

        try await store.clear()
        #expect(try await store.snapshot().isEmpty)

        // Fresh instance at the same path also sees empty — clear was
        // durable, not just in-memory.
        let reopened = JSONFileEditRetirementStore(path: path)
        #expect(try await reopened.snapshot().isEmpty)
    }

    @Test("survives across instances at the same path")
    func survivesAcrossInstances() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let writer = JSONFileEditRetirementStore(path: path)
        try await writer.recordFirstObserved(cks("X", "Y"), for: "id-shared")

        let reader = JSONFileEditRetirementStore(path: path)
        #expect(try await reader.firstObserved(for: "id-shared") == cks("X", "Y"))
    }
}
