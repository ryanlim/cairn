import Foundation
import Testing
@testable import CairnCore

/// Stable, explicit name for each `JournalEntry.Event` case. Use this
/// instead of `String(describing: event)` — the latter relies on
/// Swift's enum-case-printing format (case name followed by associated
/// values in parens), which is not part of any stable API. A Swift
/// upgrade or associated-value-shape change to one of these cases
/// could silently break every `hasPrefix(...)` assertion.
fileprivate func eventName(_ event: JournalEntry.Event) -> String {
    switch event {
    case .runStarted: return "runStarted"
    case .planningTrash: return "planningTrash"
    case .tagApplied: return "tagApplied"
    case .trashSucceeded: return "trashSucceeded"
    case .trashFailed: return "trashFailed"
    case .runCompleted: return "runCompleted"
    case .runAborted: return "runAborted"
    case .restoreStarted: return "restoreStarted"
    case .restoreSucceeded: return "restoreSucceeded"
    case .restoreFailed: return "restoreFailed"
    case .assetsExcluded: return "assetsExcluded"
    case .pendingReview: return "pendingReview"
    case .syncCompleted: return "syncCompleted"
    case .syncTransitions: return "syncTransitions"
    }
}

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
        #expect(summary.breadcrumbTag?.value == "cairn/v1/run/RUN-1")
        #expect(await writer.upsertedTagValues == ["cairn/v1/run/RUN-1"])
        #expect(await writer.trashedBatches == [["a1", "a2"]])

        let entries = try await journal.readAll()
        let kinds = entries.map { eventName($0.event) }
        #expect(kinds.contains("runStarted"))
        #expect(kinds.contains("planningTrash"))
        #expect(kinds.contains("tagApplied"))
        #expect(kinds.contains("trashSucceeded"))
        #expect(kinds.contains("runCompleted"))
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

    /// Pins the "breadcrumb stays on server after a partial-failure run"
    /// semantic. Tag is upserted + applied *before* the DELETE call,
    /// so if the DELETE throws, the server has:
    ///   - the `cairn/v1/run/<id>` tag committed
    ///   - the tag applied to the candidate asset IDs
    ///   - the assets themselves still live (not trashed)
    ///
    /// That's the intended shape — the tag is a breadcrumb, not a state
    /// flag. `cairn history` will find the tag on live, non-trashed
    /// assets; that tells the user "this run attempted to trash these
    /// and the server rejected it," which is the whole point of the
    /// breadcrumb. The journal's `trashFailed` event is the local-side
    /// mirror of the same fact.
    /// `upsertTag` is the first writer call and runs BEFORE any
    /// journal write. If it throws (network down, server 500), the
    /// orchestrator throws cleanly without leaving any journal
    /// residue — no `runStarted`, no `runAborted`. The intent is
    /// preserved by the caller's retry queue (iOS `PendingTrashIntentStore`)
    /// or surfaced as a CLI exit code.
    ///
    /// Why no journal entries: a network blip on every offline trash
    /// attempt would otherwise leave a fake "aborted" run in the
    /// user's history. The retry queue is the authoritative record.
    @Test("upsertTag failure: no tag, no trash, no journal entries — retry queue is the record")
    func upsertTagFailureAbortsBeforeAnyJournalWrite() async throws {
        let writer = FakeWriter()
        await writer.setFailTag(FakeError(message: "tag-500"))
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }

        let orch = TrashOrchestrator(writer: writer, journal: journal)
        await #expect(throws: FakeError.self) {
            _ = try await orch.run(
                runId: "TAG-FAIL",
                candidates: [asset("a1", "ck1"), asset("a2", "ck2")],
                assetsInPurview: 100,
                dryRun: false
            )
        }

        // No server-side state: tag never landed, nothing tagged,
        // nothing trashed.
        #expect(await writer.upsertedTagValues.isEmpty)
        #expect(await writer.taggedBatches.isEmpty)
        #expect(await writer.trashedBatches.isEmpty)

        // No journal residue. The retry queue handles intent
        // persistence; the journal records actual server-touching
        // runs only.
        let entries = try await journal.readAll()
        #expect(entries.isEmpty)
    }

    /// `bulkTagAssets` runs after `upsertTag`. If it 500s the tag is
    /// already committed on the server, so the orchestrator does a
    /// best-effort `deleteTag` cleanup before re-throwing the original
    /// error. No `tagApplied` event is written (that fires only on a
    /// successful bulk-tag call), and the journal still resolves to
    /// `runAborted` for the run summary.
    ///
    /// The cleanup keeps the server's tag list tidy after a failure —
    /// without it, every transient bulk-tag 500 would leave an empty
    /// `cairn/v1/run/<id>` tag behind for the user to garbage-collect
    /// manually.
    @Test("bulkTagAssets failure: orchestrator cleans up the orphan tag with deleteTag before re-throwing")
    func bulkTagAssetsFailureCleansUpOrphanTag() async throws {
        let writer = FakeWriter()
        await writer.setFailBulkTag(FakeError(message: "bulk-tag-500"))
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }

        let orch = TrashOrchestrator(writer: writer, journal: journal)
        await #expect(throws: FakeError.self) {
            _ = try await orch.run(
                runId: "BULK-FAIL",
                candidates: [asset("a1", "ck1"), asset("a2", "ck2")],
                assetsInPurview: 100,
                dryRun: false
            )
        }

        // upsertTag landed (the tag was created on the server) but
        // bulk-tag threw, so taggedBatches is empty and nothing was
        // trashed. The orchestrator then called `deleteTag` to remove
        // the orphan.
        #expect(await writer.upsertedTagValues == ["cairn/v1/run/BULK-FAIL"])
        #expect(await writer.taggedBatches.isEmpty)
        #expect(await writer.trashedBatches.isEmpty)
        #expect(await writer.deletedTagIds == ["tag-uuid-1"])

        let entries = try await journal.readAll()
        let events = entries.map { eventName($0.event) }
        #expect(events.contains("runStarted"))
        #expect(events.contains("planningTrash"))
        #expect(events.contains("runAborted"))
        #expect(!events.contains("tagApplied"))
        #expect(!events.contains("trashSucceeded"))
        #expect(!events.contains("trashFailed"))
        #expect(!events.contains("runCompleted"))
    }

    /// If the cleanup `deleteTag` ALSO fails (e.g. server now down),
    /// the original `bulkTagAssets` error is what surfaces — the
    /// cleanup-failure is swallowed (best-effort). The user's error
    /// message stays the actionable one ("bulk-tag-500") rather than
    /// being masked by the secondary cleanup failure.
    @Test("bulkTagAssets failure + deleteTag failure: original bulk-tag error surfaces; cleanup failure is swallowed")
    func bulkTagAssetsFailureWithCleanupFailureSurfacesOriginalError() async throws {
        let writer = FakeWriter()
        await writer.setFailBulkTag(FakeError(message: "bulk-tag-500"))
        await writer.setFailDeleteTag(FakeError(message: "delete-tag-500"))
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }

        let orch = TrashOrchestrator(writer: writer, journal: journal)
        await #expect {
            _ = try await orch.run(
                runId: "BULK-FAIL-CLEANUP-FAIL",
                candidates: [asset("a1", "ck1")],
                assetsInPurview: 50,
                dryRun: false
            )
        } throws: { error in
            guard let fake = error as? FakeError else { return false }
            return fake.message == "bulk-tag-500"
        }

        // The orphan-cleanup attempt happened (deleteTagIds is empty
        // because the call threw), but the original bulk-tag failure
        // is what bubbles up.
        #expect(await writer.deletedTagIds.isEmpty)
    }

    /// Pin the no-journal-residue invariant for an upsertTag failure.
    /// The retry queue records the intent; the journal stays clean.
    /// (Sister to `bulkTagAssetsFailureEventOrderIsExact`, which DOES
    /// expect a journal record because the failure is past the first
    /// network call — there's real partial state worth surfacing.)
    @Test("upsertTag failure: journal is empty (retry queue is the record)")
    func upsertTagFailureProducesNoJournalEntries() async throws {
        let writer = FakeWriter()
        await writer.setFailTag(FakeError(message: "tag-500"))
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }

        let orch = TrashOrchestrator(writer: writer, journal: journal)
        _ = try? await orch.run(
            runId: "ORDER",
            candidates: [asset("a1", "ck1")],
            assetsInPurview: 50,
            dryRun: false
        )

        let entries = try await journal.readAll()
        #expect(entries.isEmpty)
    }

    /// Sister to `upsertTagFailureEventOrderIsExact`: same ordering
    /// invariant, but with the failure one step further along the
    /// pipeline. The tag exists on the server but `bulkTagAssets`
    /// threw, so the journal still resolves to `runAborted` (not
    /// `tagApplied` — that event is only emitted after a successful
    /// bulk tag call).
    @Test("bulkTagAssets failure: journal event order is runStarted → planningTrash → runAborted, exactly once each")
    func bulkTagAssetsFailureEventOrderIsExact() async throws {
        let writer = FakeWriter()
        await writer.setFailBulkTag(FakeError(message: "bulk-tag-500"))
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }

        let orch = TrashOrchestrator(writer: writer, journal: journal)
        _ = try? await orch.run(
            runId: "ORDER-BULK",
            candidates: [asset("a1", "ck1")],
            assetsInPurview: 50,
            dryRun: false
        )

        let entries = try await journal.readAll()
        let kinds = entries.map { eventName($0.event) }
        #expect(kinds == ["runStarted", "planningTrash", "runAborted"])
    }

    /// `runAborted`'s `reason` string is forensically useful — it
    /// surfaces as the abort reason in `RunSummary` and is what the
    /// CLI prints when a user runs `cairn journal show --last`.
    /// Pin that the underlying error's `description` makes it into
    /// the reason string, so a server message ("bulk-tag-500") stays
    /// recoverable from the journal alone.
    @Test("bulkTagAssets failure: runAborted.reason carries the underlying error description")
    func bulkTagAssetsFailureReasonContainsErrorMessage() async throws {
        let writer = FakeWriter()
        await writer.setFailBulkTag(FakeError(message: "bulk-tag-500"))
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }

        let orch = TrashOrchestrator(writer: writer, journal: journal)
        _ = try? await orch.run(
            runId: "REASON",
            candidates: [asset("a1", "ck1")],
            assetsInPurview: 50,
            dryRun: false
        )

        let entries = try await journal.readAll()
        let aborted = entries.compactMap { entry -> String? in
            if case .runAborted(let reason) = entry.event { return reason }
            return nil
        }
        #expect(aborted.count == 1)
        #expect(aborted.first?.contains("bulk-tag-500") == true)
    }

    @Test("trash failure after tag: cairn/v1 tag and tagApplied remain, trashFailed is the terminal")
    func trashFailureLeavesBreadcrumbOnServer() async throws {
        let writer = FakeWriter()
        await writer.setFailTrash(FakeError(message: "server-500"))
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }

        let candidates = [asset("a1", "ck1"), asset("a2", "ck2")]
        let orch = TrashOrchestrator(writer: writer, journal: journal)
        await #expect(throws: FakeError.self) {
            _ = try await orch.run(
                runId: "PARTIAL",
                candidates: candidates,
                assetsInPurview: 100,
                dryRun: false
            )
        }

        // Tag was created AND applied on the server before trash threw.
        #expect(await writer.upsertedTagValues == ["cairn/v1/run/PARTIAL"])
        let tagged = await writer.taggedBatches
        #expect(tagged.count == 1)
        #expect(tagged[0].assetIds.sorted() == ["a1", "a2"])
        // DELETE never committed.
        #expect(await writer.trashedBatches.isEmpty)

        // Journal: tagApplied + trashFailed, NO trashSucceeded.
        // `trashFailed` is the terminal — the orchestrator's
        // `emittedTerminal` flag prevents an extra `runAborted` or
        // `runCompleted` from landing on top of it.
        let entries = try await journal.readAll()
        let events = entries.map { eventName($0.event) }
        #expect(events.contains("tagApplied"))
        #expect(events.contains("trashFailed"))
        #expect(!events.contains("trashSucceeded"))
        #expect(!events.contains("runCompleted"))
    }
}
