import Foundation
import Testing
import CairnCore
@testable import CairnIOSCore

/// Unit coverage for `CairnFixtures.JournalTailEntry.from(_:)` and its
/// helpers. The Status screen reads the resulting fields directly —
/// event-name strings drive `eventColor`, `glyph` drives the leading
/// SF Symbol, `isRoutineSync` drives the filter chip, `runIdSuffix`
/// drives the right-aligned column, and the abort summarizer rewrites
/// the verbose `SafetyRails.AbortReason.description` for the
/// single-line row. Each test pins one of those projections.
@Suite("JournalTailEntry — from(JournalEntry)")
struct JournalTailEntryFromTests {

    private typealias Tail = CairnFixtures.JournalTailEntry

    private let runId = "2026-04-21T17:57:15Z-034389BC"
    private let ts = Date(timeIntervalSince1970: 1_745_200_000)

    private func entry(_ event: JournalEntry.Event) -> JournalEntry {
        JournalEntry(timestamp: ts, runId: runId, event: event)
    }

    private func target(_ id: String, ck: String) -> JournalEntry.TrashTarget {
        JournalEntry.TrashTarget(assetId: id, checksum: ck, livePhotoVideoId: nil)
    }

    @Test("runStarted → run.start, play.circle, not routine")
    func runStarted() {
        let t = Tail.from(entry(.runStarted(dryRun: false, candidateCount: 3, assetsInPurview: 100)))
        #expect(t.event == "run.start")
        #expect(t.glyph == "play.circle")
        #expect(!t.isRoutineSync)
        #expect(t.runIdSuffix == "034389BC")
        #expect(t.runId == runId)
        #expect(t.message.contains("live"))
        #expect(t.message.contains("3 candidates"))
    }

    @Test("runStarted dry-run shows dry-run label")
    func runStartedDryRun() {
        let t = Tail.from(entry(.runStarted(dryRun: true, candidateCount: 1, assetsInPurview: 100)))
        #expect(t.message.contains("dry-run"))
        #expect(t.message.contains("1 candidate"))
        #expect(!t.message.contains("candidates"))
    }

    @Test("planningTrash → plan.trash, list.bullet")
    func planningTrash() {
        let t = Tail.from(entry(.planningTrash(targets: [target("a", ck: "x"), target("b", ck: "y")])))
        #expect(t.event == "plan.trash")
        #expect(t.glyph == "list.bullet")
        #expect(t.message == "2 assets")
    }

    @Test("tagApplied uses short-form value (last 12 chars + ellipsis)")
    func tagApplied() {
        let t = Tail.from(entry(.tagApplied(
            tagId: "tid",
            tagValue: "cairn/v1/run/2026-04-21T17:57:15Z-034389BC",
            assetIds: ["a", "b", "c"]
        )))
        #expect(t.event == "tag.apply")
        #expect(t.glyph == "tag")
        // Last 12 of `cairn/v1/run/2026-04-21T17:57:15Z-034389BC`
        // is `15Z-034389BC`. Suffix-tail trims to keep the rightmost
        // 12 chars (drops the leading prefix).
        #expect(t.message.hasPrefix("…"))
        #expect(t.message.contains("15Z-034389BC"))
        #expect(t.message.hasSuffix("→ 3 assets"))
    }

    @Test("trashSucceeded → trash.ok, checkmark")
    func trashSucceeded() {
        let t = Tail.from(entry(.trashSucceeded(assetIds: ["a"])))
        #expect(t.event == "trash.ok")
        #expect(t.glyph == "checkmark")
        #expect(t.message.contains("1 asset"))
    }

    @Test("trashFailed → trash.fail, xmark.octagon")
    func trashFailed() {
        let t = Tail.from(entry(.trashFailed(assetIds: ["a", "b"], message: "HTTP 500")))
        #expect(t.event == "trash.fail")
        #expect(t.glyph == "xmark.octagon")
        #expect(t.message.contains("2 assets"))
        #expect(t.message.contains("HTTP 500"))
    }

    @Test("runCompleted → run.complete, checkmark")
    func runCompleted() {
        let t = Tail.from(entry(.runCompleted(deletedCount: 14)))
        #expect(t.event == "run.complete")
        #expect(t.glyph == "checkmark")
        #expect(t.message == "trashed=14")
    }

