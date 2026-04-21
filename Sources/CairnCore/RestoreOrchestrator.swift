import Foundation

public struct RestoreRunSummary: Sendable, Equatable {
    public let fromRunId: String
    public let restoredAssetIds: [String]
}

public enum RestoreError: Error, CustomStringConvertible, Equatable {
    case runNotFoundInJournal(runId: String)
    case runHasNoTrashedAssets(runId: String)
    case assetIdsNotInRun(runId: String, unknownIds: [String])

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
        }
    }
}

public struct RestoreOrchestrator: Sendable {
    public let writer: ImmichWriter
    public let journal: DeletionJournal
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

    /// Restore assets that were trashed by a prior run. If `assetIds` is nil,
    /// every asset the run trashed is restored. If provided, restoration is
    /// narrowed to those IDs — with two guards:
    ///   1. Each ID must appear in that run's `trashSucceeded` event, else
    ///      `.assetIdsNotInRun` is thrown (no silent no-ops).
    ///   2. Live Photo halves auto-expand: requesting a still implicitly
    ///      includes its linked motion video and vice versa, so partial
    ///      restores don't orphan motion videos.
    public func restore(
        fromRunId: String,
        assetIds explicitIds: Set<String>? = nil
    ) async throws -> RestoreRunSummary {
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

        do {
            try await writer.restoreAssets(ids: idsToRestore)
        } catch {
            try await journal.append(.init(
                timestamp: now(),
                runId: fromRunId,
                event: .restoreFailed(fromRunId: fromRunId, assetIds: idsToRestore, message: String(describing: error))
            ))
            throw error
        }

        try await journal.append(.init(
            timestamp: now(),
            runId: fromRunId,
            event: .restoreSucceeded(fromRunId: fromRunId, assetIds: idsToRestore)
        ))

        return RestoreRunSummary(fromRunId: fromRunId, restoredAssetIds: idsToRestore)
    }

    /// Given a user-supplied set of asset IDs and the run's planningTrash
    /// targets, return a superset that always includes both halves of any
    /// Live Photo the user touched — requesting the still includes its
    /// linked motion video, and requesting the video includes the still.
    /// Prevents partial-restore from leaving orphaned motion videos.
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

    /// ServerAsset-flavored overload for when the source of truth is a
    /// server query (e.g. `cairn restore --file-name-matches`) rather than
    /// the local journal. Same pairing rules; different input shape.
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
