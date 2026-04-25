import Foundation
import SwiftData
import CairnCore

// MARK: - @Model types

/// Ever-seen checksum row. One per SHA1 the device has ever observed
/// locally.
///
/// `base64` is `@Attribute(.unique)` so the underlying SQLite store
/// enforces dedup at the schema level. Two wins over dedup-on-insert:
///   1. `union(_:)` collapses from "snapshot, diff, write" to
///      "insert and let the store reject duplicates."
///   2. Concurrent writers from two actors over the same container
///      can't race their way to a duplicate row.
///
/// `@Model` classes are reference types and **not** `Sendable`. They
/// must never escape the actor that owns the `ModelContext` they were
/// fetched on. The actors below convert to `Checksum` values before
/// returning anything to callers.
@Model
final class StoredEverSeenChecksum {
    @Attribute(.unique) var base64: String

    init(base64: String) {
        self.base64 = base64
    }
}

/// Exclusion row. One per excluded checksum, keyed on unique
/// `checksumBase64`. Metadata fields flatten to plain columns rather
/// than nesting an `ExclusionMetadata` — one blob per row, SwiftData
/// prefers flat schemas, and the protocol surface converts back to
/// `ExclusionMetadata` at read time anyway.
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

/// Confirmed-deleted checksum row. One per checksum seen as
/// locally-deleted. `confirmedAt` stamps the first observation;
/// `union` is first-write-wins on that timestamp so the quarantine
/// clock stays stable across re-observations (flapping assets don't
/// reset their clock).
@Model
final class StoredConfirmedDeletedChecksum {
    @Attribute(.unique) var base64: String
    var confirmedAt: Date

    init(base64: String, confirmedAt: Date) {
        self.base64 = base64
        self.confirmedAt = confirmedAt
    }
}

/// Local-hash row. One per `(localIdentifier, checksum)` pair — a
/// `PHAsset` may contribute multiple checksums (Live Photo = still +
/// paired video), so the unique key is the compound
/// `"<localIdentifier>|<base64>"` rather than just `localIdentifier`.
///
/// `modificationDate` duplicates across rows sharing a
/// `localIdentifier` — a per-asset property we flatten onto every row
/// to keep the schema simple. Cheap on disk, simpler queries. Optional
/// so legacy rows (pre-field addition) decode without a migration.
@Model
final class StoredLocalHashEntry {
    @Attribute(.unique) var compoundKey: String
    var localIdentifier: String
    var base64: String
    var modificationDate: Date?

    init(localIdentifier: String, base64: String, modificationDate: Date?) {
        self.compoundKey = "\(localIdentifier)|\(base64)"
        self.localIdentifier = localIdentifier
        self.base64 = base64
        self.modificationDate = modificationDate
    }
}

/// Deferred-hash row. One per asset awaiting a later re-hash. See
/// `CairnCore/DeferredHashStore.swift` for the lifecycle rules.
///
/// `reasonRaw` stores the enum's raw string value rather than using a
/// native enum column. Strings survive schema evolution painlessly —
/// a new defer reason added in a future version decodes to `.tooLarge`
/// (the common case) on older clients rather than throwing.
@Model
final class StoredDeferredHash {
    @Attribute(.unique) var localIdentifier: String
    var reasonRaw: String
    /// `Int64?` so "unknown size" (timeouts, no-resources cases)
    /// round-trips cleanly.
    var sizeBytes: Int64?
    var firstDeferredAt: Date

    init(localIdentifier: String, reasonRaw: String, sizeBytes: Int64?, firstDeferredAt: Date) {
        self.localIdentifier = localIdentifier
        self.reasonRaw = reasonRaw
        self.sizeBytes = sizeBytes
        self.firstDeferredAt = firstDeferredAt
    }
}

/// Persistent-change-token row. Singleton — the store keys off a
/// fixed sentinel id (`"default"`). Token bytes are stored opaque
/// (`NSSecureCoding` output from `PhotoKitPersistentChangeReconciler
/// .archiveToken`); cairn never inspects PhotoKit internals, only
/// round-trips what PhotoKit gives us.
@Model
final class StoredPersistentChangeToken {
    @Attribute(.unique) var singletonId: String
    var tokenData: Data
    var savedAt: Date