    @Test("runAborted summarizes thresholdExceeded")
    func runAbortedThreshold() {
        let reason = "thresholdExceeded — would delete 12 of 1024 in-purview assets (1.17%); limit is 1.00%"
        let t = Tail.from(entry(.runAborted(reason: reason)))
        #expect(t.event == "run.abort")
        #expect(t.glyph == "exclamationmark.triangle")
        #expect(t.message == "safety rail (12 / 1.17% > 1.00% cap)")
    }

    @Test("runAborted summarizes emptyServerResponse")
    func runAbortedEmptyServer() {
        let reason = "emptyServerResponse — server returned 0 assets, refusing to act on what looks like a transient API problem"
        let t = Tail.from(entry(.runAborted(reason: reason)))
        #expect(t.message == "server returned 0 assets")
    }

    @Test("runAborted summarizes emptyLocalLibrary")
    func runAbortedEmptyLocal() {
        let reason = "emptyLocalLibrary — local checksum set is empty (Photos permission revoked? Library not loaded?)"
        let t = Tail.from(entry(.runAborted(reason: reason)))
        #expect(t.message == "local library empty (Photos permission?)")
    }

    @Test("runAborted summarizes firstRunNotDryRun")
    func runAbortedFirstRun() {
        let reason = "firstRunNotDryRun — the first run on a fresh ever-seen store must be a dry-run"
        let t = Tail.from(entry(.runAborted(reason: reason)))
        #expect(t.message == "first run must be dry-run")
    }

    @Test("runAborted unknown reason falls through to first 60 chars")
    func runAbortedUnknown() {
        let reason = "someNewCodeName — totally novel reason that didn't exist before this test was written"
        let t = Tail.from(entry(.runAborted(reason: reason)))
        #expect(t.message == String(reason.prefix(60)))
    }

    @Test("restoreStarted → restore.start, arrow.uturn.backward")
    func restoreStarted() {
        let t = Tail.from(entry(.restoreStarted(fromRunId: runId, assetIds: ["a", "b"])))
        #expect(t.event == "restore.start")
        #expect(t.glyph == "arrow.uturn.backward")
        #expect(t.message.contains("2 assets"))
    }

    @Test("restoreSucceeded → restore.ok, checkmark")
    func restoreSucceeded() {
        let t = Tail.from(entry(.restoreSucceeded(fromRunId: runId, assetIds: ["a"])))
        #expect(t.event == "restore.ok")
        #expect(t.glyph == "checkmark")
        #expect(t.message.contains("1 asset"))
    }

    @Test("restoreFailed → restore.fail, xmark.octagon")
    func restoreFailed() {
        let t = Tail.from(entry(.restoreFailed(fromRunId: runId, assetIds: ["a"], message: "boom")))
        #expect(t.event == "restore.fail")
        #expect(t.glyph == "xmark.octagon")
        #expect(t.message.contains("boom"))
    }

    @Test("assetsExcluded → exclude.add, shield glyph")
    func assetsExcluded() {
        let t = Tail.from(entry(.assetsExcluded(checksums: ["a", "b", "c"], fromRunId: nil)))
        #expect(t.event == "exclude.add")
        #expect(t.glyph == "shield.lefthalf.filled")
        #expect(t.message == "3 checksums")
    }

    @Test("pendingReview → pending.hold, clock glyph")
    func pendingReview() {
        let t = Tail.from(entry(.pendingReview(assetIds: ["a", "b"], checksums: ["x", "y"])))
        #expect(t.event == "pending.hold")
        #expect(t.glyph == "clock.arrow.circlepath")
        #expect(t.message.contains("2 assets"))
    }

    @Test("syncCompleted → sync, arrow glyph; routine when every signal is zero")
    func syncCompletedRoutine() {
        let t = Tail.from(entry(.syncCompleted(
            indexed: 100, candidates: 0, pendingReview: 0,
            deferredLarge: 0, deferredLargeBytes: 0,
            deferredTimeout: 0, elapsedMs: 1200
        )))
        #expect(t.event == "sync")
        #expect(t.glyph == "arrow.triangle.2.circlepath")
        #expect(t.isRoutineSync)
    }

    @Test("syncCompleted not routine when candidates > 0")
    func syncCompletedNotRoutineCandidates() {
        let t = Tail.from(entry(.syncCompleted(
            indexed: 100, candidates: 3, pendingReview: 0,
            deferredLarge: 0, deferredLargeBytes: 0,
            deferredTimeout: 0, elapsedMs: 1200
        )))
        #expect(!t.isRoutineSync)
    }

