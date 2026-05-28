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
        // Purview is set, so the message renders the ratio form
        // ("3 of 100 (3.00%)") rather than the bare count form.
        #expect(t.message.contains("3 of 100"))
        #expect(t.message.contains("3.00%"))
    }

    @Test("runStarted dry-run shows dry-run label")
    func runStartedDryRun() {
        let t = Tail.from(entry(.runStarted(dryRun: true, candidateCount: 1, assetsInPurview: 100)))
        #expect(t.message.contains("dry-run"))
        #expect(t.message.contains("1 of 100"))
        #expect(t.message.contains("1.00%"))
    }

    @Test("runStarted with no purview falls back to bare count")
    func runStartedNoPurview() {
        let t = Tail.from(entry(.runStarted(dryRun: false, candidateCount: 3, assetsInPurview: 0)))
        #expect(t.message.contains("3 candidates"))
        #expect(!t.message.contains("of 0"))
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
            assetIds: ["a", "b", "c"],
            durationMs: nil
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

    @Test("tagApplied with durationMs renders the suffix")
    func tagAppliedDuration() {
        let t = Tail.from(entry(.tagApplied(
            tagId: "tid",
            tagValue: "cairn/v1/run/abc",
            assetIds: ["a"],
            durationMs: 432
        )))
        #expect(t.message.contains("· 432ms"))
    }

    @Test("trashSucceeded → trash.ok, checkmark")
    func trashSucceeded() {
        let t = Tail.from(entry(.trashSucceeded(assetIds: ["a"], durationMs: nil)))
        #expect(t.event == "trash.ok")
        #expect(t.glyph == "checkmark")
        #expect(t.message.contains("1 asset"))
    }

    @Test("trashSucceeded with durationMs >= 1s renders seconds form")
    func trashSucceededDurationSeconds() {
        let t = Tail.from(entry(.trashSucceeded(assetIds: ["a"], durationMs: 1_400)))
        #expect(t.message.contains("· 1.4s"))
    }

    @Test("trashFailed → trash.fail, xmark.octagon")
    func trashFailed() {
        let t = Tail.from(entry(.trashFailed(assetIds: ["a", "b"], message: "HTTP 500", httpStatus: nil)))
        #expect(t.event == "trash.fail")
        #expect(t.glyph == "xmark.octagon")
        #expect(t.message.contains("2 assets"))
        #expect(t.message.contains("HTTP 500"))
    }

    @Test("trashFailed with httpStatus prepends the bracketed code")
    func trashFailedHttpStatus() {
        let t = Tail.from(entry(.trashFailed(assetIds: ["a"], message: "auth", httpStatus: 401)))
        #expect(t.message.contains("[401]"))
        #expect(t.message.contains("auth"))
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
        let reason = "firstRunNotDryRun — the first run on a fresh observed store must be a dry-run"
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
        let t = Tail.from(entry(.restoreSucceeded(fromRunId: runId, assetIds: ["a"], durationMs: nil)))
        #expect(t.event == "restore.ok")
        #expect(t.glyph == "checkmark")
        #expect(t.message.contains("1 asset"))
    }

    @Test("restoreFailed → restore.fail, xmark.octagon")
    func restoreFailed() {
        let t = Tail.from(entry(.restoreFailed(fromRunId: runId, assetIds: ["a"], message: "boom", httpStatus: nil)))
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
            .trashSucceeded(assetIds: [], durationMs: nil),
            .pendingReview(assetIds: [], checksums: []),
        ]
        for c in cases {
            #expect(!Tail.from(entry(c)).isRoutineSync)
        }
    }

    // MARK: - Severity tier

    @Test("severity tiers map per event type")
    func severityTiers() {
        // Spot-check one event per tier; full mapping is the switch
        // statement in from(_:).
        let infoEvent = Tail.from(entry(.runStarted(dryRun: false, candidateCount: 1, assetsInPurview: 100)))
        #expect(infoEvent.severity == .info)

        let okEvent = Tail.from(entry(.trashSucceeded(assetIds: ["a"], durationMs: nil)))
        #expect(okEvent.severity == .ok)

        let warnEvent = Tail.from(entry(.pendingReview(assetIds: ["a"], checksums: ["x"])))
        #expect(warnEvent.severity == .warn)

        let errorEvent = Tail.from(entry(.runAborted(reason: "test")))
        #expect(errorEvent.severity == .error)

        let trashFailEvent = Tail.from(entry(.trashFailed(assetIds: ["a"], message: "boom", httpStatus: nil)))
        #expect(trashFailEvent.severity == .error)
    }

    // MARK: - rawJSON encoding

    @Test("rawJSON is populated and decodes back to the source event")
    func rawJSONRoundTrips() throws {
        let source = entry(.trashSucceeded(assetIds: ["a", "b", "c"], durationMs: nil))
        let tail = Tail.from(source)
        let json = try #require(tail.rawJSON)
        #expect(json.contains("trashSucceeded"))
        // Round-trip back through JSONDecoder. Field-level match isn't
        // worth the fragility — round-trip equality is the point.
        let decoded = try JSONDecoder.cairnIso8601.decode(JournalEntry.self, from: Data(json.utf8))
        #expect(decoded.runId == source.runId)
        if case .trashSucceeded(let ids, _) = decoded.event {
            #expect(ids == ["a", "b", "c"])
        } else {
            Issue.record("decoded event was not trashSucceeded")
        }
    }

    // MARK: - syncTransitions

    @Test("syncTransitions renders only non-zero counts in the message")
    func syncTransitionsCompactRender() {
        let t = Tail.from(entry(.syncTransitions(
            editsProtected: 2,
            editsQuarantined: 0,
            confirmedFromChangeLog: 5,
            confirmedFromOrphanSweep: 0
        )))
        #expect(t.event == "sync.trans")
        #expect(t.message.contains("edit-prot=2"))
        #expect(t.message.contains("conf-cl=5"))
        #expect(!t.message.contains("edit-q="))
        #expect(!t.message.contains("conf-orph="))
    }

    @Test("syncTransitions with orphan-sweep confirmations bumps severity to .warn")
    func syncTransitionsOrphanSweepWarns() {
        let withOrphan = Tail.from(entry(.syncTransitions(
            editsProtected: 0, editsQuarantined: 0,
            confirmedFromChangeLog: 0, confirmedFromOrphanSweep: 3
        )))
        #expect(withOrphan.severity == .warn)
        let withoutOrphan = Tail.from(entry(.syncTransitions(
            editsProtected: 1, editsQuarantined: 1,
            confirmedFromChangeLog: 1, confirmedFromOrphanSweep: 0
        )))
        #expect(withoutOrphan.severity == .info)
    }

    @Test("syncTransitions with all zero counts renders as 'no transitions'")
    func syncTransitionsAllZero() {
        let t = Tail.from(entry(.syncTransitions(
            editsProtected: 0, editsQuarantined: 0,
            confirmedFromChangeLog: 0, confirmedFromOrphanSweep: 0
        )))
        #expect(t.message == "no transitions")
    }
}

