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
        try await journal.append(.init(runId: runId, event: .tagApplied(tagId: "t1", tagValue: "cairn/\(runId)", assetIds: assetIds, durationMs: nil)))
        try await journal.append(.init(runId: runId, event: .trashSucceeded(assetIds: assetIds, durationMs: nil)))
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
        try await journal.append(.init(runId: "LIVE", event: .trashSucceeded(assetIds: ["still-1", "video-1"], durationMs: nil)))
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
        try await journal.append(.init(runId: "LIVE", event: .trashSucceeded(assetIds: ["still-1", "video-1"], durationMs: nil)))

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
        try await journal.append(.init(runId: "R", event: .trashSucceeded(assetIds: ["still-1", "video-1", "solo-2"], durationMs: nil)))
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

        await #expect(throws: FakeError.self) {
            _ = try await orch.restore(fromRunId: "R-ORDER")
        }

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

        await #expect(throws: FakeError.self) {
            _ = try await orch.restore(fromRunId: "R-MSG")
        }

        let entries = try await journal.readAll()
        let messages = entries.compactMap { entry -> String? in
            if case .restoreFailed(_, _, let message, _) = entry.event { return message }
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

        await #expect(throws: FakeError.self) {
            _ = try await orch.restore(fromRunId: "R-SUB", assetIds: ["a2", "a3"])
        }

        let entries = try await journal.readAll()
        let failedIds = entries.compactMap { entry -> [String]? in
            if case .restoreFailed(_, let ids, _, _) = entry.event { return ids }
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
        try await journal.append(.init(runId: "LIVE-FAIL", event: .trashSucceeded(assetIds: ["still-1", "video-1"], durationMs: nil)))
        try await journal.append(.init(runId: "LIVE-FAIL", event: .runCompleted(deletedCount: 2)))

        let writer = FakeWriter()
        await writer.setFailRestore(FakeError(message: "boom"))
        let orch = RestoreOrchestrator(writer: writer, journal: journal)

        await #expect(throws: FakeError.self) {
            _ = try await orch.restore(fromRunId: "LIVE-FAIL", assetIds: ["still-1"])
        }

        let entries = try await journal.readAll()
        let failedIds = entries.compactMap { entry -> [String]? in
            if case .restoreFailed(_, let ids, _, _) = entry.event { return ids }
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
        try await journal.append(.init(runId: "TRASH-FAILED", event: .tagApplied(tagId: "t1", tagValue: "cairn/v1/run/TRASH-FAILED", assetIds: ["a1", "a2"], durationMs: nil)))
        try await journal.append(.init(runId: "TRASH-FAILED", event: .trashFailed(assetIds: ["a1", "a2"], message: "server-500", httpStatus: nil)))

        let writer = FakeWriter()
        let orch = RestoreOrchestrator(writer: writer, journal: journal)
        await #expect(throws: RestoreError.self) {
            _ = try await orch.restore(fromRunId: "TRASH-FAILED")
        }
        #expect(await writer.restoredBatches.isEmpty)
    }

    /// Empty `explicitIds` set is rejected with `RestoreError.emptyAssetIds`
    /// before the journal is touched. Pass `nil` to mean "restore the whole
    /// run" — `[]` is almost always a programming bug (an upstream filter
    /// excluded everything) and silently writing a `restoreSucceeded([])`
    /// hides that.
    @Test("empty explicitIds is rejected with RestoreError.emptyAssetIds — no journal write, no writer call")
    func emptyExplicitIdsRejected() async throws {
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }
        try await seedTrashRun(journal, runId: "R-EMPTY", assetIds: ["a1", "a2"])

        let writer = FakeWriter()
        let orch = RestoreOrchestrator(writer: writer, journal: journal)

        await #expect {
            _ = try await orch.restore(fromRunId: "R-EMPTY", assetIds: [])
        } throws: { error in
            guard case RestoreError.emptyAssetIds(let runId) = error else { return false }
            return runId == "R-EMPTY"
        }

        // Writer never called.
        #expect(await writer.restoredBatches.isEmpty)

        // Journal carries only the seeded trash-run events — no
        // restoreStarted / restoreSucceeded / restoreFailed.
        let entries = try await journal.readAll()
        let restoreEvents = entries.filter {
            switch $0.event {
            case .restoreStarted, .restoreSucceeded, .restoreFailed: return true
            default: return false
            }
        }
        #expect(restoreEvents.isEmpty)
    }

    /// Immich's `POST /api/trash/restore/assets` returns 204 even for
    /// IDs that didn't actually move out of trash (already-restored,
    /// hard-deleted, or permissions-blocked). The orchestrator
    /// post-restores by calling `fetchAssets` and partitions the
    /// requested set into actually-restored (journaled as
    /// `restoreSucceeded`) and still-trashed (journaled as
    /// `restoreFailed` with an explanatory message). The summary
    /// reflects the verified set, not the requested one.
    @Test("partial server restore: journal records actually-restored vs still-trashed via post-call verification")
    func partialServerRestoreVerifiedAgainstFetch() async throws {
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }
        try await seedTrashRun(journal, runId: "R-OVER", assetIds: ["a1", "a2", "a3"])

        // Server claims success on the restore call but only `a2`
        // actually moved out of trash; `a1` and `a3` remain trashed.
        // `fetchAssets` is what the orchestrator uses to learn this.
        let writer = FakeWriter()
        await writer.setFetchAssetsHandler { ids in
            ids.map { id in
                ServerAsset(
                    id: id,
                    checksum: Checksum(base64: "ck-\(id)"),
                    isTrashed: id != "a2"
                )
            }
        }
        let orch = RestoreOrchestrator(writer: writer, journal: journal)
        let summary = try await orch.restore(fromRunId: "R-OVER")

        // Summary reflects what the verification call actually
        // confirmed — only `a2`, not the full requested set.
        #expect(summary.restoredAssetIds == ["a2"])

        let entries = try await journal.readAll()
        let succeeded = entries.compactMap { entry -> [String]? in
            if case .restoreSucceeded(_, let ids, _) = entry.event { return ids }
            return nil
        }
        let failed = entries.compactMap { entry -> ([String], String)? in
            if case .restoreFailed(_, let ids, let message, _) = entry.event { return (ids, message) }
            return nil
        }
        #expect(succeeded == [["a2"]])
        #expect(failed.count == 1)
        #expect(failed.first?.0 == ["a1", "a3"])
        #expect(failed.first?.1.contains("remain in trash") == true)
    }

    /// Verification fetch failure (transient network blip on the
    /// follow-up read, after the actual restore call already
    /// succeeded): the orchestrator can't tell what really happened,
    /// so it falls back to the writer's optimistic signal — journals
    /// `restoreSucceeded` with the full requested set rather than
    /// stranding the run in `restoreFailed` for a verification-only
    /// failure.
    @Test("post-restore verification failure: falls back to optimistic restoreSucceeded with full requested set")
    func verificationFailureFallsBackOptimistic() async throws {
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }
        try await seedTrashRun(journal, runId: "R-VERIFY-FAIL", assetIds: ["a1", "a2"])

        let writer = FakeWriter()
        await writer.setFailFetchAssets(FakeError(message: "network-blip-during-verify"))
        let orch = RestoreOrchestrator(writer: writer, journal: journal)
        let summary = try await orch.restore(fromRunId: "R-VERIFY-FAIL")

        #expect(summary.restoredAssetIds == ["a1", "a2"])

        let entries = try await journal.readAll()
        let succeeded = entries.compactMap { entry -> [String]? in
            if case .restoreSucceeded(_, let ids, _) = entry.event { return ids }
            return nil
        }
        #expect(succeeded == [["a1", "a2"]])
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
