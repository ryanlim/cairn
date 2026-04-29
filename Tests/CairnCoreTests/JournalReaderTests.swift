import Foundation
import Testing
@testable import CairnCore

@Suite("JournalReader")
struct JournalReaderTests {

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func entry(_ runId: String, _ iso: String, _ event: JournalEntry.Event) -> JournalEntry {
        JournalEntry(timestamp: date(iso), runId: runId, event: event)
    }

    @Test("classifies a completed trash run as .trashed with the right asset count")
    func trashedStatus() {
        let es = [
            entry("R1", "2026-04-21T00:00:00Z", .runStarted(dryRun: false, candidateCount: 2, assetsInPurview: 100)),
            entry("R1", "2026-04-21T00:00:01Z", .trashSucceeded(assetIds: ["a", "b"], durationMs: nil)),
            entry("R1", "2026-04-21T00:00:02Z", .runCompleted(deletedCount: 2)),
        ]
        let summaries = JournalReader.summarize(es)
        #expect(summaries.count == 1)
        #expect(summaries[0].status == .trashed)
        #expect(summaries[0].trashedCount == 2)
        #expect(summaries[0].restoredCount == 0)
    }

    @Test("a run with restoreSucceeded reports .restored, preserving trashedCount for context")
    func restoredStatus() {
        let es = [
            entry("R1", "2026-04-21T00:00:00Z", .runStarted(dryRun: false, candidateCount: 1, assetsInPurview: 100)),
            entry("R1", "2026-04-21T00:00:01Z", .trashSucceeded(assetIds: ["a"], durationMs: nil)),
            entry("R1", "2026-04-21T00:00:02Z", .runCompleted(deletedCount: 1)),
            entry("R1", "2026-04-21T01:00:00Z", .restoreSucceeded(fromRunId: "R1", assetIds: ["a"], durationMs: nil)),
        ]
        let s = JournalReader.summarize(es)[0]
        #expect(s.status == .restored)
        #expect(s.trashedCount == 1)
        #expect(s.restoredCount == 1)
    }

    @Test("a dry-run is classified as .dryRun and no trashed count is recorded")
    func dryRunStatus() {
        let es = [
            entry("D", "2026-04-21T00:00:00Z", .runStarted(dryRun: true, candidateCount: 5, assetsInPurview: 100)),
            entry("D", "2026-04-21T00:00:01Z", .runCompleted(deletedCount: 0)),
        ]
        let s = JournalReader.summarize(es)[0]
        #expect(s.status == .dryRun)
        #expect(s.trashedCount == 0)
    }

    @Test("trashFailed without trashSucceeded → .trashFailed")
    func trashFailedStatus() {
        let es = [
            entry("F", "2026-04-21T00:00:00Z", .runStarted(dryRun: false, candidateCount: 1, assetsInPurview: 100)),
            entry("F", "2026-04-21T00:00:01Z", .trashFailed(assetIds: ["x"], message: "server down", httpStatus: nil)),
        ]
        let s = JournalReader.summarize(es)[0]
        #expect(s.status == .trashFailed)
    }

    @Test("aborted beats every other state (the safety rail stopped the run)")
    func abortedWins() {
        let es = [
            entry("A", "2026-04-21T00:00:00Z", .runStarted(dryRun: false, candidateCount: 50, assetsInPurview: 100)),
            entry("A", "2026-04-21T00:00:01Z", .runAborted(reason: "thresholdExceeded")),
        ]
        let s = JournalReader.summarize(es)[0]
        #expect(s.status == .aborted)
    }