/// Coverage for the new chronological batch builder. `from(entries:)`
/// walks entries oldest→newest, threading prev `syncCompleted` counts
/// forward so sync rows can render `(+N)` deltas. Each test pins one
/// transition rule. Pure data — no UI involvement.
@Suite("JournalTailEntry — from(entries:) sync deltas")
struct JournalTailEntryBatchTests {
    private typealias Tail = CairnFixtures.JournalTailEntry
    private let runId = "2026-04-21T17:57:15Z-034389BC"
    private let ts = Date(timeIntervalSince1970: 1_745_200_000)

    private func sync(indexed: Int, candidates: Int = 0, pending: Int = 0) -> JournalEntry {
        JournalEntry(timestamp: ts, runId: runId, event: .syncCompleted(
            indexed: indexed, candidates: candidates, pendingReview: pending,
            deferredLarge: 0, deferredLargeBytes: 0, deferredTimeout: 0, elapsedMs: 100
        ))
    }

    @Test("first sync row has no delta clause")
    func firstSyncNoDelta() {
        let out = Tail.from(entries: [sync(indexed: 100)])
        #expect(out.count == 1)
        #expect(out[0].message.contains("indexed=100"))
        #expect(!out[0].message.contains("(+"))
        #expect(!out[0].message.contains("(-"))
    }

    @Test("subsequent sync renders positive delta vs previous")
    func positiveDelta() {
        let out = Tail.from(entries: [sync(indexed: 100), sync(indexed: 110, candidates: 2)])
        // Second row's message must show indexed=110 (+10) and cand=2 (+2).
        #expect(out[1].message.contains("indexed=110 (+10)"))
        #expect(out[1].message.contains("cand=2 (+2)"))
    }

    @Test("subsequent sync renders negative delta vs previous")
    func negativeDelta() {
        let out = Tail.from(entries: [sync(indexed: 100), sync(indexed: 95)])
        #expect(out[1].message.contains("indexed=95 (-5)"))
    }

    @Test("zero-delta sync omits the parenthetical")
    func zeroDelta() {
        let out = Tail.from(entries: [sync(indexed: 100), sync(indexed: 100)])
        #expect(out[1].message.contains("indexed=100"))
        // No (+0) / (-0) noise.
        #expect(!out[1].message.contains("(+0)"))
        #expect(!out[1].message.contains("(-0)"))
    }

    @Test("non-sync events between syncs do not reset the delta baseline")
    func nonSyncDoesNotReset() {
        let trashEvent = JournalEntry(timestamp: ts, runId: runId, event: .trashSucceeded(assetIds: ["a"], durationMs: nil))
        let out = Tail.from(entries: [sync(indexed: 100), trashEvent, sync(indexed: 105)])
        // The sync at index 2 should still compute its delta against
        // the sync at index 0, not reset because of the trash event in between.
        #expect(out[2].message.contains("indexed=105 (+5)"))
    }
}

private extension JSONDecoder {
    /// ISO-8601 decoder matching the encoder used in
    /// `JournalTailEntry.encodeRawJSON` so test round-trips pass.
    static var cairnIso8601: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
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
        let raw = "firstRunNotDryRun — the first run on a fresh observed store must be a dry-run"
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
            .thresholdExceeded(candidateCount: 12, assetsInObserved: 1024, percent: 0.0117, limit: 0.01),
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

    @Test("same-day timestamps render as HH:mm under .h24")
    func sameDay() {
        let now = Date()
        // Build a date earlier today by subtracting a few hours.
        let earlier = Calendar.current.date(byAdding: .minute, value: -125, to: now) ?? now
        let formatted = Tail.formatTime(earlier, now: now, format: .h24)
        // `HH:mm` is exactly 5 characters, with a colon. Pinned to
        // `.h24` rather than `.system` because the `j` skeleton in
        // .system resolves to the host locale's hour cycle — en_US
        // gives `h:mm a` (7 chars), making the assertion locale-
        // dependent. The journal-tail format under .h24 is the
        // contract being pinned here.
        #expect(formatted.count == 5)
        #expect(formatted.contains(":"))
    }

    @Test("past-day timestamps render as MMM d HH:mm under .h24")
    func pastDay() {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now
        let formatted = Tail.formatTime(yesterday, now: now, format: .h24)
        // Past-day form contains a colon (HH:mm) AND a space (between
        // the date and time fragments). Same-day form has no space.
        #expect(formatted.contains(":"))
        #expect(formatted.contains(" "))
    }
}
