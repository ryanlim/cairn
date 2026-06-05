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
final class StoredObservedChecksum {
    @Attribute(.unique) var base64: String
    /// Comma-separated `PHAssetCollection.localIdentifier` values
    /// recording which selected-scope albums cairn last observed this
    /// checksum in. Empty `""` means "untagged / pre-scope-aware /
    /// out-of-current-scope." `PHAssetCollection.localIdentifier` is
    /// UUID-shaped (commas don't appear), so a CSV is unambiguous and
    /// human-debuggable in the SwiftData store browser. Default `""`
    /// makes adding this field migration-free for SwiftData's
    /// lightweight-migration path: existing rows decode with empty
    /// CSV.
    var albumIdsCSV: String = ""

    init(base64: String, albumIdsCSV: String = "") {
        self.base64 = base64
        self.albumIdsCSV = albumIdsCSV
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
    /// `true` when this checksum was imputed from the server via the
    /// fast-initial-scan path (`server.deviceAssetId` join) rather than
    /// computed locally. Verify-on-touch will re-hash before propagating
    /// any deletion that resolves through an imputed row. Defaulted to
    /// `false` so legacy rows (predating this field) decode as verified
    /// — the existing population path is always locally-hashed.
    /// See `docs/active-design/fast-initial-scan-plan.md`.
    var imputed: Bool = false

    init(
        localIdentifier: String,
        base64: String,
        modificationDate: Date?,
        imputed: Bool = false
    ) {
        self.compoundKey = "\(localIdentifier)|\(base64)"
        self.localIdentifier = localIdentifier
        self.base64 = base64
        self.modificationDate = modificationDate
        self.imputed = imputed
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
    /// Comma-separated `originalFilename` strings collected from
    /// EVERY `PHAssetResource` attached to the asset (in addition to
    /// the primary one stored in `originalFileName`). For an edited
    /// video the resource list typically contains the original
    /// (`IMG_1234.MOV`), the rendered edit (`FullSizeRender.mov`), an
    /// adjustment sidecar (`Adjustments.plist`), and sometimes a
    /// `FullSizeRender.jpeg` poster. PhotoKit replaces the PHAsset's
    /// KVC `filename` with a UUID-style placeholder for edited
    /// assets, so neither the KVC name NOR the primary resource name
    /// match what Immich originally uploaded — the source of truth
    /// for the upload is one of the *other* resource filenames in
    /// this list, and the engine's alive-on-phone safety check needs
    /// to see all of them to suppress correctly.
    ///
    /// CSV chosen for SwiftData lightweight-migration friendliness
    /// (just a `String` with a default value). `=""` default means
    /// existing rows decode as "no extra filenames known" and the
    /// alive-key build falls back to its other sources.
    var allResourceFilenamesCSV: String = ""

    init(
        localIdentifier: String,
        originalFileName: String?,
        creationDate: Date?,
        modificationDate: Date?,
        fileSize: Int64?,
        observedAt: Date,
        allResourceFilenamesCSV: String = ""
    ) {
        self.localIdentifier = localIdentifier
        self.originalFileName = originalFileName
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.fileSize = fileSize
        self.observedAt = observedAt
        self.allResourceFilenamesCSV = allResourceFilenamesCSV
    }
}

/// Deletion-source row. Sidecar to `StoredConfirmedDeletedChecksum`
/// that records the source `localIdentifier` a checksum was retired
/// from. Lets Pending Review group quarantined entries with inferred
/// orphans across syncs (the scan-time mapping from the reconciler
/// only covers items deleted in the current pass; on subsequent
/// syncs that data is gone). One row per checksum, keyed unique on
/// `base64`.
@Model
final class StoredDeletionSourceEntry {
    @Attribute(.unique) var base64: String
    var localIdentifier: String

    init(base64: String, localIdentifier: String) {
        self.base64 = base64
        self.localIdentifier = localIdentifier
    }
}

/// Edit-retirement row. One per `(localIdentifier, base64)` pair —
/// Live Photos contribute two rows under the same id (still + motion
/// video). Compound unique key mirrors `StoredLocalHashEntry`'s
/// approach so SwiftData enforces dedup at the schema layer.
///
/// **First-write-wins semantics.** Writes diff against the existing
/// rows for the id and only insert when the id has no rows at all.
/// Once seeded, an id's rows are immutable until explicit removal.
/// That's the contract that protects edited-then-saved photos from
/// having their original SHA1 silently flow into quarantine.
@Model
final class StoredEditRetirementEntry {
    @Attribute(.unique) var compoundKey: String
    var localIdentifier: String
    var base64: String

    init(localIdentifier: String, base64: String) {
        self.compoundKey = "\(localIdentifier)|\(base64)"
        self.localIdentifier = localIdentifier
        self.base64 = base64
    }
}

/// Status-snapshot row. Singleton — there's only ever one snapshot
/// per server, keyed off a fixed sentinel id (`"current"`). Save is an
/// upsert; load returns `nil` when no row exists yet. See
/// `CairnCore/StatusSnapshotStore.swift` for the cosmetic-only contract.
@Model
final class StoredStatusSnapshot {
    @Attribute(.unique) var singletonId: String
    var deleteCandidatesCount: Int
    var matchedCount: Int
    var pendingReviewCount: Int
    var inferredOrphanCount: Int
    var computedAt: Date

    init(
        deleteCandidatesCount: Int,
        matchedCount: Int,
        pendingReviewCount: Int,
        inferredOrphanCount: Int,
        computedAt: Date
    ) {
        self.singletonId = "current"
        self.deleteCandidatesCount = deleteCandidatesCount
        self.matchedCount = matchedCount
        self.pendingReviewCount = pendingReviewCount
        self.inferredOrphanCount = inferredOrphanCount
        self.computedAt = computedAt
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

/// Pending-trash retry-queue row. One per user-confirmed trash
/// request that hasn't successfully landed on Immich yet. The
/// `assetsData` blob is a JSON-encoded `[ServerAsset]`: SwiftData
/// can't store arbitrary Codable arrays directly, so we serialize
/// at the actor boundary. Costs one encode/decode per
/// snapshot/enqueue, which is fine — the queue is small (typically
/// 1-10 intents).
@Model
final class StoredPendingTrashIntent {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var runId: String
    /// JSON-encoded `[ServerAsset]`. Decoded by the actor on read.
    var assetsData: Data
    var assetsInPurview: Int
    var lastAttemptedAt: Date?
    var attemptCount: Int
    var lastError: String?

    init(
        id: UUID,
        createdAt: Date,
        runId: String,
        assetsData: Data,
        assetsInPurview: Int,
        lastAttemptedAt: Date? = nil,
        attemptCount: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.runId = runId
        self.assetsData = assetsData
        self.assetsInPurview = assetsInPurview
        self.lastAttemptedAt = lastAttemptedAt
        self.attemptCount = attemptCount
        self.lastError = lastError
    }
}

// MARK: - Server-side asset cache + sync ack rows

/// Per-server-asset row. One per Immich-side asset visible to the API
/// key. `serverAssetId` is the Immich UUID — unique per asset on the
/// server — and chosen as the primary key because tombstones
/// (`SyncAssetDeleteV1`) arrive keyed only by id, not by checksum. Two
/// distinct server assets can in theory share a checksum (same bytes
/// uploaded from two devices); the reconciler treats them as one
/// logical content but the cache stores each row separately so the
/// stream-side delete-by-id stays unambiguous.
@Model
final class StoredServerAsset {
    @Attribute(.unique) var serverAssetId: String
    var checksumBase64: String
    var originalFileName: String
    /// Server-side `thumbhash` blob, base64-encoded — small (~28 bytes)
    /// placeholder image data. Carried through the cache so the
    /// Excluded / Pending Review screens render their blurry
    /// placeholders the same way under either discovery path.
    var thumbhash: String?
    var livePhotoVideoId: String?
    var deletedAt: Date?
    var visibility: String
    var isFavorite: Bool
    var assetType: String
    var fileCreatedAt: Date?
    var fileModifiedAt: Date?
    var width: Int?
    var height: Int?
    /// Originating-device per-asset id (PHAsset.localIdentifier on
    /// iOS) stamped by the Immich mobile uploader. Joining on this
    /// gives a precise phone→server mapping without re-hashing —
    /// see docs/active-design/fast-initial-scan-plan.md.
    var deviceAssetId: String?
    /// When cairn last wrote this row from a SyncEvent. Diagnostic
    /// only; not used in reconciliation.
    var lastUpdatedAt: Date

    init(
        serverAssetId: String,
        checksumBase64: String,
        originalFileName: String,
        thumbhash: String?,
        livePhotoVideoId: String?,
        deletedAt: Date?,
        visibility: String,
        isFavorite: Bool,
        assetType: String,
        fileCreatedAt: Date?,
        fileModifiedAt: Date?,
        width: Int?,
        height: Int?,
        deviceAssetId: String? = nil,
        lastUpdatedAt: Date
    ) {
        self.serverAssetId = serverAssetId
        self.checksumBase64 = checksumBase64
        self.originalFileName = originalFileName
        self.thumbhash = thumbhash
        self.livePhotoVideoId = livePhotoVideoId
        self.deletedAt = deletedAt
        self.visibility = visibility
        self.isFavorite = isFavorite
        self.assetType = assetType
        self.fileCreatedAt = fileCreatedAt
        self.fileModifiedAt = fileModifiedAt
        self.width = width
        self.height = height
        self.deviceAssetId = deviceAssetId
        self.lastUpdatedAt = lastUpdatedAt
    }
}

/// Per-entity-type ack cursor. Bounded — one row per SyncEntityType
/// cairn requests events for (currently `.assetV1` and
/// `.assetDeleteV1`, so ≤ 2 rows in practice). `entityType` stores the
/// raw SyncEntityType.rawValue rather than the enum itself because
/// SwiftData doesn't yet model RawRepresentable cleanly across
/// platform versions; the actor's adapter maps between the two.
@Model
final class StoredSyncAck {
    @Attribute(.unique) var entityType: String
    var ack: String
    var savedAt: Date

    init(entityType: String, ack: String, savedAt: Date) {
        self.entityType = entityType
        self.ack = ack
        self.savedAt = savedAt
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

    /// Build a `ModelContainer` for per-server state (observed,
    /// exclusions, confirmed-deleted, persistent-change token,
    /// edit-retirement anchors, cosmetic status snapshot, pending
    /// trash retry queue, server-asset cache, sync acks).
    public static func makePerServer(url: URL, inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([
            StoredObservedChecksum.self,
            StoredExclusion.self,
            StoredConfirmedDeletedChecksum.self,
            StoredPersistentChangeToken.self,
            StoredThumbnail.self,
            StoredEditRetirementEntry.self,
            StoredDeletionSourceEntry.self,
            StoredStatusSnapshot.self,
            StoredPendingTrashIntent.self,
            StoredServerAsset.self,
            StoredSyncAck.self,
        ])
        return try container(schema: schema, url: inMemory ? nil : url, inMemory: inMemory)
    }

    /// Legacy factory — every model type in one container. Used
    /// only by tests and the one-shot migration path.
    public static func make(url: URL? = nil, inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([
            StoredObservedChecksum.self,
            StoredExclusion.self,
            StoredConfirmedDeletedChecksum.self,
            StoredLocalHashEntry.self,
            StoredDeferredHash.self,
            StoredPersistentChangeToken.self,
            StoredThumbnail.self,
            StoredLocalAssetMetadata.self,
            StoredEditRetirementEntry.self,
            StoredDeletionSourceEntry.self,
            StoredStatusSnapshot.self,
            StoredPendingTrashIntent.self,
            StoredServerAsset.self,
            StoredSyncAck.self,
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

// MARK: - SwiftDataObservedStore

/// SwiftData-backed `ObservedStore`.
///
/// **Why a plain `actor` instead of `@ModelActor`.** `@ModelActor`
/// synthesizes an init taking a `ModelContainer` + custom `Executor`
/// and exposes a `modelContext` property. Convenient, but it bakes
/// in a more restrictive isolation model than we need — sharing
/// fetch helpers across actors gets awkward and the generated init
/// doesn't leave room for other parameters. A plain actor with an
/// internally-owned `ModelContext` is just as `Sendable`-safe (the
/// context never escapes the actor) with full control over the init.
public actor SwiftDataObservedStore: ObservedStore {
    private let context: ModelContext

    public init(container: ModelContainer) {
        // Each actor owns its own context so all SwiftData calls happen on
        // a single isolation domain (this actor's). Sharing a context
        // across isolation boundaries is the SwiftData footgun this design
        // avoids.
        self.context = ModelContext(container)
    }

    public func snapshot() async throws -> Set<Checksum> {
        let descriptor = FetchDescriptor<StoredObservedChecksum>()
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
            context.insert(StoredObservedChecksum(base64: checksum.base64))
        }
        // SwiftData doesn't auto-persist — explicit save required.
        try context.save()
    }

    private func snapshotBase64Set() throws -> Set<String> {
        let descriptor = FetchDescriptor<StoredObservedChecksum>()
        let rows = try context.fetch(descriptor)
        var out: Set<String> = []
        out.reserveCapacity(rows.count)
        for row in rows {
            out.insert(row.base64)
        }
        return out
    }

    /// Wipe every observed row. Called by Settings → Reset index.
    /// Not on the `ObservedStore` protocol — wiping the index is an
    /// iOS-specific affordance; no Kotlin port or CLI invocation
    /// needs it.
    public func remove(_ checksums: Set<Checksum>) async throws {
        guard !checksums.isEmpty else { return }
        let targets = Set(checksums.map(\.base64))
        var changed = false
        for row in try context.fetch(FetchDescriptor<StoredObservedChecksum>()) {
            if targets.contains(row.base64) {
                context.delete(row)
                changed = true
            }
        }
        if changed { try context.save() }
    }

    public func clear() async throws {
        var changed = false
        for row in try context.fetch(FetchDescriptor<StoredObservedChecksum>()) {
            context.delete(row)
            changed = true
        }
        if changed { try context.save() }
    }

    // MARK: - Scope-aware tag API

    public func snapshotWithTags() async throws -> [Checksum: Set<String>] {
        let descriptor = FetchDescriptor<StoredObservedChecksum>()
        let rows = try context.fetch(descriptor)
        var out: [Checksum: Set<String>] = [:]
        out.reserveCapacity(rows.count)
        for row in rows {
            out[Checksum(base64: row.base64)] = Self.parseAlbumCSV(row.albumIdsCSV)
        }
        return out
    }

    public func recordObserved(_ observations: [Checksum: Set<String>]) async throws {
        guard !observations.isEmpty else { return }
        // Build a map of existing rows so we can update-in-place on
        // collision rather than firing N independent fetch+update
        // round-trips.
        let allRows = try context.fetch(FetchDescriptor<StoredObservedChecksum>())
        var byBase64: [String: StoredObservedChecksum] = [:]
        byBase64.reserveCapacity(allRows.count)
        for row in allRows { byBase64[row.base64] = row }

        var changed = false
        for (ck, tags) in observations {
            let csv = Self.formatAlbumCSV(tags)
            if let row = byBase64[ck.base64] {
                if row.albumIdsCSV != csv {
                    row.albumIdsCSV = csv
                    changed = true
                }
            } else {
                context.insert(StoredObservedChecksum(base64: ck.base64, albumIdsCSV: csv))
                changed = true
            }
        }
        if changed { try context.save() }
    }

    public func setTags(for checksums: Set<Checksum>, tags: Set<String>) async throws {
        guard !checksums.isEmpty else { return }
        let targets = Set(checksums.map(\.base64))
        let csv = Self.formatAlbumCSV(tags)
        var changed = false
        for row in try context.fetch(FetchDescriptor<StoredObservedChecksum>()) {
            if targets.contains(row.base64), row.albumIdsCSV != csv {
                row.albumIdsCSV = csv
                changed = true
            }
        }
        if changed { try context.save() }
    }

    // MARK: - CSV codec

    /// Parse the comma-separated stored representation back into a Set.
    /// Empty string → empty set (legacy / untagged entries). Whitespace
    /// is *not* trimmed — `PHAssetCollection.localIdentifier`s are
    /// generated by PhotoKit and don't contain spaces.
    static func parseAlbumCSV(_ csv: String) -> Set<String> {
        guard !csv.isEmpty else { return [] }
        return Set(csv.split(separator: ",").map(String.init))
    }

    /// Sorted CSV for stable on-disk encoding; lets two equal-set writes
    /// produce byte-identical rows so the change-detection logic in
    /// `recordObserved` / `setTags` doesn't issue spurious saves.
    static func formatAlbumCSV(_ tags: Set<String>) -> String {
        tags.sorted().joined(separator: ",")
    }
}

// MARK: - SwiftDataExclusionStore

/// SwiftData-backed `ExclusionStore`. Same actor-with-private-context
/// pattern as `SwiftDataObservedStore`; see that type for the
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
/// `SwiftDataObservedStore` for the plain-actor-vs-`@ModelActor`
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

// MARK: - SwiftDataDeletionSourceStore

/// SwiftData-backed `DeletionSourceStore`. One row per
/// `(checksum, localIdentifier)` pair; schema-level dedup on
/// `base64` so the unique index does the work. Last-writer-wins on
/// the `localIdentifier` — re-recording an existing checksum with
/// the same id is idempotent and skips the save call entirely.
public actor SwiftDataDeletionSourceStore: DeletionSourceStore {
    private let context: ModelContext

    public init(container: ModelContainer) {
        self.context = ModelContext(container)
    }

    public func snapshot() async throws -> [Checksum: String] {
        let rows = try context.fetch(FetchDescriptor<StoredDeletionSourceEntry>())
        var out: [Checksum: String] = [:]
        out.reserveCapacity(rows.count)
        for row in rows {
            out[Checksum(base64: row.base64)] = row.localIdentifier
        }
        return out
    }

    public func record(_ entries: [Checksum: String]) async throws {
        guard !entries.isEmpty else { return }
        var changed = false
        for (checksum, localId) in entries {
            let base64 = checksum.base64
            var descriptor = FetchDescriptor<StoredDeletionSourceEntry>(
                predicate: #Predicate<StoredDeletionSourceEntry> { $0.base64 == base64 }
            )
            descriptor.fetchLimit = 1
            if let existing = try context.fetch(descriptor).first {
                // Idempotent: skip the in-place mutation when the
                // mapping is already what the caller is recording.
                // SwiftData treats untouched rows as no-ops on save,
                // but the explicit guard avoids paying the row read
                // for no reason on hot paths.
                if existing.localIdentifier != localId {
                    existing.localIdentifier = localId
                    changed = true
                }
            } else {
                context.insert(StoredDeletionSourceEntry(
                    base64: base64,
                    localIdentifier: localId
                ))
                changed = true
            }
        }
        if changed { try context.save() }
    }

    public func remove(_ checksums: Set<Checksum>) async throws {
        guard !checksums.isEmpty else { return }
        var changed = false
        for checksum in checksums {
            let base64 = checksum.base64
            var descriptor = FetchDescriptor<StoredDeletionSourceEntry>(
                predicate: #Predicate<StoredDeletionSourceEntry> { $0.base64 == base64 }
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
        for row in try context.fetch(FetchDescriptor<StoredDeletionSourceEntry>()) {
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

    /// Flat union of every cached checksum. Skips the per-row Live
    /// Photo grouping that `snapshot()` does — cheap when callers
    /// only need a `Set<Checksum>` for reconciliation diffs.
    public func allChecksums() async throws -> Set<Checksum> {
        let rows = try context.fetch(FetchDescriptor<StoredLocalHashEntry>())
        var out = Set<Checksum>()
        out.reserveCapacity(rows.count)
        for row in rows {
            out.insert(Checksum(base64: row.base64))
        }
        return out
    }

    /// Combined `allChecksums` + `indexedCount` from a single fetch.
    /// Both projections walk the same row set, so doing them together
    /// saves one full-table fetch worth of SwiftData hydration —
    /// material on libraries with thousands of cached SHA1s where the
    /// row count is the dominant cost. Materializes once, sweeps once.
    public func summary() async throws -> (checksums: Set<Checksum>, distinctIdCount: Int) {
        let rows = try context.fetch(FetchDescriptor<StoredLocalHashEntry>())
        var cks = Set<Checksum>()
        var ids = Set<String>()
        cks.reserveCapacity(rows.count)
        ids.reserveCapacity(rows.count)
        for row in rows {
            cks.insert(Checksum(base64: row.base64))
            ids.insert(row.localIdentifier)
        }
        return (cks, ids.count)
    }

    /// Batch lookup of `(checksums, modificationDate)` for a known id
    /// set. One SQL fetch with a `localIdentifier IN (...)` predicate
    /// instead of N per-id queries. Used by drain pre-filtering and
    /// other batch paths.
    public func entries(forIdentifiers ids: Set<String>) async throws -> [String: (checksums: Set<Checksum>, modificationDate: Date?)] {
        guard !ids.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<StoredLocalHashEntry>(
            predicate: #Predicate<StoredLocalHashEntry> { ids.contains($0.localIdentifier) }
        )
        let rows = try context.fetch(descriptor)
        var out: [String: (checksums: Set<Checksum>, modificationDate: Date?)] = [:]
        for row in rows {
            if var existing = out[row.localIdentifier] {
                existing.checksums.insert(Checksum(base64: row.base64))
                out[row.localIdentifier] = existing
            } else {
                out[row.localIdentifier] = (
                    [Checksum(base64: row.base64)],
                    row.modificationDate
                )
            }
        }
        return out
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

    public func setImputed(_ checksums: Set<Checksum>, for localIdentifier: String, modificationDate: Date?) async throws {
        // Same replace-all-prior-rows semantics as `set`, but stamps
        // `imputed = true` so the verify-on-touch path knows to re-hash
        // before propagating any deletion that resolves through it.
        // Multiple checksums per localId is the Live Photo case:
        // still + paired motion video both seed under the same
        // PHAsset.localIdentifier.
        guard !checksums.isEmpty else { return }
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
                modificationDate: modificationDate,
                imputed: true
            ))
        }
        try context.save()
    }

    public func isImputed(for localIdentifier: String) async throws -> Bool {
        var descriptor = FetchDescriptor<StoredLocalHashEntry>(
            predicate: #Predicate<StoredLocalHashEntry> { $0.localIdentifier == localIdentifier }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.imputed ?? false
    }

    public func imputedCount() async throws -> Int {
        let descriptor = FetchDescriptor<StoredLocalHashEntry>(
            predicate: #Predicate<StoredLocalHashEntry> { $0.imputed == true }
        )
        let rows = try context.fetch(descriptor)
        var seen = Set<String>()
        seen.reserveCapacity(rows.count)
        for row in rows {
            seen.insert(row.localIdentifier)
        }
        return seen.count
    }

    public func imputedIdentifiers() async throws -> Set<String> {
        let descriptor = FetchDescriptor<StoredLocalHashEntry>(
            predicate: #Predicate<StoredLocalHashEntry> { $0.imputed == true }
        )
        let rows = try context.fetch(descriptor)
        var ids = Set<String>()
        ids.reserveCapacity(rows.count)
        for row in rows {
            ids.insert(row.localIdentifier)
        }
        return ids
    }

    /// Single-fetch implementation. Avoids the protocol default's
    /// N+1 query pattern (snapshot + modDate + isImputed per id) —
    /// on libraries with thousands of rows that's the difference
    /// between a few ms and a few seconds.
    public func exportableRows() async throws -> [(localId: String, checksum: Checksum, modificationDate: Date?, imputed: Bool)] {
        let rows = try context.fetch(FetchDescriptor<StoredLocalHashEntry>())
        return rows.map { row in
            (
                localId: row.localIdentifier,
                checksum: Checksum(base64: row.base64),
                modificationDate: row.modificationDate,
                imputed: row.imputed
            )
        }
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
                existing.allResourceFilenamesCSV = Self.encodeFilenames(entry.allResourceFilenames)
            } else {
                context.insert(StoredLocalAssetMetadata(
                    localIdentifier: entry.localIdentifier,
                    originalFileName: entry.originalFileName,
                    creationDate: entry.creationDate,
                    modificationDate: entry.modificationDate,
                    fileSize: entry.fileSize,
                    observedAt: entry.observedAt,
                    allResourceFilenamesCSV: Self.encodeFilenames(entry.allResourceFilenames)
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

    public func snapshot() async throws -> [LocalAssetMetadata] {
        let rows = try context.fetch(FetchDescriptor<StoredLocalAssetMetadata>())
        return rows.map(Self.toEntry)
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
            observedAt: row.observedAt,
            allResourceFilenames: Self.decodeFilenames(row.allResourceFilenamesCSV)
        )
    }

    /// Tab-separated, not comma — resource `originalFilename` strings
    /// can legitimately contain commas (system-rendered exports
    /// sometimes use them in their filenames), but tabs essentially
    /// never appear in PhotoKit-emitted filenames. Slightly less
    /// human-friendly to read in a raw DB inspection but unambiguous
    /// on round-trip.
    private static let filenameSeparator = "\t"

    private static func encodeFilenames(_ names: [String]) -> String {
        names.filter { !$0.isEmpty }.joined(separator: filenameSeparator)
    }

    private static func decodeFilenames(_ csv: String) -> [String] {
        guard !csv.isEmpty else { return [] }
        return csv.components(separatedBy: filenameSeparator).filter { !$0.isEmpty }
    }
}

// MARK: - SwiftDataEditRetirementStore

/// SwiftData-backed `EditRetirementStore`. Tracks the first-observed
/// SHA1 set per `localIdentifier`; first-write-wins so retirement
/// anchors stay stable across re-observations (full enumeration,
/// orphan-sweep recovery). Same plain-actor-with-private-context
/// pattern as the other stores.
public actor SwiftDataEditRetirementStore: EditRetirementStore {
    private let context: ModelContext

    public init(container: ModelContainer) {
        self.context = ModelContext(container)
    }

    public func firstObserved(for localIdentifier: String) async throws -> Set<Checksum> {
        let descriptor = FetchDescriptor<StoredEditRetirementEntry>(
            predicate: #Predicate<StoredEditRetirementEntry> { $0.localIdentifier == localIdentifier }
        )
        let rows = try context.fetch(descriptor)
        var out: Set<Checksum> = []
        out.reserveCapacity(rows.count)
        for row in rows {
            out.insert(Checksum(base64: row.base64))
        }
        return out
    }

    public func recordFirstObserved(_ checksums: Set<Checksum>, for localIdentifier: String) async throws {
        guard !checksums.isEmpty else { return }
        // First-write-wins: bail if any row already exists for this id.
        // The id-level fetchLimit avoids materializing more than one
        // row just to test presence.
        var existsDescriptor = FetchDescriptor<StoredEditRetirementEntry>(
            predicate: #Predicate<StoredEditRetirementEntry> { $0.localIdentifier == localIdentifier }
        )
        existsDescriptor.fetchLimit = 1
        if try context.fetch(existsDescriptor).first != nil { return }

        for checksum in checksums {
            context.insert(StoredEditRetirementEntry(
                localIdentifier: localIdentifier,
                base64: checksum.base64
            ))
        }
        try context.save()
    }

    public func snapshot() async throws -> [String: Set<Checksum>] {
        let rows = try context.fetch(FetchDescriptor<StoredEditRetirementEntry>())
        var out: [String: Set<Checksum>] = [:]
        for row in rows {
            out[row.localIdentifier, default: []].insert(Checksum(base64: row.base64))
        }
        return out
    }

    public func remove(for localIdentifiers: Set<String>) async throws {
        guard !localIdentifiers.isEmpty else { return }
        var changed = false
        for id in localIdentifiers {
            let descriptor = FetchDescriptor<StoredEditRetirementEntry>(
                predicate: #Predicate<StoredEditRetirementEntry> { $0.localIdentifier == id }
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
        for row in try context.fetch(FetchDescriptor<StoredEditRetirementEntry>()) {
            context.delete(row)
            changed = true
        }
        if changed { try context.save() }
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

// MARK: - SwiftDataStatusSnapshotStore

/// SwiftData-backed `StatusSnapshotStore`. Singleton row keyed off a
/// fixed sentinel id; save upserts and load returns `nil` when no row
/// exists yet. Same plain-actor-with-private-context pattern as the
/// other stores.
public actor SwiftDataStatusSnapshotStore: StatusSnapshotStore {
    private let context: ModelContext

    public init(container: ModelContainer) {
        self.context = ModelContext(container)
    }

    public func load() async throws -> StatusSnapshot? {
        var descriptor = FetchDescriptor<StoredStatusSnapshot>()
        descriptor.fetchLimit = 1
        guard let row = try context.fetch(descriptor).first else { return nil }
        return StatusSnapshot(
            deleteCandidatesCount: row.deleteCandidatesCount,
            matchedCount: row.matchedCount,
            pendingReviewCount: row.pendingReviewCount,
            inferredOrphanCount: row.inferredOrphanCount,
            computedAt: row.computedAt
        )
    }

    public func save(_ snapshot: StatusSnapshot) async throws {
        // Singleton upsert — at most one row should ever exist. Clean
        // up any rogue extras in case a prior bug or schema migration
        // left more than one behind.
        let existing = try context.fetch(FetchDescriptor<StoredStatusSnapshot>())
        if let row = existing.first {
            row.deleteCandidatesCount = snapshot.deleteCandidatesCount
            row.matchedCount = snapshot.matchedCount
            row.pendingReviewCount = snapshot.pendingReviewCount
            row.inferredOrphanCount = snapshot.inferredOrphanCount
            row.computedAt = snapshot.computedAt
            for extra in existing.dropFirst() {
                context.delete(extra)
            }
        } else {
            context.insert(StoredStatusSnapshot(
                deleteCandidatesCount: snapshot.deleteCandidatesCount,
                matchedCount: snapshot.matchedCount,
                pendingReviewCount: snapshot.pendingReviewCount,
                inferredOrphanCount: snapshot.inferredOrphanCount,
                computedAt: snapshot.computedAt
            ))
        }
        try context.save()
    }

    public func clear() async throws {
        var changed = false
        for row in try context.fetch(FetchDescriptor<StoredStatusSnapshot>()) {
            context.delete(row)
            changed = true
        }
        if changed { try context.save() }
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

// MARK: - SwiftDataPendingTrashIntentStore

/// SwiftData-backed `PendingTrashIntentStore`. Rows decode lazily —
/// `[ServerAsset]` lives as JSON `Data` in `assetsData` and only
/// inflates inside this actor. Conflict-pruning helpers
/// (`removeIntents(containingAnyOf:)`, `remove(matchingRunId:)`)
/// scan the queue with linear cost; the queue is small enough that
/// the simpler shape beats indexed lookups.
public actor SwiftDataPendingTrashIntentStore: PendingTrashIntentStore {
    private let context: ModelContext
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(container: ModelContainer) {
        self.context = ModelContext(container)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    public func snapshot() async throws -> [PendingTrashIntent] {
        let descriptor = FetchDescriptor<StoredPendingTrashIntent>(
            sortBy: [SortDescriptor(\.createdAt)]
        )
        let rows = try context.fetch(descriptor)
        return try rows.map { try toModel($0) }
    }

    public func enqueue(_ intent: PendingTrashIntent) async throws {
        let data = try encoder.encode(intent.assets)
        context.insert(StoredPendingTrashIntent(
            id: intent.id,
            createdAt: intent.createdAt,
            runId: intent.runId,
            assetsData: data,
            assetsInPurview: intent.assetsInPurview,
            lastAttemptedAt: intent.lastAttemptedAt,
            attemptCount: intent.attemptCount,
            lastError: intent.lastError
        ))
        try context.save()
    }

    public func update(_ id: UUID, lastAttemptedAt: Date, attemptCount: Int, lastError: String?) async throws {
        var descriptor = FetchDescriptor<StoredPendingTrashIntent>(
            predicate: #Predicate<StoredPendingTrashIntent> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let row = try context.fetch(descriptor).first else { return }
        row.lastAttemptedAt = lastAttemptedAt
        row.attemptCount = attemptCount
        row.lastError = lastError
        try context.save()
    }

    public func remove(_ ids: Set<UUID>) async throws {
        guard !ids.isEmpty else { return }
        var changed = false
        for id in ids {
            var descriptor = FetchDescriptor<StoredPendingTrashIntent>(
                predicate: #Predicate<StoredPendingTrashIntent> { $0.id == id }
            )
            descriptor.fetchLimit = 1
            if let row = try context.fetch(descriptor).first {
                context.delete(row)
                changed = true
            }
        }
        if changed { try context.save() }
    }

    public func remove(matchingRunId runId: String) async throws {
        let descriptor = FetchDescriptor<StoredPendingTrashIntent>(
            predicate: #Predicate<StoredPendingTrashIntent> { $0.runId == runId }
        )
        let rows = try context.fetch(descriptor)
        guard !rows.isEmpty else { return }
        for row in rows { context.delete(row) }
        try context.save()
    }

    public func removeIntents(containingAnyOf checksums: Set<Checksum>) async throws {
        guard !checksums.isEmpty else { return }
        let bases = Set(checksums.map(\.base64))
        let rows = try context.fetch(FetchDescriptor<StoredPendingTrashIntent>())
        var changed = false
        for row in rows {
            // Decode just enough to know if any asset matches.
            // Cheap: queue is small, asset count per intent small.
            guard let assets = try? decoder.decode([ServerAsset].self, from: row.assetsData) else {
                continue
            }
            if assets.contains(where: { bases.contains($0.checksum.base64) }) {
                context.delete(row)
                changed = true
            }
        }
        if changed { try context.save() }
    }

    public func count() async throws -> Int {
        try context.fetchCount(FetchDescriptor<StoredPendingTrashIntent>())
    }

    // MARK: - Private

    private func toModel(_ row: StoredPendingTrashIntent) throws -> PendingTrashIntent {
        let assets = try decoder.decode([ServerAsset].self, from: row.assetsData)
        return PendingTrashIntent(
            id: row.id,
            createdAt: row.createdAt,
            runId: row.runId,
            assets: assets,
            assetsInPurview: row.assetsInPurview,
            lastAttemptedAt: row.lastAttemptedAt,
            attemptCount: row.attemptCount,
            lastError: row.lastError
        )
    }
}

// MARK: - SwiftDataServerAssetCacheStore

/// SwiftData-backed `ServerAssetCacheStore`. Per-server container only;
/// the asset cache is partitioned by (URL, userId) the same way Observed
/// and Exclusion stores are. Plain `actor` + private `ModelContext` —
/// same pattern documented at `SwiftDataObservedStore`.
///
/// Idempotency contract: `applyEvents` upserts by `serverAssetId`, so
/// replaying the same event batch produces the same cache state. This
/// is what lets the coordinator ack-after-apply safely: a crash between
/// apply-to-cache and POST-ack leaves an old cursor on the server; the
/// next stream call replays the events; the second apply is a no-op.
public actor SwiftDataServerAssetCacheStore: ServerAssetCacheStore {
    private let context: ModelContext
    private let clock: @Sendable () -> Date

    public init(container: ModelContainer, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.context = ModelContext(container)
        self.clock = clock
    }

    public func snapshot() async throws -> [ServerAsset] {
        // Filter at read time to match `ImmichClient.listAllAssets()`
        // default semantics so the reconciler sees an equivalent set
        // whether it's reading from the cache or the paginated path:
        //
        // - `deletedAt != nil` → server-side trashed; the engine
        //   already drops trashed assets but excluding them here
        //   keeps the byChecksum lookup the orchestrator builds
        //   from snapshot() smaller.
        // - `visibility == "hidden"` → Live Photo motion videos, etc.
        //   The reconciler discovers them via the still photo's
        //   `livePhotoVideoId` linkage; surfacing them as standalone
        //   ServerAsset entries would double-include them in the
        //   batch the orchestrator deletes.
        // - `visibility == "locked"` → PIN-protected; cairn's API
        //   key can't trash these even if asked, so omitting them
        //   from the candidate set saves a guaranteed failure.
        //
        // Timeline + archive are kept (matches listAllAssets default
        // server behavior).
        let rows = try context.fetch(FetchDescriptor<StoredServerAsset>())
        return rows.compactMap { row in
            guard row.deletedAt == nil else { return nil }
            guard row.visibility != "hidden", row.visibility != "locked" else { return nil }
            return Self.toServerAsset(row)
        }
    }

    public func size() async throws -> Int {
        try context.fetchCount(FetchDescriptor<StoredServerAsset>())
    }

    public func applyEvents(_ events: [SyncEvent]) async throws -> ApplyEventsSummary {
        guard !events.isEmpty else { return .empty }

        // One bulk fetch keyed by serverAssetId so upsert + delete
        // can both look up rows without N round-trips. The cache is
        // proportional to the server's asset count, but the typical
        // event batch is small (≤ 100) so the index dict over the
        // existing rows is dominated by I/O, not memory.
        let allRows = try context.fetch(FetchDescriptor<StoredServerAsset>())
        var byServerId: [String: StoredServerAsset] = [:]
        byServerId.reserveCapacity(allRows.count)
        for row in allRows { byServerId[row.serverAssetId] = row }

        var upserted = 0
        var deleted = 0
        var ignored = 0
        let now = clock()

        for event in events {
            switch event {
            case .asset(let payload, _):
                if let existing = byServerId[payload.id] {
                    // Update in place — same SwiftData object, just
                    // overwrite the mutable fields.
                    Self.copyPayload(payload, into: existing, now: now)
                } else {
                    let row = Self.makeRow(from: payload, now: now)
                    context.insert(row)
                    byServerId[payload.id] = row
                }
                upserted += 1
            case .assetDeleted(let payload, _):
                if let existing = byServerId[payload.assetId] {
                    context.delete(existing)
                    byServerId.removeValue(forKey: payload.assetId)
                    deleted += 1
                } else {
                    // Tombstone for an asset we never cached — fine.
                    // Counts as ignored because no row state changed.
                    ignored += 1
                }
            case .complete, .ignored:
                ignored += 1
            }
        }

        if upserted > 0 || deleted > 0 {
            try context.save()
        }
        return ApplyEventsSummary(upserted: upserted, deleted: deleted, ignored: ignored)
    }

    public func reset() async throws {
        var changed = false
        for row in try context.fetch(FetchDescriptor<StoredServerAsset>()) {
            context.delete(row)
            changed = true
        }
        if changed { try context.save() }
    }

    // MARK: - Private

    private static func toServerAsset(_ row: StoredServerAsset) -> ServerAsset {
        // The cache preserves visibility / deletedAt as raw fields but
        // the reconciliation engine only consumes ServerAsset (which
        // has `isTrashed`). Map deletedAt → isTrashed as the
        // closest-fitting representation: a non-nil deletedAt means
        // the server is treating this asset as trashed.
        let isTrashed = row.deletedAt != nil
        return ServerAsset(
            id: row.serverAssetId,
            checksum: Checksum(base64: row.checksumBase64),
            livePhotoVideoId: row.livePhotoVideoId,
            isTrashed: isTrashed,
            originalFileName: row.originalFileName,
            fileCreatedAt: row.fileCreatedAt,
            thumbhash: row.thumbhash,
            deviceAssetId: row.deviceAssetId
        )
    }

    private static func makeRow(from payload: SyncAssetV1, now: Date) -> StoredServerAsset {
        StoredServerAsset(
            serverAssetId: payload.id,
            checksumBase64: payload.checksum,
            originalFileName: payload.originalFileName,
            thumbhash: payload.thumbhash,
            livePhotoVideoId: payload.livePhotoVideoId,
            deletedAt: payload.deletedAt,
            visibility: payload.visibility,
            isFavorite: payload.isFavorite,
            assetType: payload.type,
            fileCreatedAt: payload.fileCreatedAt,
            fileModifiedAt: payload.fileModifiedAt,
            width: payload.width,
            height: payload.height,
            deviceAssetId: payload.deviceAssetId,
            lastUpdatedAt: now
        )
    }

    private static func copyPayload(_ payload: SyncAssetV1, into row: StoredServerAsset, now: Date) {
        row.checksumBase64 = payload.checksum
        row.originalFileName = payload.originalFileName
        row.thumbhash = payload.thumbhash
        row.livePhotoVideoId = payload.livePhotoVideoId
        row.deletedAt = payload.deletedAt
        row.visibility = payload.visibility
        row.isFavorite = payload.isFavorite
        row.assetType = payload.type
        row.fileCreatedAt = payload.fileCreatedAt
        row.fileModifiedAt = payload.fileModifiedAt
        row.width = payload.width
        row.height = payload.height
        row.deviceAssetId = payload.deviceAssetId
        row.lastUpdatedAt = now
    }
}

// MARK: - SwiftDataSyncAckStore

/// SwiftData-backed `SyncAckStore`. Bounded (one row per entity type
/// cairn requests; ≤ 2 rows in practice). Per-server container.
public actor SwiftDataSyncAckStore: SyncAckStore {
    private let context: ModelContext
    private let clock: @Sendable () -> Date

    public init(container: ModelContainer, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.context = ModelContext(container)
        self.clock = clock
    }

    public func ack(for type: SyncEntityType) async throws -> String? {
        let target = type.rawValue
        let rows = try context.fetch(FetchDescriptor<StoredSyncAck>())
        return rows.first(where: { $0.entityType == target })?.ack
    }

    public func setAck(_ ack: String, for type: SyncEntityType) async throws {
        let target = type.rawValue
        let now = clock()
        let rows = try context.fetch(FetchDescriptor<StoredSyncAck>())
        if let existing = rows.first(where: { $0.entityType == target }) {
            guard existing.ack != ack else { return }
            existing.ack = ack
            existing.savedAt = now
        } else {
            context.insert(StoredSyncAck(entityType: target, ack: ack, savedAt: now))
        }
        try context.save()
    }

    public func allAcks() async throws -> [SyncAckRecord] {
        let rows = try context.fetch(FetchDescriptor<StoredSyncAck>())
        var out: [SyncAckRecord] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            guard let type = SyncEntityType(rawValue: row.entityType) else {
                // A row whose entityType doesn't match any current
                // case — could happen on a schema rollback. Skip
                // silently; the next setAck will overwrite when it
                // comes for the matching type.
                continue
            }
            out.append(SyncAckRecord(type: type, ack: row.ack))
        }
        return out
    }

    public func clearAll() async throws {
        var changed = false
        for row in try context.fetch(FetchDescriptor<StoredSyncAck>()) {
            context.delete(row)
            changed = true
        }
        if changed { try context.save() }
    }
}
