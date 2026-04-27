import Foundation

/// Write-side surface of the Immich API the orchestrators depend on. Conformed
/// to by `ImmichClient` and by test fakes. Kept separate from the client so
/// the orchestrator has no knowledge of HTTP plumbing and so tests can
/// substitute deterministic fakes.
public protocol ImmichWriter: Sendable {
    /// Create a tag (or return the existing one) for the given canonical value.
    /// Calls `POST /api/tags`.
    func upsertTag(value: String) async throws -> ImmichTag
    /// Attach `tagIds` to every asset in `assetIds`. Calls `PUT /api/tags/assets`.
    func bulkTagAssets(tagIds: [String], assetIds: [String]) async throws
    /// Delete a tag by id. Calls `DELETE /api/tags/{id}`. Used to clean up
    /// orphan breadcrumb tags when `bulkTagAssets` fails after `upsertTag`
    /// already committed the tag — leaving an empty `cairn/v1/run/<id>` tag
    /// on the server is harmless but forensically untidy.
    func deleteTag(id: String) async throws
    /// Move assets to Immich's Trash folder (30-day retention), not a hard
    /// delete. Calls `DELETE /api/assets` with `force: false`.
    func trashAssets(ids: [String]) async throws
    /// Pull assets back out of Trash. Calls `POST /api/trash/restore/assets`.
    func restoreAssets(ids: [String]) async throws
    /// Fetch the current server-side state of the given asset IDs. Used by
    /// `RestoreOrchestrator` to verify which assets actually moved out of
    /// trash — Immich's `POST /api/trash/restore/assets` returns 204 even
    /// for IDs that don't exist or were already restored, so the response
    /// alone can't tell the orchestrator what happened. Implementations
    /// MUST include trashed assets in the result so callers can read each
    /// asset's `isTrashed` field. Missing IDs (404) are silently dropped —
    /// the caller treats absence as "still trashed" by default.
    func fetchAssets(ids: [String]) async throws -> [ServerAsset]
}

/// A tag as returned by the Immich API. Only the fields cairn reads are
/// modelled; everything else on the server-side DTO is ignored.
public struct ImmichTag: Sendable, Equatable {
    public let id: String
    public let value: String
    public let color: String?
    public let createdAt: Date?

    public init(id: String, value: String, color: String? = nil, createdAt: Date? = nil) {
        self.id = id
        self.value = value
        self.color = color
        self.createdAt = createdAt
    }
}

extension ImmichClient: ImmichWriter {}

/// Outcome of a single `TrashOrchestrator.run` invocation. `breadcrumbTag` is
/// nil when the run was a dry-run or had zero candidates (no tag was created).
public struct TrashRunSummary: Sendable, Equatable {
    public let runId: String
    public let trashedAssetIds: [String]
    public let breadcrumbTag: ImmichTag?
    public let aborted: Bool
    public let abortReason: String?
}

/// Moves a set of server assets into Immich's Trash and writes the journal
/// entries that let `RestoreOrchestrator` (and `cairn history`) reconstruct
/// what happened.
///
/// The destructive path is split across multiple API calls so partial progress
/// is visible in the journal even if the process is killed mid-run. The tag
/// is applied *before* the DELETE so restore still has a breadcrumb if the
/// DELETE itself half-succeeds on the server.
public struct TrashOrchestrator: Sendable {
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