    @Test("summaries are ordered by lastTimestamp descending — most recent first")
    func summaryOrdering() {
        let old = entry("OLD", "2026-04-01T00:00:00Z", .runStarted(dryRun: true, candidateCount: 0, assetsInPurview: 0))
        let oldDone = entry("OLD", "2026-04-01T00:00:01Z", .runCompleted(deletedCount: 0))
        let new = entry("NEW", "2026-04-21T00:00:00Z", .runStarted(dryRun: true, candidateCount: 0, assetsInPurview: 0))
        let newDone = entry("NEW", "2026-04-21T00:00:01Z", .runCompleted(deletedCount: 0))

        let summaries = JournalReader.summarize([old, oldDone, new, newDone])
        #expect(summaries.map(\.runId) == ["NEW", "OLD"])
    }

    @Test("mostRecentRunId returns the latest run or nil on empty journal")
    func mostRecentRun() {
        #expect(JournalReader.mostRecentRunId(in: []) == nil)

        let es = [
            entry("A", "2026-04-01T00:00:00Z", .runCompleted(deletedCount: 0)),
            entry("B", "2026-04-21T00:00:00Z", .runCompleted(deletedCount: 0)),
        ]
        #expect(JournalReader.mostRecentRunId(in: es) == "B")
    }

    @Test("entries(for:) returns only entries for the requested run, in original order")
    func entriesForRun() {
        let es = [
            entry("A", "2026-04-21T00:00:00Z", .runStarted(dryRun: true, candidateCount: 0, assetsInPurview: 0)),
            entry("B", "2026-04-21T00:00:01Z", .runStarted(dryRun: true, candidateCount: 0, assetsInPurview: 0)),
            entry("A", "2026-04-21T00:00:02Z", .runCompleted(deletedCount: 0)),
        ]
        let aEntries = JournalReader.entries(for: "A", in: es)
        #expect(aEntries.count == 2)
        #expect(aEntries.map(\.runId) == ["A", "A"])
    }

    @Test("trashed with live-photo pair produces the paired-video note")
    func trashedWithLivePhotoNote() {
        let target = JournalEntry.TrashTarget(
            assetId: "still-1",
            checksum: "c1",
            livePhotoVideoId: "video-1"
        )
        let es = [
            entry("R1", "2026-04-21T00:00:00Z", .runStarted(dryRun: false, candidateCount: 1, assetsInPurview: 100)),
            entry("R1", "2026-04-21T00:00:01Z", .planningTrash(targets: [target])),
            entry("R1", "2026-04-21T00:00:02Z", .trashSucceeded(assetIds: ["still-1", "video-1"], durationMs: nil)),
            entry("R1", "2026-04-21T00:00:03Z", .runCompleted(deletedCount: 2)),
        ]
        let s = JournalReader.summarize(es)[0]
        #expect(s.status == .trashed)
        #expect(s.notes.contains("live-photo videos included"))
        #expect(s.notes.contains("1 live-photo videos included"))
    }

    @Test("restored run shows restored count, not trashed count")
    func restoredNoteShowsRestoredCount() {
        let es = [
            entry("R1", "2026-04-21T00:00:00Z", .runStarted(dryRun: false, candidateCount: 2, assetsInPurview: 100)),
            entry("R1", "2026-04-21T00:00:01Z", .trashSucceeded(assetIds: ["a", "b"], durationMs: nil)),
            entry("R1", "2026-04-21T00:00:02Z", .runCompleted(deletedCount: 2)),
            entry("R1", "2026-04-21T01:00:00Z", .restoreSucceeded(fromRunId: "R1", assetIds: ["a", "b"], durationMs: nil)),
        ]
        let s = JournalReader.summarize(es)[0]
        #expect(s.status == .restored)
        #expect(s.notes.contains("2 restored"))
        #expect(!s.notes.contains("trashed"))
    }

    @Test("dry-run with candidates produces the right note")
    func dryRunWithCandidatesNote() {
        let es = [
            entry("D", "2026-04-21T00:00:00Z", .runStarted(dryRun: true, candidateCount: 5, assetsInPurview: 100)),
            entry("D", "2026-04-21T00:00:01Z", .runCompleted(deletedCount: 0)),
        ]
        let s = JournalReader.summarize(es)[0]
        #expect(s.notes == "dry-run · 5 candidates")
    }

