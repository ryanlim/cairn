import Foundation

public struct RestoreRunSummary: Sendable, Equatable {
    public let fromRunId: String
    public let restoredAssetIds: [String]
}

public enum RestoreError: Error, CustomStringConvertible, Equatable {
    case runNotFoundInJournal(runId: String)
    case runHasNoTrashedAssets(runId: String)

    public var description: String {
        switch self {
        case .runNotFoundInJournal(let id):
            return "run '\(id)' not found in journal — check --run-id or use --journal to point at the right file"
        case .runHasNoTrashedAssets(let id):
            return "run '\(id)' has no trashSucceeded event; nothing to restore (was it a dry-run or an aborted run?)"
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

    /// Restore every asset successfully trashed by the given trash-run. Reads the
    /// journal to find the asset IDs (no extra server round-trip to resolve a tag),
    /// calls Immich's trash/restore/assets endpoint, then journals its own events
    /// with a fresh run ID so the restore itself is traceable.
    public func restore(fromRunId: String) async throws -> RestoreRunSummary {
        let entries = try await journal.readAll()
        let forRun = entries.filter { $0.runId == fromRunId }
        if forRun.isEmpty {
            throw RestoreError.runNotFoundInJournal(runId: fromRunId)
        }
        var assetIds: [String] = []
        for entry in forRun {
            if case .trashSucceeded(let ids) = entry.event {
                assetIds = ids
            }
        }
        if assetIds.isEmpty {
            throw RestoreError.runHasNoTrashedAssets(runId: fromRunId)
        }

        try await journal.append(.init(
            timestamp: now(),
            runId: fromRunId,
            event: .restoreStarted(fromRunId: fromRunId, assetIds: assetIds)
        ))

        do {
            try await writer.restoreAssets(ids: assetIds)
        } catch {
            try await journal.append(.init(
                timestamp: now(),
                runId: fromRunId,
                event: .restoreFailed(fromRunId: fromRunId, assetIds: assetIds, message: String(describing: error))
            ))
            throw error
        }

        try await journal.append(.init(
            timestamp: now(),
            runId: fromRunId,
            event: .restoreSucceeded(fromRunId: fromRunId, assetIds: assetIds)
        ))

        return RestoreRunSummary(fromRunId: fromRunId, restoredAssetIds: assetIds)
    }
}
