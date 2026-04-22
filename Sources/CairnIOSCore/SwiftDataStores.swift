import Foundation
import SwiftData
import CairnCore

// MARK: - @Model types

/// SwiftData row for `EverSeenStore`. One row per checksum the device has
/// ever observed locally.
///
/// `base64` is `@Attribute(.unique)` so that SwiftData (well, the underlying
/// SQLite store) enforces dedup at the schema level. This is preferable to
/// dedup-on-insert in Swift because:
///   1. It collapses the "snapshot, diff, write" round trip on `union(_:)`
///      into a straight insert-and-let-the-store-reject-duplicates pattern.
///   2. Concurrent writers from two `SwiftDataEverSeenStore` actors over the
///      same container can't race their way to a duplicate row.
///
/// Note: `@Model` classes are reference types and *not* `Sendable`. They
/// must never escape the actor that owns the `ModelContext` they were
/// fetched on. The actors below convert to plain `Checksum` values before
/// returning anything to callers.
@Model
final class StoredEverSeenChecksum {
    @Attribute(.unique) var base64: String

    init(base64: String) {
        self.base64 = base64
    }
}

/// SwiftData row for `ExclusionStore`. Keyed by `checksumBase64` (unique).
///
/// The metadata fields are stored as plain columns rather than a nested
/// `ExclusionMetadata` value because SwiftData prefers flat schemas and we
/// gain nothing by nesting — there is one metadata blob per checksum and
/// the protocol surface only ever returns flattened `ExclusionMetadata`
/// values to callers.
@Model
final class StoredExclusion {
    @Attribute(.unique) var checksumBase64: String
    var addedAt: Date
    var fromRunId: String?
    var reason: String?

    init(checksumBase64: String, addedAt: Date, fromRunId: String?, reason: String?) {
        self.checksumBase64 = checksumBase64
        self.addedAt = addedAt
        self.fromRunId = fromRunId
        self.reason = reason
    }
}

/// SwiftData row for `ConfirmedDeletedStore`. One row per checksum that
/// has been observed in iOS's Recently Deleted album. Same `.unique`-on-
/// `base64` pattern as `StoredEverSeenChecksum`.
@Model
final class StoredConfirmedDeletedChecksum {
    @Attribute(.unique) var base64: String

    init(base64: String) {
        self.base64 = base64
    }
}

// MARK: - Container helper