    @Test("dry-run with no candidates says 'no candidates'")
    func dryRunNoCandidatesNote() {
        let es = [
            entry("D", "2026-04-21T00:00:00Z", .runStarted(dryRun: true, candidateCount: 0, assetsInPurview: 100)),
            entry("D", "2026-04-21T00:00:01Z", .runCompleted(deletedCount: 0)),
        ]
        let s = JournalReader.summarize(es)[0]
        #expect(s.notes == "dry-run · no candidates")
    }

    @Test("aborted run includes the abort reason")
    func abortedNoteIncludesReason() {
        let es = [
            entry("A", "2026-04-21T00:00:00Z", .runStarted(dryRun: false, candidateCount: 50, assetsInPurview: 100)),
            entry("A", "2026-04-21T00:00:01Z", .runAborted(reason: "threshold · 2.3% > 1% cap")),
        ]
        let s = JournalReader.summarize(es)[0]
        #expect(s.status == .aborted)
        #expect(s.notes.contains("threshold · 2.3% > 1% cap"))
        #expect(s.notes.hasPrefix("aborted · "))
    }

    @Test("durationMs is last timestamp minus first, in ms")
    func durationMsBasic() {
        let es = [
            entry("R1", "2026-04-21T00:00:00Z", .runStarted(dryRun: false, candidateCount: 1, assetsInPurview: 100)),
            entry("R1", "2026-04-21T00:00:03Z", .trashSucceeded(assetIds: ["a"], durationMs: nil)),
            entry("R1", "2026-04-21T00:00:05Z", .runCompleted(deletedCount: 1)),
        ]
        let s = JournalReader.summarize(es)[0]
        #expect(s.durationMs == 5000)
    }

    // MARK: - recentlyTrashedChecksums

    @Test("empty journal produces an empty trash index")
    func recentlyTrashedEmpty() {
        let now = date("2026-04-25T00:00:00Z")
        let map = JournalReader.recentlyTrashedChecksums(in: [], withinDays: 30, now: now)
        #expect(map.isEmpty)
    }

    @Test("a single trashed run surfaces its checksums with the right runId and timestamp")
    func recentlyTrashedOneRun() {
        let target = JournalEntry.TrashTarget(
            assetId: "asset-1",
            checksum: "ck1",
            livePhotoVideoId: nil
        )
        let trashedAt = date("2026-04-20T12:00:00Z")
        let es = [
            entry("R1", "2026-04-20T11:59:00Z", .runStarted(dryRun: false, candidateCount: 1, assetsInPurview: 100)),
            entry("R1", "2026-04-20T11:59:30Z", .planningTrash(targets: [target])),
            JournalEntry(timestamp: trashedAt, runId: "R1", event: .trashSucceeded(assetIds: ["asset-1"], durationMs: nil)),
            entry("R1", "2026-04-20T12:00:01Z", .runCompleted(deletedCount: 1)),
        ]
        let now = date("2026-04-25T00:00:00Z")
        let map = JournalReader.recentlyTrashedChecksums(in: es, withinDays: 30, now: now)
        #expect(map.count == 1)
        let record = map[Checksum(base64: "ck1")]
        #expect(record?.runId == "R1")
        #expect(record?.trashedAt == trashedAt)
    }

