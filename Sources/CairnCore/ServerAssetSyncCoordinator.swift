import Foundation
import OSLog

private let coordLog = Logger(subsystem: "app.cairn", category: "sync.stream")

// MARK: - Coordinator

/// Drives the incremental server-asset sync loop. One coordinator per
/// (URL, userId) partition — the same partitioning the rest of the
/// per-server state uses.
///
/// Responsibilities:
/// 1. Decide bootstrap vs. incremental based on the local cache size.
///    On bootstrap (cache empty) the stream request sets `reset: true`
///    so the server flushes any stale checkpoint left over from a
///    prior install against this same API key.
/// 2. Iterate the JSONL change stream, batch events into chunks of
///    `batchSize`, apply each chunk to the cache transactionally.
/// 3. After each successful local apply, POST the chunk's ack ids to
///    the server (advances the server-side cursor) and then persist
///    the highest ack-per-type to the local mirror.
///
/// Crash safety: the local cache is committed before the server is
/// acked, so a crash between local-apply and server-ack replays the
/// already-applied events on the next stream. The cache's
/// `applyEvents` is idempotent (upsert-by-server-id), so replay is a
/// no-op semantically. The opposite ordering — ack server first —
/// would risk losing events forever if the local commit failed.
public actor ServerAssetSyncCoordinator {
    private let client: ImmichClient
    private let cache: any ServerAssetCacheStore
    private let ackStore: any SyncAckStore
    private let clock: @Sendable () -> Date

    public init(
        client: ImmichClient,
        cache: any ServerAssetCacheStore,
        ackStore: any SyncAckStore,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.cache = cache
        self.ackStore = ackStore
        self.clock = clock
    }

    /// Pull every change the server has since our last ack, apply to
    /// the cache, advance both cursors. Returns once the server emits
    /// `SyncCompleteV1` and closes the stream.
    ///
    /// - Parameter batchSize: How many events to accumulate before
    ///   flushing to disk + acking. Smaller batches give finer-grained
    ///   crash safety; larger batches amortize the per-flush save.
    ///   100 is the default — balances disk fsync overhead against
    ///   replay cost on a crash.
    ///
    /// - Throws `ImmichClientError.missingScope(...)` if the API key
    ///   lacks `sync.stream` or `sync.checkpoint.update`. The caller
    ///   should catch this and fall back to the paginated path.
    /// - Throws other `ImmichClientError` variants for transport
    ///   errors. The caller logs and falls back.
    @discardableResult
    public func syncToCache(batchSize: Int = 100) async throws -> SyncRunSummary {
        let start = clock()
        let priorSize = try await cache.size()
        let isBootstrap = priorSize == 0
        let mode: SyncRunSummary.Mode = isBootstrap ? .bootstrap : .incremental
        coordLog.info("[cairn.sync.stream] starting mode=\(mode.rawValue, privacy: .public) priorCache=\(priorSize, privacy: .public)")

        var totalUpserted = 0
        var totalDeleted = 0
        var totalIgnored = 0
        var batch: [SyncEvent] = []
        batch.reserveCapacity(batchSize)
        var highestAckByType: [SyncEntityType: String] = [:]
        var batchesFlushed = 0

        // `reset: true` on bootstrap clears any server-side checkpoint
        // left over from a prior install. Without this, a wipe-and-
        // reinstall of cairn against the same API key could leave the
        // server thinking the client is caught up while the local
        // cache is empty.
        let stream = client.syncStream(types: [.assetsV1], reset: isBootstrap)

        for try await event in stream {
            try Task.checkCancellation()
            batch.append(event)
            if let entityType = Self.entityType(for: event), let ack = event.ack {
                // Last write wins per type — events arrive in
                // server-order so this records the most recent ack.
                highestAckByType[entityType] = ack
            }
            if batch.count >= batchSize {
                let summary = try await flush(&batch, highestAckByType: &highestAckByType)
                totalUpserted += summary.upserted
                totalDeleted += summary.deleted
                totalIgnored += summary.ignored
                batchesFlushed += 1
                let elapsedMs = Int((clock().timeIntervalSince(start) * 1000).rounded())
                coordLog.info("[cairn.sync.stream] batch \(batchesFlushed, privacy: .public) flushed: cache=+\(summary.upserted, privacy: .public)/-\(summary.deleted, privacy: .public) total=+\(totalUpserted, privacy: .public)/-\(totalDeleted, privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms")
            }
        }

        if !batch.isEmpty {
            let summary = try await flush(&batch, highestAckByType: &highestAckByType)
            totalUpserted += summary.upserted
            totalDeleted += summary.deleted
            totalIgnored += summary.ignored
        }

        let duration = Int((clock().timeIntervalSince(start) * 1000).rounded())
        coordLog.info("[cairn.sync.stream] complete: upserted=\(totalUpserted, privacy: .public) deleted=\(totalDeleted, privacy: .public) ignored=\(totalIgnored, privacy: .public) durationMs=\(duration, privacy: .public)")
        return SyncRunSummary(
            mode: mode,
            upserted: totalUpserted,
            deleted: totalDeleted,
            ignored: totalIgnored,
            durationMs: duration
        )
    }

    // MARK: - Private

    /// Apply the batch to the cache, ack the server, persist the
    /// highest-per-type ack to the local mirror, clear the batch in
    /// place. The ordering — cache → server → local cursor — is the
    /// crash-safety guarantee: a failure between cache-apply and
    /// server-ack replays events idempotently; a failure between
    /// server-ack and local-cursor-write leaves the local cursor
    /// trailing but still correct.
    private func flush(
        _ batch: inout [SyncEvent],
        highestAckByType: inout [SyncEntityType: String]
    ) async throws -> ApplyEventsSummary {
        // 1. Apply to local cache.
        let summary = try await cache.applyEvents(batch)

        // 2. Ack the server for every event in the batch. We ack
        // *every* ack-bearing event (including the .ignored ones)
        // so the server's cursor stays aligned with what we've seen
        // — even events we chose not to act on need to be marked
        // consumed.
        let ackIds = batch.compactMap { $0.ack }
        if !ackIds.isEmpty {
            // Chunk to the server's max of 1000 per request. In
            // practice batchSize stays well under that, but the cap
            // here is a defensive guard.
            for chunk in ackIds.chunked(into: SyncAckSetRequest.maxAcksPerRequest) {
                try await client.ackSync(chunk)
            }
        }

        // 3. Persist the highest-per-type ack to the local mirror
        // so a future `currentSyncAcks()` diagnostic can compare
        // server vs. local without a network round-trip.
        for (type, ack) in highestAckByType {
            try await ackStore.setAck(ack, for: type)
        }
        highestAckByType.removeAll()
        batch.removeAll(keepingCapacity: true)
        return summary
    }

    /// Map a SyncEvent to its underlying entity type for cursor
    /// bookkeeping. Returns nil for `.ignored` so we don't persist
    /// a cursor under a phantom raw-string type.
    private static func entityType(for event: SyncEvent) -> SyncEntityType? {
        switch event {
        case .asset:
            return .assetV1
        case .assetDeleted:
            return .assetDeleteV1
        case .complete(let type, _):
            return type
        case .ignored:
            return nil
        }
    }
}

