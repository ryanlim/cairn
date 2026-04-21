import Foundation
import Testing
@testable import CairnCore

@Suite("RestoreOrchestrator")
struct RestoreOrchestratorTests {

    private func tempJournal() -> (DeletionJournal, URL) {
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "restore-\(UUID().uuidString).jsonl")
        return (DeletionJournal(path: path), path)
    }

    /// Seeds a journal with a complete successful trash run for `runId` against `assetIds`.
    private func seedTrashRun(_ journal: DeletionJournal, runId: String, assetIds: [String]) async throws {
        try await journal.append(.init(runId: runId, event: .runStarted(dryRun: false, candidateCount: assetIds.count, assetsInPurview: 100)))
        try await journal.append(.init(runId: runId, event: .planningTrash(targets: assetIds.map {
            JournalEntry.TrashTarget(assetId: $0, checksum: "ck-\($0)", livePhotoVideoId: nil)
        })))
        try await journal.append(.init(runId: runId, event: .tagApplied(tagId: "t1", tagValue: "cairn/\(runId)", assetIds: assetIds)))
        try await journal.append(.init(runId: runId, event: .trashSucceeded(assetIds: assetIds)))
        try await journal.append(.init(runId: runId, event: .runCompleted(deletedCount: assetIds.count)))
    }

    @Test("happy path: pulls asset IDs from journal's trashSucceeded event and calls restore")
    func happyPath() async throws {
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }
        try await seedTrashRun(journal, runId: "R1", assetIds: ["a1", "a2", "a3"])

        let writer = FakeWriter()
        let orch = RestoreOrchestrator(writer: writer, journal: journal)
        let summary = try await orch.restore(fromRunId: "R1")

        #expect(summary.restoredAssetIds == ["a1", "a2", "a3"])
        #expect(await writer.restoredBatches == [["a1", "a2", "a3"]])

        let entries = try await journal.readAll()
        #expect(entries.contains { if case .restoreStarted = $0.event { return true } else { return false } })
        #expect(entries.contains { if case .restoreSucceeded = $0.event { return true } else { return false } })
    }

    @Test("throws when the run ID has no journal entries")
    func missingRunThrows() async throws {
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }

        let writer = FakeWriter()
        let orch = RestoreOrchestrator(writer: writer, journal: journal)

        await #expect(throws: RestoreError.self) {
            _ = try await orch.restore(fromRunId: "GHOST")
        }
    }

    @Test("throws when the run exists but never had a trashSucceeded event (dry-run / aborted)")
    func noTrashSucceededThrows() async throws {
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }

        try await journal.append(.init(runId: "DRY", event: .runStarted(dryRun: true, candidateCount: 3, assetsInPurview: 100)))
        try await journal.append(.init(runId: "DRY", event: .runCompleted(deletedCount: 0)))

        let writer = FakeWriter()
        let orch = RestoreOrchestrator(writer: writer, journal: journal)
        await #expect(throws: RestoreError.self) {
            _ = try await orch.restore(fromRunId: "DRY")
        }
        #expect(await writer.restoredBatches.isEmpty)
    }

    @Test("API failure: journals restoreFailed and rethrows")
    func apiFailureJournaledAndRethrown() async throws {
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }
        try await seedTrashRun(journal, runId: "R-FAIL", assetIds: ["a1"])

        let writer = FakeWriter()
        await writer.setFailRestore(FakeError(message: "server down"))
        let orch = RestoreOrchestrator(writer: writer, journal: journal)

        await #expect(throws: FakeError.self) {
            _ = try await orch.restore(fromRunId: "R-FAIL")
        }

        let entries = try await journal.readAll()
        #expect(entries.contains { if case .restoreFailed = $0.event { return true } else { return false } })
        #expect(!entries.contains { if case .restoreSucceeded = $0.event { return true } else { return false } })
    }

    @Test("multiple runs in the same journal: restore only touches the requested run's assets")
    func multipleRunsIsolation() async throws {
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }
        try await seedTrashRun(journal, runId: "R1", assetIds: ["r1-a", "r1-b"])
        try await seedTrashRun(journal, runId: "R2", assetIds: ["r2-x", "r2-y", "r2-z"])

        let writer = FakeWriter()
        let orch = RestoreOrchestrator(writer: writer, journal: journal)
        _ = try await orch.restore(fromRunId: "R2")

        #expect(await writer.restoredBatches == [["r2-x", "r2-y", "r2-z"]])
    }
}