    @Test("syncCompleted not routine when pendingReview > 0")
    func syncCompletedNotRoutinePending() {
        let t = Tail.from(entry(.syncCompleted(
            indexed: 100, candidates: 0, pendingReview: 1,
            deferredLarge: 0, deferredLargeBytes: 0,
            deferredTimeout: 0, elapsedMs: 1200
        )))
        #expect(!t.isRoutineSync)
    }

    @Test("syncCompleted not routine when deferredLarge or deferredTimeout > 0")
    func syncCompletedNotRoutineDeferred() {
        let large = Tail.from(entry(.syncCompleted(
            indexed: 100, candidates: 0, pendingReview: 0,
            deferredLarge: 2, deferredLargeBytes: 1_000_000,
            deferredTimeout: 0, elapsedMs: 1200
        )))
        #expect(!large.isRoutineSync)
        let timeout = Tail.from(entry(.syncCompleted(
            indexed: 100, candidates: 0, pendingReview: 0,
            deferredLarge: 0, deferredLargeBytes: 0,
            deferredTimeout: 1, elapsedMs: 1200
        )))
        #expect(!timeout.isRoutineSync)
    }

    @Test("runIdSuffix is the last 8 chars of the entry runId")
    func runIdSuffixShape() {
        let t = Tail.from(entry(.runCompleted(deletedCount: 1)))
        #expect(t.runIdSuffix == "034389BC")
        #expect(t.runIdSuffix.count == 8)
    }

    @Test("non-sync events are never marked routine")
    func nonSyncNeverRoutine() {
        let cases: [JournalEntry.Event] = [
            .runStarted(dryRun: false, candidateCount: 1, assetsInPurview: 1),
            .runCompleted(deletedCount: 0),
            .runAborted(reason: "unknown"),
            .planningTrash(targets: []),
            .trashSucceeded(assetIds: []),
            .pendingReview(assetIds: [], checksums: []),
        ]
        for c in cases {
            #expect(!Tail.from(entry(c)).isRoutineSync)
        }
    }
}

/// Coverage for the routine-sync filter logic at the call-site shape:
/// only `syncCompleted` events with every signal field at zero get
/// flagged. Anything with real signal — or any non-sync event — must
/// pass through.
@Suite("JournalTailEntry — routine-sync filter")
struct JournalTailRoutineFilterTests {

    private typealias Tail = CairnFixtures.JournalTailEntry

    private let runId = "2026-04-21T17:55:00Z-sync5512"

    private func sync(
        candidates: Int = 0,
        pending: Int = 0,
        large: Int = 0,
        largeBytes: Int64 = 0,
        timeout: Int = 0
    ) -> JournalEntry {
        JournalEntry(
            runId: runId,
            event: .syncCompleted(
                indexed: 100,
                candidates: candidates,
                pendingReview: pending,
                deferredLarge: large,
                deferredLargeBytes: largeBytes,
                deferredTimeout: timeout,
                elapsedMs: 800
            )
        )
    }

    @Test("a buffer of all-routine syncs filters down to nothing")
    func allRoutineFilters() {
        let entries = (0..<5).map { _ in Tail.from(sync()) }
        let filtered = entries.filter { !$0.isRoutineSync }
        #expect(filtered.isEmpty)
    }

    @Test("any sync with candidates > 0 stays visible after filter")
    func candidatesStaysVisible() {
        let entries = [
            Tail.from(sync()),
            Tail.from(sync(candidates: 4)),
            Tail.from(sync()),
        ]
        let filtered = entries.filter { !$0.isRoutineSync }
        #expect(filtered.count == 1)
        #expect(filtered.first?.message.contains("cand=4") == true)
    }

    @Test("non-sync events are never elided")
    func nonSyncStaysVisible() {
        let entries = [
            Tail.from(JournalEntry(runId: runId, event: .runStarted(dryRun: false, candidateCount: 1, assetsInPurview: 1))),
            Tail.from(sync()),
            Tail.from(JournalEntry(runId: runId, event: .runCompleted(deletedCount: 0))),
        ]
        let filtered = entries.filter { !$0.isRoutineSync }
        #expect(filtered.count == 2)
    }
}

