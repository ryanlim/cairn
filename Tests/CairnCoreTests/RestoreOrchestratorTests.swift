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

    @Test("per-asset: restoring a subset only touches the requested assets")
    func perAssetRestoreSubset() async throws {
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }
        try await seedTrashRun(journal, runId: "R1", assetIds: ["a1", "a2", "a3", "a4"])

        let writer = FakeWriter()
        let orch = RestoreOrchestrator(writer: writer, journal: journal)
        let summary = try await orch.restore(fromRunId: "R1", assetIds: ["a2", "a4"])
        #expect(summary.restoredAssetIds == ["a2", "a4"])
        #expect(await writer.restoredBatches == [["a2", "a4"]])
    }

    @Test("per-asset: passing an ID that wasn't in the run throws .assetIdsNotInRun")
    func perAssetRejectsUnknownId() async throws {
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }
        try await seedTrashRun(journal, runId: "R1", assetIds: ["a1", "a2"])

        let writer = FakeWriter()
        let orch = RestoreOrchestrator(writer: writer, journal: journal)
        await #expect(throws: RestoreError.self) {
            _ = try await orch.restore(fromRunId: "R1", assetIds: ["a1", "ghost"])
        }
        #expect(await writer.restoredBatches.isEmpty)
    }

    @Test("Live Photo auto-expand: restoring the still implicitly restores the linked motion video")
    func livePhotoStillExpandsToVideo() async throws {
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }

        try await journal.append(.init(runId: "LIVE", event: .runStarted(dryRun: false, candidateCount: 1, assetsInPurview: 100)))
        try await journal.append(.init(runId: "LIVE", event: .planningTrash(targets: [
            JournalEntry.TrashTarget(assetId: "still-1", checksum: "ck-still", livePhotoVideoId: "video-1")
        ])))
        try await journal.append(.init(runId: "LIVE", event: .trashSucceeded(assetIds: ["still-1", "video-1"])))
        try await journal.append(.init(runId: "LIVE", event: .runCompleted(deletedCount: 2)))

        let writer = FakeWriter()
        let orch = RestoreOrchestrator(writer: writer, journal: journal)
        let summary = try await orch.restore(fromRunId: "LIVE", assetIds: ["still-1"])

        #expect(summary.restoredAssetIds.sorted() == ["still-1", "video-1"])
    }

    @Test("Live Photo auto-expand: restoring the motion video implicitly restores its still")
    func livePhotoVideoExpandsToStill() async throws {
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }

        try await journal.append(.init(runId: "LIVE", event: .planningTrash(targets: [
            JournalEntry.TrashTarget(assetId: "still-1", checksum: "ck-still", livePhotoVideoId: "video-1")
        ])))
        try await journal.append(.init(runId: "LIVE", event: .trashSucceeded(assetIds: ["still-1", "video-1"])))

        let writer = FakeWriter()
        let orch = RestoreOrchestrator(writer: writer, journal: journal)
        let summary = try await orch.restore(fromRunId: "LIVE", assetIds: ["video-1"])
        #expect(summary.restoredAssetIds.sorted() == ["still-1", "video-1"])
    }

    @Test("per-asset: nil assetIds (default) restores the whole run — backward compat")
    func nilMeansFull() async throws {
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }
        try await seedTrashRun(journal, runId: "R1", assetIds: ["a", "b", "c"])

        let writer = FakeWriter()
        let orch = RestoreOrchestrator(writer: writer, journal: journal)
        let summary = try await orch.restore(fromRunId: "R1", assetIds: nil)
        #expect(summary.restoredAssetIds == ["a", "b", "c"])
    }

    @Test("expandLivePhotoPairs(from serverAssets): same pairing semantics as journal-based overload")
    func expandFromServerAssets() {
        let still = ServerAsset(id: "s1", checksum: Checksum(base64: "ck-s"), livePhotoVideoId: "v1")
        let video = ServerAsset(id: "v1", checksum: Checksum(base64: "ck-v"), livePhotoVideoId: nil)
        let other = ServerAsset(id: "o1", checksum: Checksum(base64: "ck-o"), livePhotoVideoId: nil)

        let fromStill = RestoreOrchestrator.expandLivePhotoPairs(["s1"], from: [still, video, other])
        #expect(fromStill == ["s1", "v1"])

        let fromVideo = RestoreOrchestrator.expandLivePhotoPairs(["v1"], from: [still, video, other])
        #expect(fromVideo == ["s1", "v1"])

        let unrelated = RestoreOrchestrator.expandLivePhotoPairs(["o1"], from: [still, video, other])
        #expect(unrelated == ["o1"])
    }

    /// Pins the load-bearing invariant that makes the explicit-IDs
    /// guard safe against post-expansion leakage:
    ///
    ///     expand(explicit, planningTargets) ⊆ trashedSet
    ///
    /// The guard at the top of `restore(_:assetIds:)` checks
    /// `explicit ⊆ trashedSet` before expansion. Expansion then adds
    /// Live-Photo pair IDs pulled from `planningTargets` — but those
    /// pair IDs were themselves included in the original trash batch
    /// (see `TrashOrchestrator.run`, which trashes `assetId` + its
    /// `livePhotoVideoId` together). So expansion can never introduce
    /// an ID that wasn't in `trashedSet`, and a standalone asset that
    /// wasn't selected must not get pulled in either.
    @Test("explicit-IDs guard + Live Photo expansion: expanded set stays within trashedSet")
    func expansionStaysWithinTrashedSet() async throws {
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }

        // Journal shape: one Live Photo pair + one standalone asset,
        // all of which were trashed together in the original run.
        try await journal.append(.init(runId: "R", event: .runStarted(dryRun: false, candidateCount: 2, assetsInPurview: 100)))
        try await journal.append(.init(runId: "R", event: .planningTrash(targets: [
            JournalEntry.TrashTarget(assetId: "still-1", checksum: "ck-still", livePhotoVideoId: "video-1"),
            JournalEntry.TrashTarget(assetId: "solo-2", checksum: "ck-solo", livePhotoVideoId: nil),
        ])))
        try await journal.append(.init(runId: "R", event: .trashSucceeded(assetIds: ["still-1", "video-1", "solo-2"])))
        try await journal.append(.init(runId: "R", event: .runCompleted(deletedCount: 3)))

        // Restore just the still. Expansion pulls in video-1 (paired);
        // solo-2 is unrelated and must NOT get swept up.
        let writer = FakeWriter()
        let orch = RestoreOrchestrator(writer: writer, journal: journal)
        let summary = try await orch.restore(fromRunId: "R", assetIds: ["still-1"])

        let expanded = Set(summary.restoredAssetIds)
        let trashedSet: Set<String> = ["still-1", "video-1", "solo-2"]
        #expect(expanded.isSubset(of: trashedSet), "expansion MUST stay within trashedSet")
        #expect(expanded == ["still-1", "video-1"])
        #expect(!expanded.contains("solo-2"), "standalone asset must not be pulled in by expansion")

        // The server call reflects the same set — sorted for
        // determinism inside the orchestrator.
        #expect(await writer.restoredBatches == [["still-1", "video-1"]])
    }

    /// Pin the exact journal-event ordering for a writer failure:
    /// `restoreStarted` lands BEFORE the writer call, `restoreFailed`
    /// lands after the writer throws, and `restoreSucceeded` is
    /// suppressed. Important because `JournalReader` resolves a run's
    /// terminal status by the most-recent matching event — a stray
    /// `restoreSucceeded` after a real failure would mask the bug.
    @Test("API failure: journal events are restoreStarted → restoreFailed exactly, in that order")
    func apiFailureEventOrderIsExact() async throws {
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }
        try await seedTrashRun(journal, runId: "R-ORDER", assetIds: ["a1", "a2"])

        let writer = FakeWriter()
        await writer.setFailRestore(FakeError(message: "server-503"))
        let orch = RestoreOrchestrator(writer: writer, journal: journal)

        _ = try? await orch.restore(fromRunId: "R-ORDER")

        // Filter to events from this restore call (skip the seed entries).
        let entries = try await journal.readAll()
        let restoreEvents: [String] = entries.compactMap {
            switch $0.event {
            case .restoreStarted: return "restoreStarted"
            case .restoreSucceeded: return "restoreSucceeded"
            case .restoreFailed: return "restoreFailed"
            default: return nil
            }
        }
        #expect(restoreEvents == ["restoreStarted", "restoreFailed"])
    }

    /// `restoreFailed.message` is the only forensic record of WHY the
    /// restore failed — pin that the underlying error's description
    /// makes it into the message verbatim, so users running
    /// `cairn journal show --run-id X` see the real server response.
    @Test("API failure: restoreFailed.message carries the underlying error description")
    func apiFailureMessageContainsErrorDescription() async throws {
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }
        try await seedTrashRun(journal, runId: "R-MSG", assetIds: ["a1"])

        let writer = FakeWriter()
        await writer.setFailRestore(FakeError(message: "trash-restore-503-rate-limited"))
        let orch = RestoreOrchestrator(writer: writer, journal: journal)

        _ = try? await orch.restore(fromRunId: "R-MSG")

        let entries = try await journal.readAll()
        let messages = entries.compactMap { entry -> String? in
            if case .restoreFailed(_, _, let message) = entry.event { return message }
            return nil
        }
        #expect(messages.count == 1)
        #expect(messages.first?.contains("trash-restore-503-rate-limited") == true)
    }

    /// Subset + writer failure: `restoreFailed.assetIds` records the
    /// REQUESTED subset (the IDs that were sent to the server), not the
    /// full run. This is what the user needs to retry — they don't
    /// want to be told "1000 assets failed" when they only asked to
    /// restore 2.
    @Test("subset + API failure: restoreFailed records the requested subset, not the whole run")
    func subsetApiFailureRecordsRequestedIds() async throws {
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }
        try await seedTrashRun(journal, runId: "R-SUB", assetIds: ["a1", "a2", "a3", "a4"])

        let writer = FakeWriter()
        await writer.setFailRestore(FakeError(message: "boom"))
        let orch = RestoreOrchestrator(writer: writer, journal: journal)

        _ = try? await orch.restore(fromRunId: "R-SUB", assetIds: ["a2", "a3"])

        let entries = try await journal.readAll()
        let failedIds = entries.compactMap { entry -> [String]? in
            if case .restoreFailed(_, let ids, _) = entry.event { return ids }
            return nil
        }
        #expect(failedIds == [["a2", "a3"]])
    }

    /// Live Photo + writer failure: `restoreFailed.assetIds` records
    /// the EXPANDED set (still + linked motion video), matching what
    /// was actually sent to the server. The expansion happens before
    /// the writer call, so the journal must reflect the post-expansion
    /// shape — otherwise a retry from the journal would lose the
    /// pair.
    @Test("Live Photo + API failure: restoreFailed records the expanded pair, not just the requested still")
    func livePhotoApiFailureRecordsExpandedPair() async throws {
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }

        try await journal.append(.init(runId: "LIVE-FAIL", event: .runStarted(dryRun: false, candidateCount: 1, assetsInPurview: 100)))
        try await journal.append(.init(runId: "LIVE-FAIL", event: .planningTrash(targets: [
            JournalEntry.TrashTarget(assetId: "still-1", checksum: "ck-still", livePhotoVideoId: "video-1")
        ])))
        try await journal.append(.init(runId: "LIVE-FAIL", event: .trashSucceeded(assetIds: ["still-1", "video-1"])))
        try await journal.append(.init(runId: "LIVE-FAIL", event: .runCompleted(deletedCount: 2)))

        let writer = FakeWriter()
        await writer.setFailRestore(FakeError(message: "boom"))
        let orch = RestoreOrchestrator(writer: writer, journal: journal)

        _ = try? await orch.restore(fromRunId: "LIVE-FAIL", assetIds: ["still-1"])

        let entries = try await journal.readAll()
        let failedIds = entries.compactMap { entry -> [String]? in
            if case .restoreFailed(_, let ids, _) = entry.event { return ids }
            return nil
        }
        #expect(failedIds == [["still-1", "video-1"]])
    }

    /// A run whose ONLY journal entry is `runStarted` (the trash
    /// process crashed before reaching `planningTrash` /
    /// `trashSucceeded`) should error out as `.runHasNoTrashedAssets`,
    /// matching the dry-run case. The orchestrator never invokes the
    /// writer.
    @Test("partial trash run (only runStarted on disk) throws .runHasNoTrashedAssets")
    func partialTrashRunWithOnlyRunStartedThrows() async throws {
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }

        try await journal.append(.init(runId: "PARTIAL", event: .runStarted(dryRun: false, candidateCount: 5, assetsInPurview: 100)))

        let writer = FakeWriter()
        let orch = RestoreOrchestrator(writer: writer, journal: journal)
        await #expect(throws: RestoreError.self) {
            _ = try await orch.restore(fromRunId: "PARTIAL")
        }
        #expect(await writer.restoredBatches.isEmpty)
    }

    /// A run that reached `tagApplied` but failed at `trashSucceeded`
    /// (the `trashFailureLeavesBreadcrumbOnServer` failure mode of
    /// TrashOrchestrator) is not restorable — there is nothing trashed
    /// on the server to pull back. `RestoreOrchestrator` should throw
    /// `.runHasNoTrashedAssets` and never call the writer.
    @Test("trash run that reached trashFailed (not trashSucceeded) throws .runHasNoTrashedAssets — no server call")
    func trashFailedRunIsNotRestorable() async throws {
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }

        try await journal.append(.init(runId: "TRASH-FAILED", event: .runStarted(dryRun: false, candidateCount: 2, assetsInPurview: 100)))
        try await journal.append(.init(runId: "TRASH-FAILED", event: .planningTrash(targets: [
            JournalEntry.TrashTarget(assetId: "a1", checksum: "ck1", livePhotoVideoId: nil),
            JournalEntry.TrashTarget(assetId: "a2", checksum: "ck2", livePhotoVideoId: nil),
        ])))
        try await journal.append(.init(runId: "TRASH-FAILED", event: .tagApplied(tagId: "t1", tagValue: "cairn/v1/run/TRASH-FAILED", assetIds: ["a1", "a2"])))
        try await journal.append(.init(runId: "TRASH-FAILED", event: .trashFailed(assetIds: ["a1", "a2"], message: "server-500")))

        let writer = FakeWriter()
        let orch = RestoreOrchestrator(writer: writer, journal: journal)
        await #expect(throws: RestoreError.self) {
            _ = try await orch.restore(fromRunId: "TRASH-FAILED")
        }
        #expect(await writer.restoredBatches.isEmpty)
    }

    /// Empty `explicitIds` set is a degenerate case: `unknown` is
    /// empty (passes the guard), expansion of `{}` is `{}`, so the
    /// orchestrator writes `restoreStarted` with `[]`, calls the
    /// writer with `[]` (a no-op for `ImmichClient`), and writes
    /// `restoreSucceeded` with `[]`.
    ///
    /// TODO: this is arguably a footgun — a caller passing an
    /// accidentally-empty set gets a successful no-op rather than
    /// a clear "you didn't ask to restore anything" signal. Worth
    /// reconsidering whether to throw here. Pinning current behavior
    /// for now so any change to it is intentional.
    @Test("empty explicitIds is a no-op success: restoreStarted/Succeeded with [], writer called with []")
    func emptyExplicitIdsIsNoOpSuccess() async throws {
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }
        try await seedTrashRun(journal, runId: "R-EMPTY", assetIds: ["a1", "a2"])

        let writer = FakeWriter()
        let orch = RestoreOrchestrator(writer: writer, journal: journal)
        let summary = try await orch.restore(fromRunId: "R-EMPTY", assetIds: [])

        #expect(summary.restoredAssetIds.isEmpty)
        #expect(await writer.restoredBatches == [[]])

        let entries = try await journal.readAll()
        let started = entries.compactMap { entry -> [String]? in
            if case .restoreStarted(_, let ids) = entry.event { return ids }
            return nil
        }
        let succeeded = entries.compactMap { entry -> [String]? in
            if case .restoreSucceeded(_, let ids) = entry.event { return ids }
            return nil
        }
        #expect(started == [[]])
        #expect(succeeded == [[]])
    }

    /// Documents an actual gap in the orchestrator's failure handling:
    /// `RestoreOrchestrator.restore` trusts the writer's "no error
    /// thrown" signal as proof that all requested IDs were restored.
    /// In reality, Immich's `POST /api/trash/restore/assets` can
    /// silently no-op for IDs that don't exist (or were already
    /// restored, or the API key lacks `asset.delete` for them) — the
    /// HTTP response is still 204. The orchestrator then writes
    /// `restoreSucceeded` with the FULL requested set, even though
    /// some assets remain trashed on the server.
    ///
    /// TODO: out of scope for this test pass, but the fix would be
    /// for `restoreAssets` to return the count actually restored (or
    /// the orchestrator to do a follow-up read), then journal that
    /// number rather than the requested set. Until then, the journal
    /// can over-claim success. Pinning current behavior here so a
    /// future fix has a failing test to flip.
    @Test("partial server restore (writer returns success but server no-ops): journal over-claims restoreSucceeded — TODO")
    func partialServerRestoreOverClaimsSuccess() async throws {
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }
        try await seedTrashRun(journal, runId: "R-OVER", assetIds: ["a1", "a2", "a3"])

        // Writer returns success — that's all the orchestrator can see.
        // In a real partial-restore scenario, the server may have only
        // restored a2 (a1, a3 silently no-op'd because they were
        // already-restored from a prior session, missing, or
        // permissions-blocked). The journal-level invariant we're
        // pinning is the optimistic one: the orchestrator records
        // exactly what it asked for.
        let writer = FakeWriter()
        let orch = RestoreOrchestrator(writer: writer, journal: journal)
        let summary = try await orch.restore(fromRunId: "R-OVER")

        #expect(summary.restoredAssetIds == ["a1", "a2", "a3"])

        let entries = try await journal.readAll()
        let succeeded = entries.compactMap { entry -> [String]? in
            if case .restoreSucceeded(_, let ids) = entry.event { return ids }
            return nil
        }
        // Journal claims all three restored, even though in reality
        // (per the TODO above) we don't actually verify that.
        #expect(succeeded == [["a1", "a2", "a3"]])
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
