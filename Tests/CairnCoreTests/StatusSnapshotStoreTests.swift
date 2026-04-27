import Foundation
import Testing
@testable import CairnCore

@Suite("JSONFileStatusSnapshotStore")
struct JSONFileStatusSnapshotStoreTests {

    private func tempPath() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "status-snapshot-\(UUID().uuidString).json")
    }

    private func sample(_ computedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> StatusSnapshot {
        StatusSnapshot(
            deleteCandidatesCount: 14,
            matchedCount: 4_102,
            pendingReviewCount: 3,
            inferredOrphanCount: 1,
            computedAt: computedAt
        )
    }

    @Test("missing file reads as nil")
    func missingReadsNil() async throws {
        let store = JSONFileStatusSnapshotStore(path: tempPath())
        #expect(try await store.load() == nil)
    }

    @Test("save + load round-trips every field")
    func saveLoadRoundTrip() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileStatusSnapshotStore(path: path)
        let snap = sample()
        try await store.save(snap)
        let loaded = try await store.load()
        #expect(loaded != nil)
        #expect(loaded?.deleteCandidatesCount == 14)
        #expect(loaded?.matchedCount == 4_102)
        #expect(loaded?.pendingReviewCount == 3)
        #expect(loaded?.inferredOrphanCount == 1)
        // ISO-8601 round-trip rounds to seconds; tolerate < 1s drift.
        if let computedAt = loaded?.computedAt {
            #expect(abs(computedAt.timeIntervalSince(snap.computedAt)) < 1)
        }
    }

    @Test("save overwrites — load returns the most recent value")
    func saveOverwrites() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileStatusSnapshotStore(path: path)
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
        #expect(loaded?.pendingReviewCount == 0)
        #expect(loaded?.inferredOrphanCount == 0)
    }

    @Test("clear deletes the file — subsequent load returns nil")
    func clearDeletes() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileStatusSnapshotStore(path: path)
        try await store.save(sample())
        #expect(try await store.load() != nil)

        try await store.clear()
        #expect(try await store.load() == nil)
    }

    @Test("clear is a no-op when nothing has been saved")
    func clearNoOpOnEmpty() async throws {
        let store = JSONFileStatusSnapshotStore(path: tempPath())
        // Should not throw when the file doesn't exist.
        try await store.clear()
        #expect(try await store.load() == nil)
    }

    @Test("survives across instances at the same path")
    func survivesAcrossInstances() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let writer = JSONFileStatusSnapshotStore(path: path)
        try await writer.save(sample())

        let reader = JSONFileStatusSnapshotStore(path: path)
        let loaded = try await reader.load()
        #expect(loaded?.deleteCandidatesCount == 14)
        #expect(loaded?.matchedCount == 4_102)
    }
}
