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

    @Test("union writes and round-trips, carrying the supplied timestamp")
    func unionRoundTrips() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileConfirmedDeletedStore(path: path)
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_000_500)
        try await store.union(cks("A", "B"), at: t1)
        try await store.union(cks("B", "C"), at: t2)

        let snap = try await store.snapshot()
        #expect(Set(snap.keys) == cks("A", "B", "C"))
        // Timestamps are persisted to the same ISO-8601 precision they were
        // written at — treat "equal to the nearest second" as the contract
        // since the serializer rounds to ISO-8601 seconds.
        #expect(abs(snap[Checksum(base64: "A")]!.timeIntervalSince(t1)) < 1)
        #expect(abs(snap[Checksum(base64: "B")]!.timeIntervalSince(t1)) < 1)
        #expect(abs(snap[Checksum(base64: "C")]!.timeIntervalSince(t2)) < 1)
    }

    @Test("re-unioning an existing checksum keeps its original timestamp (first-write-wins)")
    func unionFirstWriteWins() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileConfirmedDeletedStore(path: path)
        let firstSeen = Date(timeIntervalSince1970: 1_700_000_000)
        let laterSeen = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.union(cks("A"), at: firstSeen)
        try await store.union(cks("A"), at: laterSeen)

        let snap = try await store.snapshot()
        #expect(abs(snap[Checksum(base64: "A")]!.timeIntervalSince(firstSeen)) < 1)
        // Explicitly *not* laterSeen — the quarantine clock stays stable.
        #expect(abs(snap[Checksum(base64: "A")]!.timeIntervalSince(laterSeen)) >= 1)
    }

    @Test("union with a subset of existing values is a no-op — preserves mtime")
    func unionSubsetNoOp() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileConfirmedDeletedStore(path: path)
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.union(cks("A", "B", "C"), at: t)
        let mtimeBefore = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date

        try await Task.sleep(nanoseconds: 20_000_000)
        try await store.union(cks("A"), at: Date(timeIntervalSince1970: 1_800_000_000))

        let mtimeAfter = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date
        #expect(mtimeBefore == mtimeAfter)
    }

    @Test("remove drops present entries and is a silent no-op on missing ones")
    func removeDropsEntries() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileConfirmedDeletedStore(path: path)
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.union(cks("A", "B", "C"), at: t)

        try await store.remove(cks("B", "ZZZ"))  // B present, ZZZ absent

        let snap = try await store.snapshot()
        #expect(Set(snap.keys) == cks("A", "C"))
    }

    @Test("remove with no overlap is a no-op — preserves mtime")
    func removeNoOpPreservesMtime() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileConfirmedDeletedStore(path: path)
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.union(cks("A"), at: t)
        let mtimeBefore = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date

        try await Task.sleep(nanoseconds: 20_000_000)
        try await store.remove(cks("Z"))

        let mtimeAfter = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date
        #expect(mtimeBefore == mtimeAfter)
    }

    @Test("legacy array-format file decodes every entry as .distantPast")
    func legacyArrayFormatDecodes() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        // Write the old on-disk format: a JSON array of base64 strings, no
        // timestamps. The store should read it as "everything past-quarantine".
        let legacy = Data(#"["A","B","C"]"#.utf8)
        try legacy.write(to: path)

        let store = JSONFileConfirmedDeletedStore(path: path)
        let snap = try await store.snapshot()
        #expect(Set(snap.keys) == cks("A", "B", "C"))
        for (_, date) in snap {
            #expect(date == .distantPast)
        }
    }

    @Test("survives across instances at the same path")
    func survivesAcrossInstances() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let first = JSONFileConfirmedDeletedStore(path: path)
        try await first.union(cks("X", "Y"), at: t)

        let second = JSONFileConfirmedDeletedStore(path: path)
        let snap = try await second.snapshot()
        #expect(Set(snap.keys) == cks("X", "Y"))
    }
}
