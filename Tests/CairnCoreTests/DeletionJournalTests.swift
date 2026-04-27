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

    // MARK: - Wire compatibility for the Wave-2 schema bump

    /// The Wave-2 additions (`durationMs` on success events, `httpStatus`
    /// on failure events) added Optional associated values to existing
    /// enum cases. Swift's enum Codable synthesis for Optional associated
    /// values uses `decodeIfPresent`, so legacy journal rows — written
    /// before these fields existed — must still decode cleanly with the
    /// new fields surfacing as nil. If this regresses, every journal
    /// file written before the bump becomes silently undecodable and
    /// the user's run history disappears.
    @Test("legacy trashSucceeded row decodes without durationMs as nil")
    func legacyTrashSucceededDecodes() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        // Hand-written legacy row: no `durationMs` key. Mirrors the exact
        // shape Swift's auto-synthesis would have produced before the
        // schema bump (case-name discriminator → keyed payload).
        let legacy = #"""
        {"timestamp":"2026-04-21T17:57:15Z","runId":"r1","event":{"trashSucceeded":{"assetIds":["a","b"]}}}
        """#
        try (legacy + "\n").data(using: .utf8)!.write(to: path)

        let journal = DeletionJournal(path: path)
        let entries = try await journal.readAll()
        #expect(entries.count == 1)
        if case .trashSucceeded(let ids, let dur) = entries[0].event {
            #expect(ids == ["a", "b"])
            #expect(dur == nil)
        } else {
            Issue.record("expected trashSucceeded event")
        }
    }

    @Test("legacy trashFailed row decodes without httpStatus as nil")
    func legacyTrashFailedDecodes() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let legacy = #"""
        {"timestamp":"2026-04-21T17:57:15Z","runId":"r1","event":{"trashFailed":{"assetIds":["a"],"message":"server-500"}}}
        """#
        try (legacy + "\n").data(using: .utf8)!.write(to: path)

        let journal = DeletionJournal(path: path)
        let entries = try await journal.readAll()
        #expect(entries.count == 1)
        if case .trashFailed(let ids, let msg, let http) = entries[0].event {
            #expect(ids == ["a"])
            #expect(msg == "server-500")
            #expect(http == nil)
        } else {
            Issue.record("expected trashFailed event")
        }
    }

    @Test("new-format rows round-trip durationMs and httpStatus")
    func newFieldsRoundTrip() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let journal = DeletionJournal(path: path)
        try await journal.append(.init(runId: "r1", event: .trashSucceeded(assetIds: ["a"], durationMs: 1234)))
        try await journal.append(.init(runId: "r1", event: .trashFailed(assetIds: ["b"], message: "auth", httpStatus: 401)))
        try await journal.append(.init(runId: "r1", event: .restoreSucceeded(fromRunId: "r1", assetIds: ["a"], durationMs: 567)))
        try await journal.append(.init(runId: "r1", event: .restoreFailed(fromRunId: "r1", assetIds: ["a"], message: "boom", httpStatus: 500)))
        try await journal.append(.init(runId: "r1", event: .tagApplied(tagId: "t", tagValue: "cairn/v1/run/r1", assetIds: ["a"], durationMs: 89)))

        let entries = try await journal.readAll()
        if case .trashSucceeded(_, let dur) = entries[0].event { #expect(dur == 1234) } else { Issue.record("0") }
        if case .trashFailed(_, _, let http) = entries[1].event { #expect(http == 401) } else { Issue.record("1") }
        if case .restoreSucceeded(_, _, let dur) = entries[2].event { #expect(dur == 567) } else { Issue.record("2") }
        if case .restoreFailed(_, _, _, let http) = entries[3].event { #expect(http == 500) } else { Issue.record("3") }
        if case .tagApplied(_, _, _, let dur) = entries[4].event { #expect(dur == 89) } else { Issue.record("4") }
    }
}
