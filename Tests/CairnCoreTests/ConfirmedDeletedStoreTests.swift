import Foundation
import Testing
@testable import CairnCore

@Suite("JSONFileConfirmedDeletedStore")
struct JSONFileConfirmedDeletedStoreTests {

    private func tempPath() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "confirmed-\(UUID().uuidString).json")
    }

    private func cks(_ values: String...) -> Set<Checksum> {
        Set(values.map { Checksum(base64: $0) })
    }

    @Test("missing file reads as empty")
    func missingReadsEmpty() async throws {
        let store = JSONFileConfirmedDeletedStore(path: tempPath())
        #expect(try await store.snapshot().isEmpty)
    }

    @Test("union writes and round-trips")
    func unionRoundTrips() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileConfirmedDeletedStore(path: path)
        try await store.union(cks("A", "B"))
        try await store.union(cks("B", "C"))
        #expect(try await store.snapshot() == cks("A", "B", "C"))
    }

    @Test("union with a subset of existing values is a no-op — preserves mtime")
    func unionSubsetNoOp() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileConfirmedDeletedStore(path: path)
        try await store.union(cks("A", "B", "C"))
        let mtimeBefore = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date

        try await Task.sleep(nanoseconds: 20_000_000)
        try await store.union(cks("A"))

        let mtimeAfter = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date
        #expect(mtimeBefore == mtimeAfter)
    }

    @Test("survives across instances at the same path")
    func survivesAcrossInstances() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let first = JSONFileConfirmedDeletedStore(path: path)
        try await first.union(cks("X", "Y"))

        let second = JSONFileConfirmedDeletedStore(path: path)
        #expect(try await second.snapshot() == cks("X", "Y"))
    }
}
