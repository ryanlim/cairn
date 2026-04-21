import Foundation
import Testing
@testable import CairnCore

@Suite("JSONFileEverSeenStore")
struct JSONFileEverSeenStoreTests {

    private func tempPath() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "everseen-\(UUID().uuidString).json")
    }

    private func cks(_ values: String...) -> Set<Checksum> {
        Set(values.map { Checksum(base64: $0) })
    }

    @Test("missing file reads as empty")
    func missingReadsEmpty() async throws {
        let store = JSONFileEverSeenStore(path: tempPath())
        #expect(try await store.snapshot().isEmpty)
    }

    @Test("union writes and round-trips")
    func unionRoundTrips() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileEverSeenStore(path: path)
        try await store.union(cks("A", "B"))
        try await store.union(cks("B", "C"))
        #expect(try await store.snapshot() == cks("A", "B", "C"))
    }

    @Test("union with a subset of existing values is a no-op — no needless disk write")
    func unionSubsetNoOp() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileEverSeenStore(path: path)
        try await store.union(cks("A", "B", "C"))
        let mtimeBefore = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date

        // Tiny sleep so mtime would change if a write occurred.
        try await Task.sleep(nanoseconds: 20_000_000)
        try await store.union(cks("A"))

        let mtimeAfter = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date
        #expect(mtimeBefore == mtimeAfter)
    }

    @Test("a fresh store survives across instances as long as the path is the same")
    func survivesAcrossInstances() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let first = JSONFileEverSeenStore(path: path)
        try await first.union(cks("X", "Y"))

        let second = JSONFileEverSeenStore(path: path)
        #expect(try await second.snapshot() == cks("X", "Y"))
    }
}
