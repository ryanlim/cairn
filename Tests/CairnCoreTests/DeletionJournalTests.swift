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

    @Test("syncTransitions wire format pins JSON key to confirmedFromPhotoKit despite Swift rename")
    func syncTransitionsWireKeyPinned() throws {
        // After renaming the Swift identifier `confirmedFromPhotoKit` →
        // `confirmedFromChangeLog`, the JSON key on the wire must
        // remain `confirmedFromPhotoKit` so existing journal files keep
        // decoding. SE-0295 per-case nested CodingKeys
        // (SyncTransitionsCodingKeys) carries this.
        let entry = JournalEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            runId: "R1",
            event: .syncTransitions(
                editsProtected: 1,
                editsQuarantined: 2,
                confirmedFromChangeLog: 3,
                confirmedFromOrphanSweep: 4
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        let raw = String(data: data, encoding: .utf8)!
        #expect(raw.contains("\"confirmedFromPhotoKit\":3"))
        #expect(!raw.contains("confirmedFromChangeLog"))
    }

    @Test("legacy syncTransitions JSON with confirmedFromPhotoKit decodes into confirmedFromChangeLog")
    func syncTransitionsLegacyDecode() throws {
        // Decoding a journal row written before the rename — wire format
        // matches what the v1.0 install would have written.
        let json = """
        {"event":{"syncTransitions":{"confirmedFromOrphanSweep":4,"confirmedFromPhotoKit":3,"editsProtected":1,"editsQuarantined":2}},"runId":"R1","timestamp":"2023-11-14T22:13:20Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(JournalEntry.self, from: Data(json.utf8))
        guard case .syncTransitions(let ep, let eq, let ccl, let cos) = entry.event else {
            Issue.record("expected .syncTransitions")
            return
        }
        #expect(ep == 1)
        #expect(eq == 2)
        #expect(ccl == 3)
        #expect(cos == 4)
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

    // MARK: - Rotation / archive

    private func archiveURL(_ p: URL) -> URL {
        p.deletingPathExtension().appendingPathExtension("archive").appendingPathExtension(p.pathExtension)
    }

    private func syncRun(_ id: String, at ts: Date) -> JournalEntry {
        .init(timestamp: ts, runId: id, event: .syncCompleted(
            indexed: 0, candidates: 0, pendingReview: 0,
            deferredLarge: 0, deferredLargeBytes: 0, deferredTimeout: 0, elapsedMs: 1))
    }

    @Test("rotateIfNeeded is a no-op below the keep+slack threshold")
    func rotationNoopBelowThreshold() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path); try? FileManager.default.removeItem(at: archiveURL(path)) }

        let journal = DeletionJournal(path: path)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<3 { try await journal.append(syncRun("s\(i)", at: now.addingTimeInterval(Double(i) * 3600))) }

        let outcome = try await journal.rotateIfNeeded(keepingRuns: 500, slack: 100, now: now)
        #expect(outcome == nil)
        #expect(!FileManager.default.fileExists(atPath: archiveURL(path).path))
        #expect(try await journal.readAll().count == 3)
    }

    @Test("rotateIfNeeded archives the oldest runs and keeps the most recent N")
    func rotationArchivesOldest() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path); try? FileManager.default.removeItem(at: archiveURL(path)) }

        let journal = DeletionJournal(path: path)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<6 { try await journal.append(syncRun("s\(i)", at: now.addingTimeInterval(Double(i) * 3600))) }

        let out = try #require(try await journal.rotateIfNeeded(keepingRuns: 3, slack: 0, now: now.addingTimeInterval(6 * 3600)))
        #expect(out.archivedRuns == 3)
        #expect(out.liveRuns == 3)

        #expect(Set(try await journal.readAll().map(\.runId)) == ["s3", "s4", "s5"])
        #expect(Set(try await journal.readArchive().map(\.runId)) == ["s0", "s1", "s2"])
    }

    @Test("guard keeps an older run that has a destructive event within the window")
    func rotationGuardKeepsRecentDestructive() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path); try? FileManager.default.removeItem(at: archiveURL(path)) }

        let journal = DeletionJournal(path: path)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Trash run from ~1 day ago — older than every sync run below,
        // so it ranks beyond the last-3 by recency, but well within the
        // 30-day window.
        try await journal.append(.init(
            timestamp: now.addingTimeInterval(-86_400),
            runId: "T",
            event: .planningTrash(targets: [JournalEntry.TrashTarget(assetId: "a1", checksum: "ck1", livePhotoVideoId: nil)])))
        try await journal.append(.init(
            timestamp: now.addingTimeInterval(-86_400 + 1),
            runId: "T",
            event: .trashSucceeded(assetIds: ["a1"], durationMs: 10)))
        for i in 0..<4 { try await journal.append(syncRun("s\(i)", at: now.addingTimeInterval(-Double(4 - i) * 3600))) }

        let out = try #require(try await journal.rotateIfNeeded(keepingRuns: 3, slack: 0, protectWindowDays: 30, now: now))
        // Only the oldest sync run rotates; the trash run is protected.
        #expect(out.archivedRuns == 1)
        let live = Set(try await journal.readAll().map(\.runId))
        #expect(live.contains("T"))
        #expect(Set(try await journal.readArchive().map(\.runId)) == ["s0"])

        // The per-sync detector still finds the trashed checksum from the
        // live file alone — no archive read required.
        let idx = JournalReader.recentlyTrashedChecksums(in: try await journal.readAll(), now: now)
        #expect(idx[Checksum(base64: "ck1")] != nil)
    }

    @Test("entriesForRun falls back to the archive for a rotated-out run")
    func entriesForRunArchiveFallback() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path); try? FileManager.default.removeItem(at: archiveURL(path)) }

        let journal = DeletionJournal(path: path)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<6 { try await journal.append(syncRun("s\(i)", at: now.addingTimeInterval(Double(i) * 3600))) }
        _ = try await journal.rotateIfNeeded(keepingRuns: 3, slack: 0, now: now.addingTimeInterval(6 * 3600))

        let archived = try await journal.entriesForRun("s0")   // rotated out
        #expect(archived.count == 1 && archived.first?.runId == "s0")
        let liveStill = try await journal.entriesForRun("s5")   // still live
        #expect(liveStill.count == 1 && liveStill.first?.runId == "s5")
    }

    @Test("rotation preserves undecodable rows in the live file")
    func rotationPreservesUndecodableRows() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path); try? FileManager.default.removeItem(at: archiveURL(path)) }

        let journal = DeletionJournal(path: path)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await journal.appendRawLines(["{ this is not valid json"])
        for i in 0..<6 { try await journal.append(syncRun("s\(i)", at: now.addingTimeInterval(Double(i) * 3600))) }

        _ = try await journal.rotateIfNeeded(keepingRuns: 3, slack: 0, now: now.addingTimeInterval(6 * 3600))

        let live = try await journal.readRawLines()
        #expect(live.contains { $0.contains("not valid json") })
        let archived = try await journal.readArchiveRawLines()
        #expect(!archived.contains { $0.contains("not valid json") })
    }
}
