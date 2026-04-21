import Foundation
import Testing
@testable import CairnCore

@Suite("DeletionJournal")
struct DeletionJournalTests {

    private func tempPath() -> URL {
        let name = "journal-test-\(UUID().uuidString).jsonl"
        return URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: name)
    }

    @Test("appends and reads back entries in order")
    func appendAndRead() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let journal = DeletionJournal(path: path)
        try await journal.append(.init(runId: "r1", event: .runStarted(dryRun: true, candidateCount: 3, assetsInPurview: 100)))
        try await journal.append(.init(runId: "r1", event: .runCompleted(deletedCount: 0)))

        let entries = try await journal.readAll()
        #expect(entries.count == 2)
        #expect(entries[0].runId == "r1")
        if case .runStarted(let dry, let count, let purview) = entries[0].event {
            #expect(dry == true && count == 3 && purview == 100)
        } else {
            Issue.record("first entry was not runStarted")
        }
    }

    @Test("file is created if it doesn't exist")
    func createsFileIfMissing() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        #expect(!FileManager.default.fileExists(atPath: path.path))
        let journal = DeletionJournal(path: path)
        try await journal.append(.init(runId: "r1", event: .runAborted(reason: "test")))
        #expect(FileManager.default.fileExists(atPath: path.path))
    }

    @Test("empty file reads back as empty list")
    func emptyReadsEmpty() async throws {
        let path = tempPath()
        let journal = DeletionJournal(path: path)
        let entries = try await journal.readAll()
        #expect(entries.isEmpty)
    }

    @Test("planningTrash records every candidate's checksum and live-photo link")
    func planningRecordsTargets() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let journal = DeletionJournal(path: path)
        let targets = [
            JournalEntry.TrashTarget(assetId: "a1", checksum: "ck1", livePhotoVideoId: "v1"),
            JournalEntry.TrashTarget(assetId: "a2", checksum: "ck2", livePhotoVideoId: nil),
        ]
        try await journal.append(.init(runId: "r1", event: .planningTrash(targets: targets)))

        let entries = try await journal.readAll()
        if case .planningTrash(let read) = entries[0].event {
            #expect(read == targets)
        } else {
            Issue.record("expected planningTrash event")
        }
    }
}