    @Test("when the same checksum appears in two runs, the more recent one wins")
    func recentlyTrashedNewerWins() {
        let target = JournalEntry.TrashTarget(
            assetId: "asset-1",
            checksum: "ck1",
            livePhotoVideoId: nil
        )
        let oldTrashedAt = date("2026-04-10T12:00:00Z")
        let newTrashedAt = date("2026-04-20T12:00:00Z")
        let es = [
            entry("OLD", "2026-04-10T11:59:00Z", .runStarted(dryRun: false, candidateCount: 1, assetsInPurview: 100)),
            entry("OLD", "2026-04-10T11:59:30Z", .planningTrash(targets: [target])),
            JournalEntry(timestamp: oldTrashedAt, runId: "OLD", event: .trashSucceeded(assetIds: ["asset-1"], durationMs: nil)),
            entry("NEW", "2026-04-20T11:59:00Z", .runStarted(dryRun: false, candidateCount: 1, assetsInPurview: 100)),
            entry("NEW", "2026-04-20T11:59:30Z", .planningTrash(targets: [target])),
            JournalEntry(timestamp: newTrashedAt, runId: "NEW", event: .trashSucceeded(assetIds: ["asset-1"], durationMs: nil)),
        ]
        let now = date("2026-04-25T00:00:00Z")
        let map = JournalReader.recentlyTrashedChecksums(in: es, withinDays: 30, now: now)
        let record = map[Checksum(base64: "ck1")]
        #expect(record?.runId == "NEW")
        #expect(record?.trashedAt == newTrashedAt)
    }

    @Test("trashed runs older than withinDays are excluded")
    func recentlyTrashedRespectsWindow() {
        let target = JournalEntry.TrashTarget(
            assetId: "asset-1",
            checksum: "ck1",
            livePhotoVideoId: nil
        )
        // Trashed 45 days before `now` — past the 30-day window.
        let es = [
            entry("R1", "2026-03-10T11:59:00Z", .runStarted(dryRun: false, candidateCount: 1, assetsInPurview: 100)),
            entry("R1", "2026-03-10T11:59:30Z", .planningTrash(targets: [target])),
            entry("R1", "2026-03-10T12:00:00Z", .trashSucceeded(assetIds: ["asset-1"], durationMs: nil)),
        ]
        let now = date("2026-04-25T00:00:00Z")
        let map = JournalReader.recentlyTrashedChecksums(in: es, withinDays: 30, now: now)
        #expect(map.isEmpty)
    }

    @Test("trashFailed-only runs do not contribute checksums")
    func recentlyTrashedFailureOnly() {
        let target = JournalEntry.TrashTarget(
            assetId: "asset-1",
            checksum: "ck1",
            livePhotoVideoId: nil
        )
        let es = [
            entry("R1", "2026-04-20T11:59:00Z", .runStarted(dryRun: false, candidateCount: 1, assetsInPurview: 100)),
            entry("R1", "2026-04-20T11:59:30Z", .planningTrash(targets: [target])),
            entry("R1", "2026-04-20T12:00:00Z", .trashFailed(assetIds: ["asset-1"], message: "server error", httpStatus: nil)),
        ]
        let now = date("2026-04-25T00:00:00Z")
        let map = JournalReader.recentlyTrashedChecksums(in: es, withinDays: 30, now: now)
        #expect(map.isEmpty)
    }

    @Test("a checksum trashed then restored via cairn drops out of the index")
    func recentlyTrashedRestoredViaCairn() {
        // Worked scenario: user trashes 4 photos, then restores all 4
        // via cairn's restore action. Banner should no longer flag
        // them as "still in Immich trash" — they're back on Immich
        // as live assets.
        let target = JournalEntry.TrashTarget(
            assetId: "asset-1",
            checksum: "ck1",
            livePhotoVideoId: nil
        )
        let es = [
            entry("R1", "2026-04-20T11:59:00Z", .runStarted(dryRun: false, candidateCount: 1, assetsInPurview: 100)),
            entry("R1", "2026-04-20T11:59:30Z", .planningTrash(targets: [target])),
            entry("R1", "2026-04-20T12:00:00Z", .trashSucceeded(assetIds: ["asset-1"], durationMs: nil)),
            entry("R2", "2026-04-22T09:00:00Z", .restoreSucceeded(fromRunId: "R1", assetIds: ["asset-1"], durationMs: nil)),
        ]
        let now = date("2026-04-25T00:00:00Z")
        let map = JournalReader.recentlyTrashedChecksums(in: es, withinDays: 30, now: now)
        #expect(map.isEmpty)
    }

