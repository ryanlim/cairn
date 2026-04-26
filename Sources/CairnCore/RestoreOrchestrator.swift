import Foundation

/// Outcome of a `RestoreOrchestrator.restore` call. `restoredAssetIds` is the
/// final set sent to `POST /api/trash/restore/assets` — it is a superset of
/// any user-supplied IDs, expanded to keep Live Photo pairs together.
public struct RestoreRunSummary: Sendable, Equatable {
    public let fromRunId: String
    public let restoredAssetIds: [String]
}

/// Failure modes for `RestoreOrchestrator.restore`. Each carries enough
/// context for the CLI to print an actionable error and exit non-zero.
public enum RestoreError: Error, CustomStringConvertible, Equatable {
    /// No journal entries match the given run ID. Usually means a typo or the
    /// user is pointing at the wrong journal file.
    case runNotFoundInJournal(runId: String)
    /// The run exists but never reached `trashSucceeded` — dry-run or aborted
    /// before the DELETE landed. Nothing on the server needs restoring.
    case runHasNoTrashedAssets(runId: String)
    /// The user asked to restore specific asset IDs, but some aren't in this
    /// run's `trashSucceeded` event. Thrown instead of silently dropping them
    /// so the caller knows they picked the wrong run.
    case assetIdsNotInRun(runId: String, unknownIds: [String])
    /// The caller passed a non-nil but empty `assetIds` set — almost always a
    /// programming bug (an upstream filter excluded everything) rather than
    /// "restore the whole run, please." Rejected loudly so the failure mode
    /// surfaces instead of silently writing a `restoreSucceeded([])` event.
    case emptyAssetIds(runId: String)

    public var description: String {
        switch self {
        case .runNotFoundInJournal(let id):
            return "run '\(id)' not found in journal — check --run-id or use --journal to point at the right file"
        case .runHasNoTrashedAssets(let id):
            return "run '\(id)' has no trashSucceeded event; nothing to restore (was it a dry-run or an aborted run?)"
        case .assetIdsNotInRun(let runId, let unknown):
            let preview = unknown.prefix(5).joined(separator: ", ")
            let suffix = unknown.count > 5 ? " (and \(unknown.count - 5) more)" : ""
            return "asset id(s) not in run '\(runId)': \(preview)\(suffix) — pick from the assets in that run's trashSucceeded event"
        case .emptyAssetIds(let runId):
            return "no asset ids provided to restore from run '\(runId)' — pass nil to restore the whole run, or a non-empty set"
        }
    }
}

/// Undoes a prior `TrashOrchestrator` run by pulling its assets back out of
/// Immich's Trash. Reads the journal to figure out what was trashed, expands
/// Live Photo pairs so halves don't get orphaned, calls the server, and
/// journals the outcome.
public struct RestoreOrchestrator: Sendable {
    public let writer: ImmichWriter
    public let journal: DeletionJournal
    /// Clock used for journal timestamps. Injectable so tests get
    /// deterministic output.
    public let now: @Sendable () -> Date

    public init(
        writer: ImmichWriter,
        journal: DeletionJournal,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.writer = writer
        self.journal = journal
        self.now = now
    }