// MARK: - SyncRunSummary

/// Reported back to the caller once a coordinator pass finishes. The
/// `mode` distinguishes the first run (cache was empty, stream emitted
/// the full server library) from steady-state syncs.
public struct SyncRunSummary: Sendable, Equatable, Hashable {
    public let mode: Mode
    public let upserted: Int
    public let deleted: Int
    public let ignored: Int
    public let durationMs: Int

    public init(mode: Mode, upserted: Int, deleted: Int, ignored: Int, durationMs: Int) {
        self.mode = mode
        self.upserted = upserted
        self.deleted = deleted
        self.ignored = ignored
        self.durationMs = durationMs
    }

    public enum Mode: String, Sendable, Codable, Hashable {
        case bootstrap
        case incremental
    }
}

// MARK: - Helpers

private extension Array {
    /// Split into contiguous sub-arrays of at most `size` elements.
    /// Returns the whole input as one slice when size >= count, and
    /// an empty result for an empty input.
    func chunked(into size: Int) -> [[Element]] {
        precondition(size > 0, "chunk size must be > 0")
        guard !isEmpty else { return [] }
        var out: [[Element]] = []
        out.reserveCapacity((count + size - 1) / size)
        var index = 0
        while index < count {
            let end = Swift.min(index + size, count)
            out.append(Array(self[index..<end]))
            index = end
        }
        return out
    }
}