    /// Move `candidates` to Immich's Trash. Fixed sequence:
    ///
    /// 1. Journal `runStarted`, then `planningTrash` (write-ahead log — if we
    ///    crash after this, the restore path still knows what was in-flight).
    /// 2. Upsert `cairn/v1/run/<runId>` as a tag, bulk-apply it to every
    ///    affected asset via `PUT /api/tags/assets`, journal `tagApplied`.
    /// 3. `DELETE /api/assets {force: false}` — moves to Trash (30-day
    ///    retention), not a hard delete. Journal `trashSucceeded` or
    ///    `trashFailed`.
    /// 4. Journal `runCompleted`.
    ///
    /// Live Photos: a still and its motion video are two separate Immich
    /// assets linked by `livePhotoVideoId`. The server does NOT cascade trash
    /// through that link (verified empirically; pinned by
    /// `TrashOrchestratorTests.livePhotoVideoIncluded`). Every candidate's
    /// linked video UUID is added to the batch so the pair moves together —
    /// otherwise a restore that pulls back the still would orphan the video.
    ///
    /// `assetsInPurview` is recorded into the journal for safety-rail context
    /// and is not otherwise used to gate the run; the caller is responsible
    /// for having already run `SafetyRails.evaluate`.
    public func run(
        runId: String,
        candidates: [ServerAsset],
        assetsInPurview: Int,
        dryRun: Bool
    ) async throws -> TrashRunSummary {
        let stillIds = candidates.map(\.id)
        let videoIds = candidates.compactMap(\.livePhotoVideoId)
        let allIds = Array(Set(stillIds + videoIds)).sorted()

        try await journal.append(.init(
            timestamp: now(),
            runId: runId,
            event: .runStarted(
                dryRun: dryRun,
                candidateCount: candidates.count,
                assetsInPurview: assetsInPurview
            )
        ))

        // `runStarted` is on disk. From here on, every throwable step is
        // wrapped so the run terminates with a matching journal event
        // (runCompleted / trashFailed / runAborted) even on an unhandled
        // throw. Without this, a network glitch on `upsertTag` or
        // `bulkTagAssets` would leave a dangling `runStarted` and the summary
        // stuck in `.inProgress` limbo.
        //
        // `emittedTerminal` tracks whether a more-specific terminal
        // (trashFailed, trashSucceeded, runCompleted) already fired; the
        // outer catch only falls back to `runAborted` when nothing else
        // summarized the run.
        var emittedTerminal = false
        do {
            if candidates.isEmpty {
                try await journal.append(.init(
                    timestamp: now(),
                    runId: runId,
                    event: .runCompleted(deletedCount: 0)
                ))
                emittedTerminal = true
                return TrashRunSummary(runId: runId, trashedAssetIds: [], breadcrumbTag: nil, aborted: false, abortReason: nil)
            }

            let targets = candidates.map { JournalEntry.TrashTarget(
                assetId: $0.id,
                checksum: $0.checksum.base64,
                livePhotoVideoId: $0.livePhotoVideoId,
                originalFileName: $0.originalFileName,
                fileCreatedAt: $0.fileCreatedAt
            ) }
            try await journal.append(.init(
                timestamp: now(),
                runId: runId,
                event: .planningTrash(targets: targets)
            ))

            if dryRun {
                try await journal.append(.init(
                    timestamp: now(),
                    runId: runId,
                    event: .runCompleted(deletedCount: 0)
                ))
                emittedTerminal = true
                return TrashRunSummary(runId: runId, trashedAssetIds: [], breadcrumbTag: nil, aborted: false, abortReason: nil)
            }

            let tagValue = TagSchema.runTagValue(runId: runId)
            let tagStart = Date()
            let tag = try await writer.upsertTag(value: tagValue)
            // `upsertTag` committed the tag on the server. If
            // `bulkTagAssets` now fails, the tag is left behind with
            // zero attached assets — harmless for cairn's read paths
            // (lookups by run-id surface nothing) but forensically
            // untidy. Best-effort cleanup: if the bulk-tag call
            // throws, try to delete the just-created tag and
            // re-throw the original error. The cleanup itself is
            // non-fatal; if it also fails, the user-visible error
            // stays the original `bulkTagAssets` failure.
            do {
                try await writer.bulkTagAssets(tagIds: [tag.id], assetIds: allIds)
            } catch {
                try? await writer.deleteTag(id: tag.id)
                throw error
            }
            let tagMs = Int(Date().timeIntervalSince(tagStart) * 1000)
            try await journal.append(.init(
                timestamp: now(),
                runId: runId,
                event: .tagApplied(tagId: tag.id, tagValue: tag.value, assetIds: allIds, durationMs: tagMs)
            ))

            let trashStart = Date()
            do {
                try await writer.trashAssets(ids: allIds)
                let trashMs = Int(Date().timeIntervalSince(trashStart) * 1000)
                try await journal.append(.init(
                    timestamp: now(),
                    runId: runId,
                    event: .trashSucceeded(assetIds: allIds, durationMs: trashMs)
                ))
            } catch {
                try? await journal.append(.init(
                    timestamp: now(),
                    runId: runId,
                    event: .trashFailed(
                        assetIds: allIds,
                        message: String(describing: error),
                        httpStatus: ImmichClientError.httpStatus(from: error)
                    )
                ))
                emittedTerminal = true
                throw error
            }

            try await journal.append(.init(
                timestamp: now(),
                runId: runId,
                event: .runCompleted(deletedCount: allIds.count)
            ))
            emittedTerminal = true

            return TrashRunSummary(
                runId: runId,
                trashedAssetIds: allIds,
                breadcrumbTag: tag,
                aborted: false,
                abortReason: nil
            )
        } catch {
            // Anything thrown between `runStarted` and an expected terminal:
            // emit `runAborted` so the journal summary resolves to `.aborted`
            // instead of `.inProgress`. Skip if a more-specific terminal
            // (`trashFailed`) already fired — JournalReader orders `aborted`
            // above `trashFailed`, so emitting both would mask the useful
            // diagnostic.
            if !emittedTerminal {
                try? await journal.append(.init(
                    timestamp: now(),
                    runId: runId,
                    event: .runAborted(reason: "unexpected failure: \(error)")
                ))
            }
            throw error
        }
    }
}
