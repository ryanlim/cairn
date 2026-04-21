import Foundation
import Testing
@testable import CairnCore

@Suite("TrashOrchestrator")
struct TrashOrchestratorTests {

    private func tempJournal() -> (DeletionJournal, URL) {
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "orch-\(UUID().uuidString).jsonl")
        return (DeletionJournal(path: path), path)
    }

    private func asset(_ id: String, _ checksum: String, livePhotoVideoId: String? = nil) -> ServerAsset {
        ServerAsset(id: id, checksum: Checksum(base64: checksum), livePhotoVideoId: livePhotoVideoId)
    }

    @Test("happy path: tag → trash, journal records every step in order")
    func happyPath() async throws {
        let writer = FakeWriter()
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }

        let orch = TrashOrchestrator(writer: writer, journal: journal)
        let summary = try await orch.run(
            runId: "RUN-1",
            candidates: [asset("a1", "ck1"), asset("a2", "ck2")],
            assetsInPurview: 100,
            dryRun: false
        )

        #expect(summary.trashedAssetIds == ["a1", "a2"])
        #expect(summary.breadcrumbTag?.value == "cairn/RUN-1")
        #expect(await writer.upsertedTagValues == ["cairn/RUN-1"])
        #expect(await writer.trashedBatches == [["a1", "a2"]])

        let entries = try await journal.readAll()
        let kinds = entries.map { String(describing: $0.event).prefix(20) }
        #expect(kinds.contains(where: { $0.hasPrefix("runStarted") }))
        #expect(kinds.contains(where: { $0.hasPrefix("planningTrash") }))
        #expect(kinds.contains(where: { $0.hasPrefix("tagApplied") }))
        #expect(kinds.contains(where: { $0.hasPrefix("trashSucceeded") }))
        #expect(kinds.contains(where: { $0.hasPrefix("runCompleted") }))
    }

    @Test("Live Photo: linked motion video UUID is included in the trash batch")
    func livePhotoVideoIncluded() async throws {
        let writer = FakeWriter()
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }

        let orch = TrashOrchestrator(writer: writer, journal: journal)
        _ = try await orch.run(
            runId: "RUN-LIVE",
            candidates: [asset("still-1", "ck1", livePhotoVideoId: "video-1")],
            assetsInPurview: 50,
            dryRun: false
        )

        let trashed = await writer.trashedBatches[0]
        #expect(trashed.sorted() == ["still-1", "video-1"])
    }

    @Test("dry-run journals plan but never calls writer")
    func dryRunIsInert() async throws {
        let writer = FakeWriter()
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }

        let orch = TrashOrchestrator(writer: writer, journal: journal)
        let summary = try await orch.run(
            runId: "DRY",
            candidates: [asset("a1", "ck1")],
            assetsInPurview: 10,
            dryRun: true
        )

        #expect(summary.trashedAssetIds.isEmpty)
        #expect(await writer.trashedBatches.isEmpty)
        #expect(await writer.taggedBatches.isEmpty)
        #expect(await writer.upsertedTagValues.isEmpty)

        let entries = try await journal.readAll()
        #expect(entries.contains { if case .planningTrash = $0.event { return true } else { return false } })
        #expect(!entries.contains { if case .tagApplied = $0.event { return true } else { return false } })
    }

    @Test("empty candidates: short-circuits with runStarted + runCompleted, no tag/trash calls")
    func emptyCandidatesShortCircuits() async throws {
        let writer = FakeWriter()
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }

        let orch = TrashOrchestrator(writer: writer, journal: journal)
        let summary = try await orch.run(runId: "EMPTY", candidates: [], assetsInPurview: 100, dryRun: false)

        #expect(summary.trashedAssetIds.isEmpty)
        #expect(await writer.upsertedTagValues.isEmpty)
        #expect(await writer.trashedBatches.isEmpty)
    }

    @Test("trash failure is journaled and rethrown — tag is still applied first")
    func trashFailureJournaledAndRethrown() async throws {
        let writer = FakeWriter()
        await writer.setFailTrash(FakeError(message: "boom"))
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }

        let orch = TrashOrchestrator(writer: writer, journal: journal)
        await #expect(throws: FakeError.self) {
            _ = try await orch.run(
                runId: "FAIL",
                candidates: [asset("a1", "ck1")],
                assetsInPurview: 10,
                dryRun: false
            )
        }

        #expect(await writer.upsertedTagValues.count == 1) // tag was created before delete attempt
        let entries = try await journal.readAll()
        #expect(entries.contains { if case .trashFailed = $0.event { return true } else { return false } })
        #expect(!entries.contains { if case .trashSucceeded = $0.event { return true } else { return false } })
    }
}