    @Test("partial restore: only the restored subset drops out, the rest remain")
    func recentlyTrashedPartialRestore() {
        let t1 = JournalEntry.TrashTarget(assetId: "a1", checksum: "ck1", livePhotoVideoId: nil)
        let t2 = JournalEntry.TrashTarget(assetId: "a2", checksum: "ck2", livePhotoVideoId: nil)
        let es = [
            entry("R1", "2026-04-20T11:59:30Z", .planningTrash(targets: [t1, t2])),
            entry("R1", "2026-04-20T12:00:00Z", .trashSucceeded(assetIds: ["a1", "a2"], durationMs: nil)),
            entry("R2", "2026-04-22T09:00:00Z", .restoreSucceeded(fromRunId: "R1", assetIds: ["a1"], durationMs: nil)),
        ]
        let now = date("2026-04-25T00:00:00Z")
        let map = JournalReader.recentlyTrashedChecksums(in: es, withinDays: 30, now: now)
        #expect(map.count == 1)
        #expect(map[Checksum(base64: "ck2")] != nil)
        #expect(map[Checksum(base64: "ck1")] == nil)
    }

    @Test("trash → restore → re-trash leaves the checksum flagged as trashed under the newer run")
    func recentlyTrashedRestoreThenReTrash() {
        let target = JournalEntry.TrashTarget(assetId: "a1", checksum: "ck1", livePhotoVideoId: nil)
        let target2 = JournalEntry.TrashTarget(assetId: "a1-v2", checksum: "ck1", livePhotoVideoId: nil)
        let reTrashedAt = date("2026-04-23T12:00:00Z")
        let es = [
            entry("R1", "2026-04-20T11:59:30Z", .planningTrash(targets: [target])),
            entry("R1", "2026-04-20T12:00:00Z", .trashSucceeded(assetIds: ["a1"], durationMs: nil)),
            entry("R2", "2026-04-22T09:00:00Z", .restoreSucceeded(fromRunId: "R1", assetIds: ["a1"], durationMs: nil)),
            entry("R3", "2026-04-23T11:59:30Z", .planningTrash(targets: [target2])),
            JournalEntry(timestamp: reTrashedAt, runId: "R3", event: .trashSucceeded(assetIds: ["a1-v2"], durationMs: nil)),
        ]
        let now = date("2026-04-25T00:00:00Z")
        let map = JournalReader.recentlyTrashedChecksums(in: es, withinDays: 30, now: now)
        let record = map[Checksum(base64: "ck1")]
        #expect(record?.runId == "R3")
        #expect(record?.trashedAt == reTrashedAt)
    }

    @Test("Live Photo motion video paired ID resolves through planningTrash")
    func recentlyTrashedLivePhotoPair() {
        // The trashSucceeded event lists both the still and the paired
        // video; planningTrash only carries the still target with
        // `livePhotoVideoId` set. The video id won't appear in the
        // planning map, so it gets omitted from the result — which is
        // correct: the index is keyed by *checksum*, and we only know
        // the still's checksum from the journal.
        let target = JournalEntry.TrashTarget(
            assetId: "still-1",
            checksum: "still-ck",
            livePhotoVideoId: "video-1"
        )
        let trashedAt = date("2026-04-20T12:00:00Z")
        let es = [
            entry("R1", "2026-04-20T11:59:00Z", .runStarted(dryRun: false, candidateCount: 1, assetsInPurview: 100)),
            entry("R1", "2026-04-20T11:59:30Z", .planningTrash(targets: [target])),
            JournalEntry(timestamp: trashedAt, runId: "R1", event: .trashSucceeded(assetIds: ["still-1", "video-1"], durationMs: nil)),
        ]
        let now = date("2026-04-25T00:00:00Z")
        let map = JournalReader.recentlyTrashedChecksums(in: es, withinDays: 30, now: now)
        #expect(map.count == 1)
        #expect(map[Checksum(base64: "still-ck")]?.runId == "R1")
    }
}
