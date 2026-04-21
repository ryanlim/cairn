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
            entry("R1", "2026-04-21T00:00:01Z", .trashSucceeded(assetIds: ["a", "b"])),
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
            entry("R1", "2026-04-21T00:00:01Z", .trashSucceeded(assetIds: ["a"])),
            entry("R1", "2026-04-21T00:00:02Z", .runCompleted(deletedCount: 1)),
            entry("R1", "2026-04-21T01:00:00Z", .restoreSucceeded(fromRunId: "R1", assetIds: ["a"])),
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
            entry("F", "2026-04-21T00:00:01Z", .trashFailed(assetIds: ["x"], message: "server down")),
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
}
