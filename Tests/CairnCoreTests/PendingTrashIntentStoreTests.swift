import Foundation
import Testing
@testable import CairnCore

@Suite("JSONFilePendingTrashIntentStore")
struct JSONFilePendingTrashIntentStoreTests {

    private func tempPath() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "pending-\(UUID().uuidString).json")
    }

    private func asset(_ id: String, ck: String) -> ServerAsset {
        ServerAsset(
            id: id,
            checksum: Checksum(base64: ck),
            livePhotoVideoId: nil,
            isTrashed: false,
            originalFileName: "\(id).jpg",
            fileCreatedAt: nil
        )
    }

    private func intent(
        runId: String = "run-X",
        assets: [ServerAsset]
    ) -> PendingTrashIntent {
        PendingTrashIntent(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            runId: runId,
            assets: assets,
            assetsInPurview: assets.count
        )
    }

    @Test("missing file reads as empty")
    func missingReadsEmpty() async throws {
        let store = JSONFilePendingTrashIntentStore(path: tempPath())
        #expect(try await store.snapshot().isEmpty)
        #expect(try await store.count() == 0)
    }

    @Test("enqueue + snapshot preserves intent shape including assets")
    func enqueueRoundtrip() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFilePendingTrashIntentStore(path: path)
        let i = intent(assets: [asset("A", ck: "ck-A"), asset("B", ck: "ck-B")])
        try await store.enqueue(i)

        let snap = try await store.snapshot()
        #expect(snap.count == 1)
        #expect(snap.first?.id == i.id)
        #expect(snap.first?.runId == "run-X")
        #expect(snap.first?.assets.map(\.id) == ["A", "B"])
        #expect(snap.first?.assets.map(\.checksum.base64) == ["ck-A", "ck-B"])
    }

    @Test("snapshot is sorted by createdAt ascending")
    func snapshotSorted() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFilePendingTrashIntentStore(path: path)
        let earlier = PendingTrashIntent(
            createdAt: Date(timeIntervalSince1970: 1_000),
            runId: "earlier",
            assets: [asset("A", ck: "ck-A")],
            assetsInPurview: 1
        )
        let later = PendingTrashIntent(
            createdAt: Date(timeIntervalSince1970: 2_000),
            runId: "later",
            assets: [asset("B", ck: "ck-B")],
            assetsInPurview: 1
        )
        // Enqueue in reverse-chronological order to confirm storage sorts.
        try await store.enqueue(later)
        try await store.enqueue(earlier)

        let snap = try await store.snapshot()
        #expect(snap.map(\.runId) == ["earlier", "later"])
    }

    @Test("update mutates lastAttemptedAt / attemptCount / lastError; missing id is silent no-op")
    func updateApplies() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFilePendingTrashIntentStore(path: path)
        let i = intent(assets: [asset("A", ck: "ck-A")])
        try await store.enqueue(i)

        let stamp = Date(timeIntervalSince1970: 1_700_001_000)
        try await store.update(i.id, lastAttemptedAt: stamp, attemptCount: 2, lastError: "HTTP 502")

        let snap = try await store.snapshot()
        #expect(snap.first?.lastAttemptedAt == stamp)
        #expect(snap.first?.attemptCount == 2)
        #expect(snap.first?.lastError == "HTTP 502")

        // Unknown id: silent no-op.
        try await store.update(UUID(), lastAttemptedAt: stamp, attemptCount: 99, lastError: "ignored")
        let snap2 = try await store.snapshot()
        #expect(snap2.first?.attemptCount == 2)
    }

    @Test("remove(_:) drops by id; missing id is silent no-op")
    func removeById() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFilePendingTrashIntentStore(path: path)
        let a = intent(runId: "A", assets: [asset("A1", ck: "ck-A1")])
        let b = intent(runId: "B", assets: [asset("B1", ck: "ck-B1")])
        try await store.enqueue(a)
        try await store.enqueue(b)

        try await store.remove(a.id)
        let snap = try await store.snapshot()
        #expect(snap.map(\.runId) == ["B"])

        // Removing a non-existent id is silent.
        try await store.remove(UUID())
        #expect(try await store.count() == 1)
    }

    @Test("remove(matchingRunId:) drops every intent sharing the runId")
    func removeByRunId() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFilePendingTrashIntentStore(path: path)
        try await store.enqueue(intent(runId: "shared", assets: [asset("A", ck: "ck-A")]))
        try await store.enqueue(intent(runId: "shared", assets: [asset("B", ck: "ck-B")]))
        try await store.enqueue(intent(runId: "other", assets: [asset("C", ck: "ck-C")]))

        try await store.remove(matchingRunId: "shared")
        let snap = try await store.snapshot()
        #expect(snap.count == 1)
        #expect(snap.first?.runId == "other")
    }

    @Test("removeIntents(containingAnyOf:) drops the whole intent if any of its checksums match")
    func removeByChecksumIntersection() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFilePendingTrashIntentStore(path: path)
        // Intent A has two assets. If we exclude one of those checksums,
        // the entire intent drops — partial trashes don't persist.
        let multi = intent(runId: "multi", assets: [
            asset("A1", ck: "ck-A1"),
            asset("A2", ck: "ck-A2"),
        ])
        let single = intent(runId: "single", assets: [asset("B1", ck: "ck-B1")])
        try await store.enqueue(multi)
        try await store.enqueue(single)

        try await store.removeIntents(containingAnyOf: [Checksum(base64: "ck-A2")])

        let snap = try await store.snapshot()
        #expect(snap.map(\.runId) == ["single"])
    }

    @Test("removeIntents(containingAnyOf:) is a no-op for empty / non-matching sets")
    func removeByChecksumNoOp() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFilePendingTrashIntentStore(path: path)
        try await store.enqueue(intent(assets: [asset("A", ck: "ck-A")]))

        try await store.removeIntents(containingAnyOf: [])
        try await store.removeIntents(containingAnyOf: [Checksum(base64: "ck-NOTHING")])

        #expect(try await store.count() == 1)
    }
}
