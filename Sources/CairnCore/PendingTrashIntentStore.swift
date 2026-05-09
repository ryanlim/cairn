import Foundation

/// A user-confirmed trash request that hasn't successfully been
/// applied to the Immich server yet.
///
/// `confirmTrash` enqueues an intent on every failure (network down,
/// 5xx, anything transient). The retry driver later drains the queue
/// when conditions look better — successful sync, manual "Retry now"
/// tap, or any other trigger the host wires up.
///
/// `runId` is shared across every attempt for the same user-intent.
/// Immich's `tags` API is upsert-by-name, so retries that get past
/// tag creation join the same audit trail rather than littering the
/// server with one tag per attempt. The journal sees one logical run
/// regardless of how many retries it took to land.
///
/// `assets` carries the full `ServerAsset` payload (not just the IDs)
/// because `TrashOrchestrator.run(candidates:...)` needs the live-photo
/// pairing to compute the full delete batch. Storing IDs alone would
/// force a per-retry `fetchAssets(ids:)` round-trip just to rebuild
/// the same payload we already had at enqueue time.
public struct PendingTrashIntent: Codable, Sendable, Hashable {
    public let id: UUID
    public let createdAt: Date
    public let runId: String
    public let assets: [ServerAsset]
    public let assetsInPurview: Int
    public var lastAttemptedAt: Date?
    public var attemptCount: Int
    public var lastError: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date,
        runId: String,
        assets: [ServerAsset],
        assetsInPurview: Int,
        lastAttemptedAt: Date? = nil,
        attemptCount: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.runId = runId
        self.assets = assets
        self.assetsInPurview = assetsInPurview
        self.lastAttemptedAt = lastAttemptedAt
        self.attemptCount = attemptCount
        self.lastError = lastError
    }

    /// Checksums in the intent's asset set. Used for conflict pruning
    /// (e.g., "the user just excluded one of these — drop the intent").
    public var checksums: Set<Checksum> {
        Set(assets.map(\.checksum))
    }
}

/// Persistent queue of trash intents that failed and want retrying.
///
/// Account-scoped: lives inside the per-(URL, userId) partition like
/// `ExclusionStore` and `ConfirmedDeletedStore`. Different accounts on
/// the same device do not share retry queues — a failure under
/// account A must not be retried under account B's credentials.
///
/// Conflict pruning is the caller's responsibility — when the user
/// excludes a checksum or restores a run, the host should call
/// `removeIntents(containingAnyOf:)` or `remove(matchingRunId:)` to
/// keep the queue from re-trashing things the user just decided to
/// keep. Doing it at enqueue/exclude time (rather than at retry time)
/// makes the UI snappy: the pending-trash banner ticks down the
/// instant the user acts.
public protocol PendingTrashIntentStore: Sendable {
    func snapshot() async throws -> [PendingTrashIntent]
    func enqueue(_ intent: PendingTrashIntent) async throws
    func update(_ id: UUID, lastAttemptedAt: Date, attemptCount: Int, lastError: String?) async throws
    func remove(_ ids: Set<UUID>) async throws
    func remove(matchingRunId runId: String) async throws
    func removeIntents(containingAnyOf checksums: Set<Checksum>) async throws
    func count() async throws -> Int
}

public extension PendingTrashIntentStore {
    func remove(_ id: UUID) async throws {
        try await remove(Set([id]))
    }
}

/// JSON-file impl. Same shape as the other JSONFile* stores —
/// atomic writes, stable on-disk ordering for diffability, used by
/// the CLI and by tests that want a real on-disk store without
/// SwiftData's container ceremony.
public actor JSONFilePendingTrashIntentStore: PendingTrashIntentStore {
    public let path: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(path: URL) {
        self.path = path
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    public init(filePath: String) {
        self.init(path: URL(fileURLWithPath: filePath))
    }

    public func snapshot() async throws -> [PendingTrashIntent] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let data = try Data(contentsOf: path)
        guard !data.isEmpty else { return [] }
        let intents = try decoder.decode([PendingTrashIntent].self, from: data)
        return intents.sorted { $0.createdAt < $1.createdAt }
    }

    public func enqueue(_ intent: PendingTrashIntent) async throws {
        var current = try await snapshot()
        current.append(intent)
        try writeAll(current)
    }

    public func update(_ id: UUID, lastAttemptedAt: Date, attemptCount: Int, lastError: String?) async throws {
        var current = try await snapshot()
        guard let idx = current.firstIndex(where: { $0.id == id }) else { return }
        current[idx].lastAttemptedAt = lastAttemptedAt
        current[idx].attemptCount = attemptCount
        current[idx].lastError = lastError
        try writeAll(current)
    }

    public func remove(_ ids: Set<UUID>) async throws {
        guard !ids.isEmpty else { return }
        var current = try await snapshot()
        let before = current.count
        current.removeAll { ids.contains($0.id) }
        guard current.count != before else { return }
        try writeAll(current)
    }

    public func remove(matchingRunId runId: String) async throws {
        var current = try await snapshot()
        let before = current.count
        current.removeAll { $0.runId == runId }
        guard current.count != before else { return }
        try writeAll(current)
    }

    public func removeIntents(containingAnyOf checksums: Set<Checksum>) async throws {
        guard !checksums.isEmpty else { return }
        var current = try await snapshot()
        let before = current.count
        current.removeAll { intent in
            !intent.checksums.isDisjoint(with: checksums)
        }
        guard current.count != before else { return }
        try writeAll(current)
    }

    public func count() async throws -> Int {
        try await snapshot().count
    }

    // MARK: - Private

    private func writeAll(_ intents: [PendingTrashIntent]) throws {
        let sorted = intents.sorted { $0.createdAt < $1.createdAt }
        let data = try encoder.encode(sorted)
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = path.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: path.path) {
            _ = try FileManager.default.replaceItemAt(path, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: path)
        }
    }
}