/// Factory for the shared `ModelContainer` that backs the iOS app's
/// SwiftData stores. The four `SwiftData*Store` actors are expected to be
/// constructed from the same container so they end up writing to one
/// underlying SQLite file owned by the app.
public enum CairnSwiftDataContainer {
    /// Build a `ModelContainer` over every `@Model` type in this file.
    ///
    /// - Parameters:
    ///   - url: Optional explicit on-disk location for the SQLite store.
    ///     When `nil`, SwiftData uses its default app-support location
    ///     (`Application Support/default.store` inside the app's data
    ///     container). Tests should pass `inMemory: true` instead of a
    ///     temp URL so each test gets a fully isolated store with no
    ///     filesystem cleanup.
    ///   - inMemory: When `true`, the container lives only in RAM. Used
    ///     by tests so they can run in parallel without sharing state.
    public static func make(url: URL? = nil, inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([
            StoredEverSeenChecksum.self,
            StoredExclusion.self,
            StoredConfirmedDeletedChecksum.self,
        ])
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        } else if let url {
            configuration = ModelConfiguration(url: url)
        } else {
            configuration = ModelConfiguration()
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

// MARK: - SwiftDataEverSeenStore

/// SwiftData-backed `EverSeenStore`.
///
/// **Why a plain `actor` instead of `@ModelActor`?** `@ModelActor` synthesizes
/// an init that takes a `ModelContainer` and a custom `Executor`, and gives
/// you a `modelContext` property. That sounds nice, but it bakes in a
/// specific isolation model that is more restrictive than what we need
/// (e.g. you can't easily share fetch helpers across actors, and the
/// generated init makes it awkward to expose other parameters). A plain
/// actor with an internally-owned `ModelContext` is just as Sendable-safe —
/// the `ModelContext` never escapes the actor — and gives us full control
/// over the init shape.
public actor SwiftDataEverSeenStore: EverSeenStore {
    private let container: ModelContainer
    private let context: ModelContext

    public init(container: ModelContainer) {
        self.container = container
        // Each actor owns its own context so all SwiftData calls happen on
        // a single isolation domain (this actor's). Sharing a context
        // across isolation boundaries is the SwiftData footgun this design
        // avoids.
        self.context = ModelContext(container)
    }

    public func snapshot() async throws -> Set<Checksum> {
        let descriptor = FetchDescriptor<StoredEverSeenChecksum>()
        let rows = try context.fetch(descriptor)
        var out: Set<Checksum> = []
        out.reserveCapacity(rows.count)
        for row in rows {
            out.insert(Checksum(base64: row.base64))
        }
        return out
    }

    public func union(_ additions: Set<Checksum>) async throws {
        guard !additions.isEmpty else { return }
        // Diff against current state so we don't issue inserts that the
        // unique index will reject. The unique constraint *would* save us,
        // but pre-filtering keeps insert-then-save predictable across
        // SwiftData versions (some have surfaced unique-violations as
        // throws on save rather than silent drops).
        let existing = try snapshotBase64Set()
        for checksum in additions where !existing.contains(checksum.base64) {
            context.insert(StoredEverSeenChecksum(base64: checksum.base64))
        }
        // SwiftData does not auto-persist; explicit save is required.
        try context.save()
    }

    private func snapshotBase64Set() throws -> Set<String> {
        let descriptor = FetchDescriptor<StoredEverSeenChecksum>()
        let rows = try context.fetch(descriptor)
        var out: Set<String> = []
        out.reserveCapacity(rows.count)
        for row in rows {
            out.insert(row.base64)
        }
        return out
    }
}

// MARK: - SwiftDataExclusionStore

/// SwiftData-backed `ExclusionStore`. Same actor/context pattern as
/// `SwiftDataEverSeenStore`. See that type's doc comment for the rationale
/// on plain-actor-vs-`@ModelActor`.
public actor SwiftDataExclusionStore: ExclusionStore {
    private let container: ModelContainer
    private let context: ModelContext

    public init(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    public func snapshot() async throws -> [Checksum: ExclusionMetadata] {
        let descriptor = FetchDescriptor<StoredExclusion>()
        let rows = try context.fetch(descriptor)
        var out: [Checksum: ExclusionMetadata] = [:]
        out.reserveCapacity(rows.count)
        for row in rows {
            out[Checksum(base64: row.checksumBase64)] = ExclusionMetadata(
                addedAt: row.addedAt,
                fromRunId: row.fromRunId,
                reason: row.reason
            )
        }
        return out
    }

    public func isExcluded(_ checksum: Checksum) async throws -> Bool {
        // Targeted predicate fetch on the unique attribute — cheaper than
        // pulling every row just to test membership.
        let base64 = checksum.base64
        var descriptor = FetchDescriptor<StoredExclusion>(
            predicate: #Predicate<StoredExclusion> { $0.checksumBase64 == base64 }
        )
        descriptor.fetchLimit = 1
        let rows = try context.fetch(descriptor)
        return !rows.isEmpty
    }

    public func insert(_ entries: [Checksum: ExclusionMetadata]) async throws {
        guard !entries.isEmpty else { return }
        for (checksum, metadata) in entries {
            let base64 = checksum.base64
            var descriptor = FetchDescriptor<StoredExclusion>(
                predicate: #Predicate<StoredExclusion> { $0.checksumBase64 == base64 }
            )
            descriptor.fetchLimit = 1
            if let existing = try context.fetch(descriptor).first {
                // Last-writer-wins: overwrite the metadata fields in place.
                // Mutating a fetched `@Model` instance is the SwiftData
                // idiom for updates; no separate `update` call is needed.
                existing.addedAt = metadata.addedAt
                existing.fromRunId = metadata.fromRunId
                existing.reason = metadata.reason
            } else {
                context.insert(StoredExclusion(
                    checksumBase64: base64,
                    addedAt: metadata.addedAt,
                    fromRunId: metadata.fromRunId,
                    reason: metadata.reason
                ))
            }
        }
        try context.save()
    }

    public func remove(_ checksums: Set<Checksum>) async throws {
        guard !checksums.isEmpty else { return }
        var changed = false
        for checksum in checksums {
            let base64 = checksum.base64
            var descriptor = FetchDescriptor<StoredExclusion>(
                predicate: #Predicate<StoredExclusion> { $0.checksumBase64 == base64 }
            )
            descriptor.fetchLimit = 1
            // Silent no-op when absent — protocol contract: `remove` is
            // forgiving so `cairn exclude --remove` never errors on
            // double-runs.
            if let existing = try context.fetch(descriptor).first {
                context.delete(existing)
                changed = true
            }
        }
        guard changed else { return }
        try context.save()
    }
}

// MARK: - SwiftDataConfirmedDeletedStore

/// SwiftData-backed `ConfirmedDeletedStore`. Mirrors `SwiftDataEverSeenStore`
/// in shape — append-only set of base64 checksums, dedup at the schema level
/// via a unique attribute. See `SwiftDataEverSeenStore` for the rationale on
/// plain-actor-vs-`@ModelActor`.
public actor SwiftDataConfirmedDeletedStore: ConfirmedDeletedStore {
    private let container: ModelContainer
    private let context: ModelContext

    public init(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    public func snapshot() async throws -> Set<Checksum> {
        let descriptor = FetchDescriptor<StoredConfirmedDeletedChecksum>()
        let rows = try context.fetch(descriptor)
        var out: Set<Checksum> = []
        out.reserveCapacity(rows.count)
        for row in rows {
            out.insert(Checksum(base64: row.base64))
        }
        return out
    }

    public func union(_ additions: Set<Checksum>) async throws {
        guard !additions.isEmpty else { return }
        let existing = try snapshotBase64Set()
        for checksum in additions where !existing.contains(checksum.base64) {
            context.insert(StoredConfirmedDeletedChecksum(base64: checksum.base64))
        }
        try context.save()
    }

    private func snapshotBase64Set() throws -> Set<String> {
        let descriptor = FetchDescriptor<StoredConfirmedDeletedChecksum>()
        let rows = try context.fetch(descriptor)
        var out: Set<String> = []
        out.reserveCapacity(rows.count)
        for row in rows {
            out.insert(row.base64)
        }
        return out
    }
}