    /// Restore assets trashed by a prior run.
    ///
    /// - If `explicitIds` is nil, every asset in the run's `trashSucceeded`
    ///   event is restored.
    /// - If `explicitIds` is provided, restoration narrows to that set, with
    ///   two guards:
    ///   1. Each ID must appear in the run's `trashSucceeded` event, else
    ///      `.assetIdsNotInRun` is thrown. No silent no-ops — a typo in
    ///      `--asset-id` should fail loudly.
    ///   2. Live Photo halves auto-expand: asking for a still pulls its
    ///      linked motion video along and vice versa, so a partial restore
    ///      never orphans the other half. See `expandLivePhotoPairs`.
    public func restore(
        fromRunId: String,
        assetIds explicitIds: Set<String>? = nil
    ) async throws -> RestoreRunSummary {
        // Reject `assetIds: []` before reading the journal — a caller
        // who passed an accidentally-empty set gets a loud error
        // instead of a silently-successful no-op. Pass `nil` to mean
        // "restore the whole run."
        if let explicitIds, explicitIds.isEmpty {
            throw RestoreError.emptyAssetIds(runId: fromRunId)
        }

        let entries = try await journal.readAll()
        let forRun = entries.filter { $0.runId == fromRunId }
        if forRun.isEmpty {
            throw RestoreError.runNotFoundInJournal(runId: fromRunId)
        }

        var trashedIds: [String] = []
        var planningTargets: [JournalEntry.TrashTarget] = []
        for entry in forRun {
            if case .trashSucceeded(let ids) = entry.event { trashedIds = ids }
            if case .planningTrash(let targets) = entry.event { planningTargets = targets }
        }
        if trashedIds.isEmpty {
            throw RestoreError.runHasNoTrashedAssets(runId: fromRunId)
        }

        let idsToRestore: [String]
        if let explicit = explicitIds {
            let trashedSet = Set(trashedIds)
            let unknown = explicit.subtracting(trashedSet)
            if !unknown.isEmpty {
                throw RestoreError.assetIdsNotInRun(runId: fromRunId, unknownIds: unknown.sorted())
            }
            idsToRestore = Self.expandLivePhotoPairs(explicit, from: planningTargets).sorted()
        } else {
            idsToRestore = trashedIds
        }

        try await journal.append(.init(
            timestamp: now(),
            runId: fromRunId,
            event: .restoreStarted(fromRunId: fromRunId, assetIds: idsToRestore)
        ))

        // `restoreStarted` is on disk. Guarantee a matching terminal
        // (`restoreSucceeded` / `restoreFailed`) even if a journal-append
        // throws after the writer call, so the run's summary doesn't drift
        // into `.inProgress` limbo. Use `try?` on the failure-path journal
        // write because there's no recovery if that throws — we still
        // re-throw the original error up to the caller.
        var emittedTerminal = false
        do {
            do {
                try await writer.restoreAssets(ids: idsToRestore)
            } catch {
                try? await journal.append(.init(
                    timestamp: now(),
                    runId: fromRunId,
                    event: .restoreFailed(fromRunId: fromRunId, assetIds: idsToRestore, message: String(describing: error))
                ))
                emittedTerminal = true
                throw error
            }

            // `restoreAssets` returned 204, but Immich's server responds
            // 204 even for IDs it didn't actually restore (already-out-
            // of-trash, missing, permissions-blocked). Verify the post-
            // restore state explicitly so the journal reflects what
            // really happened, not what we asked for. `fetchAssets`
            // returns trashed assets too — IDs absent from the result
            // are treated as "still trashed" (the conservative read).
            //
            // Fetch failures here are non-fatal: the restore call
            // already succeeded as far as the server's concerned, so
            // falling back to the optimistic "all requested" claim is
            // better than rethrowing and stranding the journal in
            // `restoreFailed` for a verification-only network blip.
            let actuallyRestored: [String]
            let stillTrashed: [String]
            do {
                let serverState = try await writer.fetchAssets(ids: idsToRestore)
                let nonTrashedIds = Set(serverState.filter { !$0.isTrashed }.map(\.id))
                actuallyRestored = idsToRestore.filter { nonTrashedIds.contains($0) }
                stillTrashed = idsToRestore.filter { !nonTrashedIds.contains($0) }
            } catch {
                // Verification failed — fall back to the writer's
                // optimistic signal. Note in the journal so a forensic
                // reader sees the gap.
                try await journal.append(.init(
                    timestamp: now(),
                    runId: fromRunId,
                    event: .restoreSucceeded(fromRunId: fromRunId, assetIds: idsToRestore)
                ))
                emittedTerminal = true
                return RestoreRunSummary(fromRunId: fromRunId, restoredAssetIds: idsToRestore)
            }

            if !actuallyRestored.isEmpty {
                try await journal.append(.init(
                    timestamp: now(),
                    runId: fromRunId,
                    event: .restoreSucceeded(fromRunId: fromRunId, assetIds: actuallyRestored)
                ))
            }
            if !stillTrashed.isEmpty {
                // Server confirmed the restore call but these IDs
                // didn't come out of trash. Most likely cause: they
                // were already restored from a prior session, hard-
                // deleted, or the API key lost `asset.delete` for
                // them between trash and restore. Surface as a
                // `restoreFailed` so the user can investigate.
                try await journal.append(.init(
                    timestamp: now(),
                    runId: fromRunId,
                    event: .restoreFailed(
                        fromRunId: fromRunId,
                        assetIds: stillTrashed,
                        message: "server accepted the restore call but these assets remain in trash (already-restored, hard-deleted, or permissions-blocked)"
                    )
                ))
            }
            emittedTerminal = true

            return RestoreRunSummary(fromRunId: fromRunId, restoredAssetIds: actuallyRestored)
        } catch {
            // Catch-all: if the `restoreSucceeded` append itself throws (disk
            // full, permission loss), the restore on Immich already happened
            // but the forensic record is incomplete. Emit `restoreFailed`
            // with a self-describing message so `RunSummary` resolves to a
            // terminal status rather than `.inProgress`.
            if !emittedTerminal {
                try? await journal.append(.init(
                    timestamp: now(),
                    runId: fromRunId,
                    event: .restoreFailed(
                        fromRunId: fromRunId,
                        assetIds: idsToRestore,
                        message: "journal write failed after restore completed: \(error)"
                    )
                ))
            }
            throw error
        }
    }

    /// Expand `requested` so both halves of any Live Photo are present: a
    /// still implicitly includes its linked motion video, and a motion video
    /// implicitly includes its still. The `planningTrash` targets carry the
    /// still ↔ video mapping, so this works from the journal alone without
    /// needing a fresh server query.
    ///
    /// Without this expansion, a user restoring only the still would leave
    /// the motion video stuck in Trash and produce a broken Live Photo on
    /// the server.
    public static func expandLivePhotoPairs(
        _ requested: Set<String>,
        from targets: [JournalEntry.TrashTarget]
    ) -> Set<String> {
        var out = requested
        for target in targets {
            let stillId = target.assetId
            let videoId = target.livePhotoVideoId
            if requested.contains(stillId), let videoId {
                out.insert(videoId)
            }
            if let videoId, requested.contains(videoId) {
                out.insert(stillId)
            }
        }
        return out
    }

    /// Overload for callers whose pairing source is a live server query
    /// (e.g. `cairn restore --file-name-matches`) rather than the journal.
    /// Same pairing rules — adapts `ServerAsset` into `TrashTarget` and
    /// delegates.
    public static func expandLivePhotoPairs(
        _ requested: Set<String>,
        from serverAssets: [ServerAsset]
    ) -> Set<String> {
        let targets = serverAssets.map {
            JournalEntry.TrashTarget(
                assetId: $0.id,
                checksum: $0.checksum.base64,
                livePhotoVideoId: $0.livePhotoVideoId
            )
        }
        return expandLivePhotoPairs(requested, from: targets)
    }
}