    init(tokenData: Data, savedAt: Date) {
        self.singletonId = "default"
        self.tokenData = tokenData
        self.savedAt = savedAt
    }
}

/// Lightweight per-asset metadata captured at insert/update time for
/// the deletion-correlation fallback. See
/// `CairnCore/LocalAssetMetadataStore.swift` for the rationale.
@Model
final class StoredLocalAssetMetadata {
    @Attribute(.unique) var localIdentifier: String
    var originalFileName: String?
    var creationDate: Date?
    var modificationDate: Date?
    var fileSize: Int64?
    var observedAt: Date

    init(
        localIdentifier: String,
        originalFileName: String?,
        creationDate: Date?,
        modificationDate: Date?,
        fileSize: Int64?,
        observedAt: Date
    ) {
        self.localIdentifier = localIdentifier
        self.originalFileName = originalFileName
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.fileSize = fileSize
        self.observedAt = observedAt
    }
}

@Model
final class StoredThumbnail {
    @Attribute(.unique) var assetId: String
    var thumbhashData: Data?
    var thumbnailData: Data?
    var createdAt: Date

    init(assetId: String, thumbhashData: Data? = nil, thumbnailData: Data? = nil, createdAt: Date = Date()) {
        self.assetId = assetId
        self.thumbhashData = thumbhashData
        self.thumbnailData = thumbnailData
        self.createdAt = createdAt
    }
}

// MARK: - Container helper

/// Factory for the shared `ModelContainer` behind the iOS app's
/// SwiftData stores. All `SwiftData*Store` actors are expected to
/// share one container so they end up writing to a single underlying
/// SQLite file.
public enum CairnSwiftDataContainer {
    /// Build a `ModelContainer` for device-local state shared across
    /// all servers (local hash cache, deferred hash queue).
    public static func makeGlobal(url: URL? = nil, inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([
            StoredLocalHashEntry.self,
            StoredDeferredHash.self,
            StoredLocalAssetMetadata.self,
        ])
        return try container(schema: schema, url: url, inMemory: inMemory)
    }

    /// Build a `ModelContainer` for per-server state (ever-seen,
    /// exclusions, confirmed-deleted, persistent-change token).
    public static func makePerServer(url: URL, inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([
            StoredEverSeenChecksum.self,
            StoredExclusion.self,
            StoredConfirmedDeletedChecksum.self,
            StoredPersistentChangeToken.self,
            StoredThumbnail.self,
        ])
        return try container(schema: schema, url: inMemory ? nil : url, inMemory: inMemory)
    }

    /// Legacy factory — all six model types in one container. Used
    /// only by tests and the one-shot migration path.
    public static func make(url: URL? = nil, inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([
            StoredEverSeenChecksum.self,
            StoredExclusion.self,
            StoredConfirmedDeletedChecksum.self,
            StoredLocalHashEntry.self,
            StoredDeferredHash.self,
            StoredPersistentChangeToken.self,
            StoredThumbnail.self,
            StoredLocalAssetMetadata.self,
        ])
        return try container(schema: schema, url: url, inMemory: inMemory)
    }

