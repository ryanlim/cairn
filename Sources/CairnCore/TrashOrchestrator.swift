import Foundation

/// Minimal write-side surface of the Immich API. Conformed to by `ImmichClient`
/// and by test fakes. Defining it here (not on the client) keeps the orchestrator
/// independent of HTTP plumbing.
public protocol ImmichWriter: Sendable {
    func upsertTag(value: String) async throws -> ImmichTag
    func bulkTagAssets(tagIds: [String], assetIds: [String]) async throws
    func trashAssets(ids: [String]) async throws
}

public struct ImmichTag: Sendable, Equatable {
    public let id: String
    public let value: String
    public init(id: String, value: String) {
        self.id = id
        self.value = value
    }
}

extension ImmichClient: ImmichWriter {}

public struct TrashRunSummary: Sendable, Equatable {
    public let runId: String
    public let trashedAssetIds: [String]
    public let breadcrumbTag: ImmichTag?
    public let aborted: Bool
    public let abortReason: String?
}

public struct TrashOrchestrator: Sendable {
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

    /// Executes the destructive path for a set of candidates. Order is fixed:
    /// 1. Journal `runStarted` and `planningTrash` (write-ahead log).
    /// 2. Create/upsert breadcrumb tag, bulk-apply to candidates, journal it.
    /// 3. DELETE assets (force=false → trash), journal success or failure.
    /// 4. Journal `runCompleted`.
    ///
    /// Live Photo: any candidate with a non-nil `livePhotoVideoId` includes that
    /// linked video UUID in the trash batch (the still and motion video are
    /// separate Immich assets; we want both gone together).
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

        if candidates.isEmpty {
            try await journal.append(.init(
                timestamp: now(),
                runId: runId,
                event: .runCompleted(deletedCount: 0)
            ))
            return TrashRunSummary(runId: runId, trashedAssetIds: [], breadcrumbTag: nil, aborted: false, abortReason: nil)
        }

        let targets = candidates.map { JournalEntry.TrashTarget(
            assetId: $0.id,
            checksum: $0.checksum.base64,
            livePhotoVideoId: $0.livePhotoVideoId
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
            return TrashRunSummary(runId: runId, trashedAssetIds: [], breadcrumbTag: nil, aborted: false, abortReason: nil)
        }

        let tagValue = "cairn/\(runId)"
        let tag = try await writer.upsertTag(value: tagValue)
        try await writer.bulkTagAssets(tagIds: [tag.id], assetIds: allIds)
        try await journal.append(.init(
            timestamp: now(),
            runId: runId,
            event: .tagApplied(tagId: tag.id, tagValue: tag.value, assetIds: allIds)
        ))

        do {
            try await writer.trashAssets(ids: allIds)
            try await journal.append(.init(
                timestamp: now(),
                runId: runId,
                event: .trashSucceeded(assetIds: allIds)
            ))
        } catch {
            try await journal.append(.init(
                timestamp: now(),
                runId: runId,
                event: .trashFailed(assetIds: allIds, message: String(describing: error))
            ))
            throw error
        }

        try await journal.append(.init(
            timestamp: now(),
            runId: runId,
            event: .runCompleted(deletedCount: allIds.count)
        ))

        return TrashRunSummary(
            runId: runId,
            trashedAssetIds: allIds,
            breadcrumbTag: tag,
            aborted: false,
            abortReason: nil
        )
    }
}