/// Coverage for `JournalTailEntry.summarizeAbortReason` — exercised
/// indirectly via `runAborted` cases above, but pinned directly here
/// so a mapping change has a single canonical test surface.
@Suite("JournalTailEntry — abort-reason summarizer")
struct JournalTailAbortSummaryTests {

    private typealias Tail = CairnFixtures.JournalTailEntry

    @Test("thresholdExceeded → safety-rail short form with extracted numbers")
    func threshold() {
        let raw = "thresholdExceeded — would delete 12 of 1024 in-purview assets (1.17%); limit is 1.00%"
        #expect(Tail.summarizeAbortReason(raw) == "safety rail (12 / 1.17% > 1.00% cap)")
    }

    @Test("thresholdExceeded with different numbers — extraction still works")
    func thresholdLargeNumbers() {
        let raw = "thresholdExceeded — would delete 250 of 99999 in-purview assets (12.34%); limit is 5.00%"
        #expect(Tail.summarizeAbortReason(raw) == "safety rail (250 / 12.34% > 5.00% cap)")
    }

    @Test("thresholdExceeded with malformed payload still returns a safe fallback")
    func thresholdMalformed() {
        let raw = "thresholdExceeded — short form with no numbers"
        // Numbers can't be extracted; helper returns a generic fallback
        // rather than crashing on the missing match.
        #expect(Tail.summarizeAbortReason(raw) == "safety rail tripped")
    }

    @Test("emptyServerResponse → short form")
    func emptyServer() {
        let raw = "emptyServerResponse — server returned 0 assets, refusing to act on what looks like a transient API problem"
        #expect(Tail.summarizeAbortReason(raw) == "server returned 0 assets")
    }

    @Test("emptyLocalLibrary → short form")
    func emptyLocal() {
        let raw = "emptyLocalLibrary — local checksum set is empty (Photos permission revoked? Library not loaded?)"
        #expect(Tail.summarizeAbortReason(raw) == "local library empty (Photos permission?)")
    }

    @Test("firstRunNotDryRun → short form")
    func firstRun() {
        let raw = "firstRunNotDryRun — the first run on a fresh ever-seen store must be a dry-run"
        #expect(Tail.summarizeAbortReason(raw) == "first run must be dry-run")
    }

    @Test("unknown leading code-name falls through to verbatim prefix(60)")
    func unknownLeading() {
        let raw = "novelAbortCode — first 60 chars get rendered exactly as-is for forensic visibility"
        let result = Tail.summarizeAbortReason(raw)
        #expect(result == String(raw.prefix(60)))
        #expect(result.count == 60)
    }

    /// Pin every `SafetyRails.AbortReason` description against the
    /// summarizer end-to-end. Catches drift in either direction.
    @Test("every SafetyRails.AbortReason description summarizes cleanly")
    func everyAbortReason() {
        let cases: [SafetyDecision.AbortReason] = [
            .emptyServerResponse,
            .emptyLocalLibrary,
            .firstRunNotDryRun,
            .thresholdExceeded(candidateCount: 12, assetsInEverSeen: 1024, percent: 0.0117, limit: 0.01),
        ]
        for reason in cases {
            let summary = Tail.summarizeAbortReason(reason.description)
            // No summary should be empty, and none should still carry
            // the original em-dash separator (we always rewrite).
            #expect(!summary.isEmpty)
            #expect(!summary.contains(" — "))
        }
    }
}

/// Compact-time format coverage: same-day rendering, past-day
/// rendering, and locale stability.
@Suite("JournalTailEntry — compact time format")
struct JournalTailTimeFormatTests {

    private typealias Tail = CairnFixtures.JournalTailEntry

    @Test("same-day timestamps render as HH:mm")
    func sameDay() {
        let now = Date()
        // Build a date earlier today by subtracting a few hours.
        let earlier = Calendar.current.date(byAdding: .minute, value: -125, to: now) ?? now
        let formatted = Tail.formatTime(earlier, now: now)
        // `HH:mm` is exactly 5 characters, with a colon.
        #expect(formatted.count == 5)
        #expect(formatted.contains(":"))
    }

    @Test("past-day timestamps render as MMM d HH:mm")
    func pastDay() {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now
        let formatted = Tail.formatTime(yesterday, now: now)
        // Past-day form contains a colon (HH:mm) AND a space (between
        // the date and time fragments). Same-day form has no space.
        #expect(formatted.contains(":"))
        #expect(formatted.contains(" "))
    }
}