    private static func container(schema: Schema, url: URL?, inMemory: Bool) throws -> ModelContainer {
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
/// **Why a plain `actor` instead of `@ModelActor`.** `@ModelActor`
/// synthesizes an init taking a `ModelContainer` + custom `Executor`
/// and exposes a `modelContext` property. Convenient, but it bakes
/// in a more restrictive isolation model than we need — sharing
/// fetch helpers across actors gets awkward and the generated init
/// doesn't leave room for other parameters. A plain actor with an
/// internally-owned `ModelContext` is just as `Sendable`-safe (the
/// context never escapes the actor) with full control over the init.
public actor SwiftDataEverSeenStore: EverSeenStore {
    private let context: ModelContext

    public init(container: ModelContainer) {
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
        // SwiftData doesn't auto-persist — explicit save required.
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

    /// Wipe every ever-seen row. Called by Settings → Reset index.
    /// Not on the `EverSeenStore` protocol — wiping the index is an
    /// iOS-specific affordance; no Kotlin port or CLI invocation
    /// needs it.
    public func remove(_ checksums: Set<Checksum>) async throws {
        guard !checksums.isEmpty else { return }
        let targets = Set(checksums.map(\.base64))
        var changed = false
        for row in try context.fetch(FetchDescriptor<StoredEverSeenChecksum>()) {
            if targets.contains(row.base64) {
                context.delete(row)
                changed = true
            }
        }
        if changed { try context.save() }
    }

    public func clear() async throws {
        var changed = false
        for row in try context.fetch(FetchDescriptor<StoredEverSeenChecksum>()) {
            context.delete(row)
            changed = true
        }
        if changed { try context.save() }
    }
}

// MARK: - SwiftDataExclusionStore

/// SwiftData-backed `ExclusionStore`. Same actor-with-private-context
/// pattern as `SwiftDataEverSeenStore`; see that type for the
/// plain-actor-vs-`@ModelActor` rationale.
public actor SwiftDataExclusionStore: ExclusionStore {
    private let context: ModelContext

    public init(container: ModelContainer) {
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
        // Predicate fetch on the unique attribute — cheaper than
        // materializing every row just to test membership.
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
                // Last-writer-wins. Mutating a fetched `@Model`
                // instance in place is the SwiftData idiom for
                // updates — no separate `update` call.
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

/// SwiftData-backed `ConfirmedDeletedStore`. One row per confirmed
/// checksum + `confirmedAt` timestamp; schema-level dedup on
/// `base64`. `union(_:at:)` is first-write-wins on `confirmedAt` so
/// the quarantine clock stays stable across re-observations. See
/// `SwiftDataEverSeenStore` for the plain-actor-vs-`@ModelActor`
/// rationale.
public actor SwiftDataConfirmedDeletedStore: ConfirmedDeletedStore {
    private let context: ModelContext

    public init(container: ModelContainer) {
        self.context = ModelContext(container)
    }

    public func snapshot() async throws -> [Checksum: Date] {
        let descriptor = FetchDescriptor<StoredConfirmedDeletedChecksum>()
        let rows = try context.fetch(descriptor)
        var out: [Checksum: Date] = [:]
        out.reserveCapacity(rows.count)
        for row in rows {
            out[Checksum(base64: row.base64)] = row.confirmedAt
        }
        return out
    }

    public func union(_ additions: Set<Checksum>, at timestamp: Date) async throws {
        guard !additions.isEmpty else { return }
        let existing = try snapshotBase64Set()
        var changed = false
        for checksum in additions where !existing.contains(checksum.base64) {
            context.insert(StoredConfirmedDeletedChecksum(base64: checksum.base64, confirmedAt: timestamp))
            changed = true
        }
        if changed { try context.save() }
    }

    public func remove(_ checksums: Set<Checksum>) async throws {
        guard !checksums.isEmpty else { return }
        var changed = false
        for checksum in checksums {
            let base64 = checksum.base64
            var descriptor = FetchDescriptor<StoredConfirmedDeletedChecksum>(
                predicate: #Predicate<StoredConfirmedDeletedChecksum> { $0.base64 == base64 }
            )
            descriptor.fetchLimit = 1
            if let existing = try context.fetch(descriptor).first {
                context.delete(existing)
                changed = true
            }
        }
        if changed { try context.save() }
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

    /// Wipe every confirmed-deleted row. Part of Settings → Reset
    /// index; quarantine clocks reset alongside everything else.
    public func clear() async throws {
        var changed = false
        for row in try context.fetch(FetchDescriptor<StoredConfirmedDeletedChecksum>()) {
            context.delete(row)
            changed = true
        }
        if changed { try context.save() }
    }
}

// MARK: - SwiftDataLocalHashStore

/// SwiftData-backed `LocalHashStore`. See `CairnCore/LocalHashStore.swift`
/// for the caching contract. This impl stores rows keyed on the compound
/// `(localId|base64)` string so SwiftData can enforce uniqueness at the
/// schema level.
public actor SwiftDataLocalHashStore: LocalHashStore {
    private let context: ModelContext

    public init(container: ModelContainer) {
        self.context = ModelContext(container)
    }

    public func snapshot() async throws -> [String: Set<Checksum>] {
        let rows = try context.fetch(FetchDescriptor<StoredLocalHashEntry>())
        var out: [String: Set<Checksum>] = [:]
        for row in rows {
            out[row.localIdentifier, default: []].insert(Checksum(base64: row.base64))
        }
        return out
    }

    /// Count of distinct `localIdentifier`s. SwiftData has no
    /// `SELECT DISTINCT ... COUNT(*)`, so we fetch the id column and
    /// dedupe in memory — a `Set<String>` insert per row. For single-
    /// checksum assets this is one row each; Live Photos (still +
    /// motion video) fold their two rows into one id. Cheaper than
    /// the protocol's default `snapshot().keys.count` because we
    /// never materialize the full `[String: Set<Checksum>]`.
    public func indexedCount() async throws -> Int {
        let rows = try context.fetch(FetchDescriptor<StoredLocalHashEntry>())
        var seen = Set<String>()
        seen.reserveCapacity(rows.count)
        for row in rows {
            seen.insert(row.localIdentifier)
        }
        return seen.count
    }

    /// Just the keys — same shape as `snapshot().keys` but doesn't
    /// materialize the checksum set per row. Used by the orphan
    /// sweep where we only need set-membership over identifiers, not
    /// the actual hashes. Materially faster than `snapshot()` for
    /// libraries with thousands of entries.
    public func allLocalIdentifiers() async throws -> Set<String> {
        let rows = try context.fetch(FetchDescriptor<StoredLocalHashEntry>())
        var ids = Set<String>()
        ids.reserveCapacity(rows.count)
        for row in rows {
            ids.insert(row.localIdentifier)
        }
        return ids
    }

    public func checksums(for localIdentifier: String) async throws -> Set<Checksum> {
        let descriptor = FetchDescriptor<StoredLocalHashEntry>(
            predicate: #Predicate<StoredLocalHashEntry> { $0.localIdentifier == localIdentifier }
        )
        let rows = try context.fetch(descriptor)
        var out: Set<Checksum> = []
        out.reserveCapacity(rows.count)
        for row in rows {
            out.insert(Checksum(base64: row.base64))
        }
        return out
    }

    public func set(_ checksums: Set<Checksum>, for localIdentifier: String, modificationDate: Date?) async throws {
        // Delete the asset's existing rows first — an edit changes the
        // pixel bytes and thus the checksums, so keeping stale rows
        // would leave the store lying about what's currently hashed.
        let staleDescriptor = FetchDescriptor<StoredLocalHashEntry>(
            predicate: #Predicate<StoredLocalHashEntry> { $0.localIdentifier == localIdentifier }
        )
        for row in try context.fetch(staleDescriptor) {
            context.delete(row)
        }
        for checksum in checksums {
            context.insert(StoredLocalHashEntry(
                localIdentifier: localIdentifier,
                base64: checksum.base64,
                modificationDate: modificationDate
            ))
        }
        try context.save()
    }

    public func modificationDate(for localIdentifier: String) async throws -> Date? {
        var descriptor = FetchDescriptor<StoredLocalHashEntry>(
            predicate: #Predicate<StoredLocalHashEntry> { $0.localIdentifier == localIdentifier }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.modificationDate
    }

    public func removeAll(for localIdentifiers: Set<String>) async throws {
        guard !localIdentifiers.isEmpty else { return }
        var changed = false
        for id in localIdentifiers {
            let descriptor = FetchDescriptor<StoredLocalHashEntry>(
                predicate: #Predicate<StoredLocalHashEntry> { $0.localIdentifier == id }
            )
            for row in try context.fetch(descriptor) {
                context.delete(row)
                changed = true
            }
        }
        if changed { try context.save() }
    }

    public func clear() async throws {
        var changed = false
        for row in try context.fetch(FetchDescriptor<StoredLocalHashEntry>()) {
            context.delete(row)
            changed = true
        }
        if changed { try context.save() }
    }
}

// MARK: - SwiftDataDeferredHashStore

/// SwiftData-backed `DeferredHashStore`. Same actor/context pattern
/// as the other stores. `upsert` preserves `firstDeferredAt` on
/// existing rows so a repeatedly-deferred asset shows its true age
/// in the UI rather than looking perpetually fresh.
public actor SwiftDataDeferredHashStore: DeferredHashStore {
    private let context: ModelContext

    public init(container: ModelContainer) {
        self.context = ModelContext(container)
    }

    public func snapshot() async throws -> [DeferredHashEntry] {
        let rows = try context.fetch(FetchDescriptor<StoredDeferredHash>())
        return rows.map(Self.toEntry)
    }

    public func count() async throws -> Int {
        try context.fetchCount(FetchDescriptor<StoredDeferredHash>())
    }

    public func upsert(_ entries: [DeferredHashEntry]) async throws {
        guard !entries.isEmpty else { return }
        for entry in entries {
            let id = entry.localIdentifier
            var descriptor = FetchDescriptor<StoredDeferredHash>(
                predicate: #Predicate<StoredDeferredHash> { $0.localIdentifier == id }
            )
            descriptor.fetchLimit = 1
            if let existing = try context.fetch(descriptor).first {
                // Preserve firstDeferredAt — age is reported across
                // retries, so overwriting it would reset the clock
                // every time we re-encounter the same asset.
                existing.reasonRaw = entry.reason.rawValue
                existing.sizeBytes = entry.sizeBytes
            } else {
                context.insert(StoredDeferredHash(
                    localIdentifier: entry.localIdentifier,
                    reasonRaw: entry.reason.rawValue,
                    sizeBytes: entry.sizeBytes,
                    firstDeferredAt: entry.firstDeferredAt
                ))
            }
        }
        try context.save()
    }

    public func remove(_ localIdentifiers: Set<String>) async throws {
        guard !localIdentifiers.isEmpty else { return }
        var changed = false
        for id in localIdentifiers {
            var descriptor = FetchDescriptor<StoredDeferredHash>(
                predicate: #Predicate<StoredDeferredHash> { $0.localIdentifier == id }
            )
            descriptor.fetchLimit = 1
            if let existing = try context.fetch(descriptor).first {
                context.delete(existing)
                changed = true
            }
        }
        if changed { try context.save() }
    }

    public func clear() async throws {
        var changed = false
        for row in try context.fetch(FetchDescriptor<StoredDeferredHash>()) {
            context.delete(row)
            changed = true
        }
        if changed { try context.save() }
    }

    private static func toEntry(_ row: StoredDeferredHash) -> DeferredHashEntry {
        // Unknown reason (written by a future version) falls back to
        // `.tooLarge`, the common case. Keeps older clients forward-
        // compatible with queue contents from newer versions.
        let reason = DeferredHashEntry.DeferReason(rawValue: row.reasonRaw) ?? .tooLarge
        return DeferredHashEntry(
            localIdentifier: row.localIdentifier,
            reason: reason,
            sizeBytes: row.sizeBytes,
            firstDeferredAt: row.firstDeferredAt
        )
    }
}

// MARK: - SwiftDataLocalAssetMetadataStore

/// SwiftData-backed `LocalAssetMetadataStore`. Records cheap PHAsset
/// metadata at observation time so we have something to correlate
/// against the server when an asset is deleted before it could be
/// hashed.
public actor SwiftDataLocalAssetMetadataStore: LocalAssetMetadataStore {
    private let context: ModelContext

    public init(container: ModelContainer) {
        self.context = ModelContext(container)
    }

    public func metadata(for localIdentifier: String) async throws -> LocalAssetMetadata? {
        var descriptor = FetchDescriptor<StoredLocalAssetMetadata>(
            predicate: #Predicate<StoredLocalAssetMetadata> { $0.localIdentifier == localIdentifier }
        )
        descriptor.fetchLimit = 1
        guard let row = try context.fetch(descriptor).first else { return nil }
        return Self.toEntry(row)
    }

    public func record(_ entries: [LocalAssetMetadata]) async throws {
        guard !entries.isEmpty else { return }
        for entry in entries {
            let id = entry.localIdentifier
            var descriptor = FetchDescriptor<StoredLocalAssetMetadata>(
                predicate: #Predicate<StoredLocalAssetMetadata> { $0.localIdentifier == id }
            )
            descriptor.fetchLimit = 1
            if let existing = try context.fetch(descriptor).first {
                // Preserve `observedAt` — it represents first observation,
                // useful for tracking how long ago we cached this entry.
                existing.originalFileName = entry.originalFileName
                existing.creationDate = entry.creationDate
                existing.modificationDate = entry.modificationDate
                existing.fileSize = entry.fileSize
            } else {
                context.insert(StoredLocalAssetMetadata(
                    localIdentifier: entry.localIdentifier,
                    originalFileName: entry.originalFileName,
                    creationDate: entry.creationDate,
                    modificationDate: entry.modificationDate,
                    fileSize: entry.fileSize,
                    observedAt: entry.observedAt
                ))
            }
        }
        try context.save()
    }

    public func remove(_ localIdentifiers: Set<String>) async throws {
        guard !localIdentifiers.isEmpty else { return }
        var changed = false
        for id in localIdentifiers {
            var descriptor = FetchDescriptor<StoredLocalAssetMetadata>(
                predicate: #Predicate<StoredLocalAssetMetadata> { $0.localIdentifier == id }
            )
            descriptor.fetchLimit = 1
            if let row = try context.fetch(descriptor).first {
                context.delete(row)
                changed = true
            }
        }
        if changed { try context.save() }
    }

    public func clear() async throws {
        var changed = false
        for row in try context.fetch(FetchDescriptor<StoredLocalAssetMetadata>()) {
            context.delete(row)
            changed = true
        }
        if changed { try context.save() }
    }

    private static func toEntry(_ row: StoredLocalAssetMetadata) -> LocalAssetMetadata {
        LocalAssetMetadata(
            localIdentifier: row.localIdentifier,
            originalFileName: row.originalFileName,
            creationDate: row.creationDate,
            modificationDate: row.modificationDate,
            fileSize: row.fileSize,
            observedAt: row.observedAt
        )
    }
}

// MARK: - SwiftDataPersistentChangeTokenStore

/// SwiftData-backed `PersistentChangeTokenStore`. The protocol and
/// `StoredToken` value type live in `CairnCore` so a Kotlin port
/// can provide its own impl against Android's equivalent. This impl
/// stores the opaque bytes in a singleton SwiftData row.
public actor SwiftDataPersistentChangeTokenStore: PersistentChangeTokenStore {
    private let context: ModelContext

    public init(container: ModelContainer) {
        self.context = ModelContext(container)
    }

    public func load() async throws -> StoredToken? {
        var descriptor = FetchDescriptor<StoredPersistentChangeToken>()
        descriptor.fetchLimit = 1
        guard let row = try context.fetch(descriptor).first else { return nil }
        return StoredToken(data: row.tokenData, savedAt: row.savedAt)
    }

    public func save(_ token: StoredToken) async throws {
        // Singleton upsert — only one token row should ever exist.
        let descriptor = FetchDescriptor<StoredPersistentChangeToken>()
        let existing = try context.fetch(descriptor)
        if let row = existing.first {
            row.tokenData = token.data
            row.savedAt = token.savedAt
            // Clean up any rogue extras from older bugs.
            for extra in existing.dropFirst() {
                context.delete(extra)
            }
        } else {
            context.insert(StoredPersistentChangeToken(tokenData: token.data, savedAt: token.savedAt))
        }
        try context.save()
    }

    public func clear() async throws {
        for row in try context.fetch(FetchDescriptor<StoredPersistentChangeToken>()) {
            context.delete(row)
        }
        try context.save()
    }
}

// MARK: - SwiftDataThumbnailStore

public actor SwiftDataThumbnailStore {
    private let context: ModelContext

    public init(container: ModelContainer) {
        self.context = ModelContext(container)
        self.context.autosaveEnabled = false
    }

    public func thumbhash(for assetId: String) async throws -> Data? {
        var desc = FetchDescriptor<StoredThumbnail>(predicate: #Predicate { $0.assetId == assetId })
        desc.fetchLimit = 1
        return try context.fetch(desc).first?.thumbhashData
    }

    public func thumbnail(for assetId: String) async throws -> Data? {
        var desc = FetchDescriptor<StoredThumbnail>(predicate: #Predicate { $0.assetId == assetId })
        desc.fetchLimit = 1
        return try context.fetch(desc).first?.thumbnailData
    }

    public func saveThumbhashes(_ entries: [(assetId: String, data: Data)]) async throws {
        for entry in entries {
            let id = entry.assetId
            var desc = FetchDescriptor<StoredThumbnail>(predicate: #Predicate<StoredThumbnail> { $0.assetId == id })
            desc.fetchLimit = 1
            if let existing = try context.fetch(desc).first {
                if existing.thumbhashData == nil {
                    existing.thumbhashData = entry.data
                }
            } else {
                context.insert(StoredThumbnail(assetId: id, thumbhashData: entry.data))
            }
        }
        try context.save()
    }

    public func saveThumbnail(assetId: String, data: Data) async throws {
        let id = assetId
        var desc = FetchDescriptor<StoredThumbnail>(predicate: #Predicate<StoredThumbnail> { $0.assetId == id })
        desc.fetchLimit = 1
        if let existing = try context.fetch(desc).first {
            existing.thumbnailData = data
            existing.createdAt = Date()
        } else {
            context.insert(StoredThumbnail(assetId: assetId, thumbnailData: data))
        }
        try context.save()
    }

    public func evictThumbnails(overCapBytes: Int) async throws {
        let allRows = try context.fetch(FetchDescriptor<StoredThumbnail>(sortBy: [SortDescriptor(\.createdAt, order: .forward)]))
        var totalBytes = 0
        for row in allRows {
            totalBytes += row.thumbnailData?.count ?? 0
        }
        guard totalBytes > overCapBytes else { return }
        for row in allRows {
            guard totalBytes > overCapBytes else { break }
            if let size = row.thumbnailData?.count {
                row.thumbnailData = nil
                totalBytes -= size
            }
        }
        try context.save()
    }

    public func evictThumbhashes(overCapBytes: Int) async throws {
        let allRows = try context.fetch(FetchDescriptor<StoredThumbnail>(sortBy: [SortDescriptor(\.createdAt, order: .forward)]))
        var totalBytes = 0
        for row in allRows {
            totalBytes += row.thumbhashData?.count ?? 0
        }
        guard totalBytes > overCapBytes else { return }
        for row in allRows {
            guard totalBytes > overCapBytes else { break }
            if let size = row.thumbhashData?.count {
                row.thumbhashData = nil
                totalBytes -= size
            }
        }
        try context.save()
    }

    public func thumbnailCacheBytes() async throws -> Int {
        let allRows = try context.fetch(FetchDescriptor<StoredThumbnail>())
        return allRows.reduce(0) { $0 + ($1.thumbnailData?.count ?? 0) }
    }

    public func thumbhashBytes() async throws -> Int {
        let allRows = try context.fetch(FetchDescriptor<StoredThumbnail>())
        return allRows.reduce(0) { $0 + ($1.thumbhashData?.count ?? 0) }
    }

    public func clear() async throws {
        for row in try context.fetch(FetchDescriptor<StoredThumbnail>()) {
            context.delete(row)
        }
        try context.save()
    }
}
