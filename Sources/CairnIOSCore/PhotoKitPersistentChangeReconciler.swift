import Foundation
import OSLog
import CairnCore

#if canImport(Photos)
import Photos

// PhotoKit's fetch-result objects are snapshots of library state and Apple
// routinely passes them across queues in sample code, but strict concurrency
// checking has no way to know that. Flagging `@unchecked Sendable` here
// beats sprinkling wrappers across every TaskGroup capture in this file.
// If Apple ships real `Sendable` conformance these annotations become
// no-ops.
extension PHAsset: @unchecked @retroactive Sendable {}
extension PHAssetResource: @unchecked @retroactive Sendable {}

/// Hashing-pipeline logger. Stream from a paired Mac with
/// `log stream --predicate 'subsystem == "app.cairn.ios" AND category == "hash"'`,
/// or filter by "cairn" in Console.app (see `make device-logs`). Release
/// builds emit these — the volume is moderate and the lines are the
/// primary diagnostic when "why is sync slow?" comes up in the field.
private let hashLog = Logger(subsystem: "app.cairn.ios", category: "hash")

/// Wave-4 deletion-detection pipeline driver, built on
/// `PHPhotoLibrary.fetchPersistentChanges(since:)` (iOS 16+).
///
/// Two paths:
///
/// - **Full enumeration** runs when there's no saved token, on the very
///   first scan, or whenever PhotoKit reports
///   `PHPhotosError.persistentChangeTokenExpired`. Walks every
///   `PHAsset`, hashes its resources, rebuilds `LocalHashStore`, and
///   stamps the current `PHPersistentChangeToken`. Resumable — cached
///   rows survive cancellation.
///
/// - **Incremental** runs every subsequent wake. Iterates persistent-
///   change events, translates each `deletedLocalIdentifiers` id into
///   its cached checksums, unions them into
///   `ConfirmedDeletedStore` (starting each item's quarantine clock).
///   Inserted/updated ids re-hash and refresh both `LocalHashStore`
///   and `EverSeenStore`.
///
/// State lives entirely in injected stores — the reconciler itself is
/// stateless between calls. Callers are the background-refresh handler
/// and the foreground "Review & sync" button; both construct an instance
/// and invoke `runDeletionScan()`.
@MainActor
public final class PhotoKitPersistentChangeReconciler {

    /// Why the full-enumeration path ran. Distinguishes "no prior state"
    /// (first install, post-rescan, post-clear — fine, no deletions could
    /// have been missed) from "we had state but lost it" (token expired
    /// or unarchive failed — any deletions accumulated during the dormant
    /// window are now negative-signal-only, with no quarantine clock).
    /// Callers gate review behavior on this distinction.
    public enum FullEnumerationCause: Sendable, Equatable {
        /// No saved token (fresh install, post-clear, post-rescan).
        case firstRun
        /// Saved token couldn't be used: PhotoKit reported it expired,
        /// or the archived bytes failed to unarchive (typically OS
        /// upgrade changing the format).
        case tokenExpired
    }

    /// Outcome of a single scan. Callers surface these fields in the
    /// journal summary and Status-screen stats.
    public struct Result: Sendable, Equatable {
        /// Checksums this scan added to `ConfirmedDeletedStore` — the
        /// quarantine clock starts now for each.
        public let newlyConfirmedDeleted: Set<Checksum>
        /// Checksums removed from `ConfirmedDeletedStore` because their
        /// `PHAsset` surfaced again (user restored from Recently Deleted,
        /// iCloud re-downloaded). Protects against flapping libraries.
        public let unconfirmedByRestoration: Set<Checksum>
        /// True if the full-enumeration path ran — first scan, no saved
        /// token, or token expired. Drives the "rebuilding index" UI.
        public let didFullEnumeration: Bool
        /// When `didFullEnumeration` is true, why it ran. `nil` for
        /// incremental scans. The caller uses `.tokenExpired` as a
        /// signal to gate this pass's deletion candidates for review,
        /// since a lost token means any accumulated deletions arrive
        /// without a positive signal or quarantine clock.
        public let fullEnumerationCause: FullEnumerationCause?
        /// Count of `PHPersistentChange` events consumed. Always zero
        /// on a full-enumeration run.
        public let changeEventsProcessed: Int
        /// Assets whose expected iCloud download exceeded
        /// `maxICloudBytesPerAsset`. Enqueued in `DeferredHashStore`
        /// and retried on a later scan.
        public let deferredLarge: Int
        /// Summed download bytes for `deferredLarge`. Surfaced as
        /// "deferred: N assets, M GB" in the journal.
        public let deferredLargeBytes: Int64
        /// Assets whose hash exceeded `perAssetTimeoutSeconds` — almost
        /// always a stalled iCloud fetch. Retried next scan.
        public let deferredTimeout: Int
        /// Assets with no hashable resources (adjustment-only stubs,
        /// post-edit artifacts). Rare; a non-zero count is worth
        /// investigating.
        public let deferredEmpty: Int
        /// Assets whose iCloud download would exceed the user's hard
        /// ceiling (`iCloudMaxEverBytesMB`). Out-of-scope — no retry,
        /// no `DeferredHashStore` entry.
        public let aboveHardCeiling: Int
        /// Summed download bytes for `aboveHardCeiling`. Paired with
        /// the count for the "out-of-scope: N assets, M GB" readout.
        public let aboveHardCeilingBytes: Int64
        /// Items pulled off `DeferredHashStore` and successfully hashed
        /// on this scan. Zero when nothing was queued or when no queued
        /// item fit under the current soft limit.
        public let drainedFromQueue: Int
        /// Every checksum hashed during this scan — fresh inserts and
        /// stale-update re-hashes on the incremental path; the full
        /// enumeration set on the full path. Callers intersect this
        /// against the recent-trash journal index to detect "user
        /// restored locally what cairn already trashed on Immich"
        /// before the server's 30-day hard-delete clock fires.
        ///
        /// Defaults to `[]` so the existing test fakes that omit it
        /// keep compiling.
        public let recentlyObservedChecksums: Set<Checksum>

        /// For each checksum that flowed into `removedChecksums` during
        /// this scan via a known `localIdentifier` — either the cache
        /// lookup at delete time or the EditRetirementStore firstObserved
        /// anchor — records the source identifier. Lets the UI link the
        /// resulting quarantine entry back to the same logical photo as
        /// any inferred orphan that came in via OrphanReconciler matching
        /// the same localIdentifier. `[:]` for full-enumeration paths
        /// and for scans with no deletes.
        public let sourceLocalIdentifierByChecksum: [Checksum: String]

        /// Count of PHAssets discovered by the library→cache sweep —
        /// visible in the photo library but absent from both
        /// `LocalHashStore` and `DeferredHashStore` at scan time. They're
        /// folded into the insert pipeline for this scan; subsequent
        /// scans see an empty diff once they're hashed (or deferred).
        public let untrackedDiscovered: Int

        public init(
            newlyConfirmedDeleted: Set<Checksum>,
            unconfirmedByRestoration: Set<Checksum>,
            didFullEnumeration: Bool,
            fullEnumerationCause: FullEnumerationCause? = nil,
            changeEventsProcessed: Int,
            deferredLarge: Int = 0,
            deferredLargeBytes: Int64 = 0,
            deferredTimeout: Int = 0,
            deferredEmpty: Int = 0,
            aboveHardCeiling: Int = 0,
            aboveHardCeilingBytes: Int64 = 0,
            drainedFromQueue: Int = 0,
            recentlyObservedChecksums: Set<Checksum> = [],
            sourceLocalIdentifierByChecksum: [Checksum: String] = [:],
            untrackedDiscovered: Int = 0
        ) {
            self.newlyConfirmedDeleted = newlyConfirmedDeleted
            self.unconfirmedByRestoration = unconfirmedByRestoration
            self.didFullEnumeration = didFullEnumeration
            self.fullEnumerationCause = fullEnumerationCause
            self.changeEventsProcessed = changeEventsProcessed
            self.deferredLarge = deferredLarge
            self.deferredLargeBytes = deferredLargeBytes
            self.deferredTimeout = deferredTimeout
            self.deferredEmpty = deferredEmpty
            self.aboveHardCeiling = aboveHardCeiling
            self.aboveHardCeilingBytes = aboveHardCeilingBytes
            self.drainedFromQueue = drainedFromQueue
            self.recentlyObservedChecksums = recentlyObservedChecksums
            self.sourceLocalIdentifierByChecksum = sourceLocalIdentifierByChecksum
            self.untrackedDiscovered = untrackedDiscovered
        }
    }

    public enum Error: Swift.Error, Sendable {
        /// The user hasn't granted full Photos access. Callers should
        /// route back to the permission flow rather than retrying.
        case notAuthorized(PHAuthorizationStatus)
    }

    private let hashStore: any LocalHashStore
    private let confirmedDeleted: any ConfirmedDeletedStore
    private let everSeen: any EverSeenStore
    private let tokens: any PersistentChangeTokenStore
    /// Persistent queue of assets awaiting a later re-hash. `nil`
    /// disables queueing entirely (tests, legacy callers). When set,
    /// defer outcomes upsert rows and successful re-hashes remove
    /// them; `drainDeferred()` walks the queue directly.
    private let deferredStore: (any DeferredHashStore)?
    private let clock: @Sendable () -> Date
    /// Full-library fetch cap for on-device testing against libraries
    /// with tens of thousands of photos. `nil` disables the cap. Set
    /// from the `CAIRN_ASSET_CAP` env var at app launch. Only applies
    /// to the full-enumeration path — incremental scans are already
    /// bounded by the tiny change log.
    private let maxAssets: Int?
    /// Concurrent asset-hash ceiling. Trade-off:
    ///   - Higher saturates iCloud bandwidth on network-bound libraries
    ///     and wins some NAND parallelism.
    ///   - Lower caps peak memory (a parallel ProRes video can reserve
    ///     tens of MB each) and leaves more headroom for iOS BG slots.
    /// 4 empirically balances throughput and memory pressure on modern
    /// iPhones. Profile before moving it.
    private let maxConcurrentHashes: Int = 4

    /// Per-asset iCloud-download soft limit, in bytes. Summed across
    /// unavailable resources (Live Photos contribute both still and
    /// paired video) before we commit to a fetch; anything above
    /// defers. Configured via `CairnSettings.iCloudDownloadLimitMB` and
    /// threaded through by `AppDependencies`. `nil` disables the check.
    private let maxICloudBytesPerAsset: Int64?

    /// Permanent never-fetch ceiling, in bytes. Assets above this are
    /// out-of-scope: no hash attempt, no `DeferredHashStore` row. The
    /// distinction from `maxICloudBytesPerAsset` is intent — soft
    /// limit postpones, hard ceiling renounces.
    private let hardCeilingBytes: Int64?

    /// Max deferred-queue entries to drain during a foreground
    /// `runDeletionScan()`. Keeps scans snappy when the queue is large;
    /// the background `drainDeferred()` path ignores this budget and
    /// processes everything it's allowed to.
    private let foregroundDrainBudget: Int

    /// Wall-clock ceiling per asset in foreground mode. Small-looking
    /// assets can still stall on network hiccups or background
    /// throttling, so we race the hash against this timer and cancel
    /// the `PHAssetResourceManager` request on expiration. Timed-out
    /// assets land in the "deferred-timeout" bucket for retry next
    /// scan. 60s covers typical iCloud fetch variance without holding
    /// the UI hostage on a pathological fetch.
    ///
    /// **No timeout in `.unlimited` mode.** Drains (both BG and
    /// foreground "Hash now") skip the clock entirely — the user
    /// opted into "fetch as long as needed," and since PhotoKit has
    /// no partial-download resume, any timeout would create a
    /// connection-speed-dependent size ceiling with unbounded retry
    /// churn for items that don't fit. The BG path is already
    /// bounded by `BGProcessingTask` expiration; foreground "Hash
    /// now" is bounded by the user walking away.
    private let perAssetTimeoutSeconds: TimeInterval = 60
    /// Progress callback: `(done, total, newChecksums)`. The third
    /// parameter carries checksums produced since the last report so
    /// the caller can maintain a running "matched against server" count
    /// without re-scanning the store. Only the full-enumeration path
    /// fires these; incremental batches are small enough not to warrant
    /// progress UI.
    private let onHashProgress: @Sendable (Int, Int, Set<Checksum>) async -> Void

    /// Build a reconciler. All stores are injected so tests can wire
    /// in-memory fakes and so the same type works across the
    /// foreground scan and the background refresh.
    ///
    /// Defaults: `maxICloudBytesPerAsset` at 100 MB (keeps foreground
    /// sync snappy on optimized-storage libraries),
    /// `hardCeilingBytes` nil (no permanent skip unless the settings
    /// screen overrides), `foregroundDrainBudget` at 25 (quick skim
    /// without stalling the UI). `clock` is injectable for
    /// time-sensitive tests.
    /// Optional metadata store. When wired, the reconciler records
    /// `(filename, creationDate, …)` for every observed insert/update
    /// before attempting to hash. Lets the orphan-reconciliation path
    /// recover identity for assets that were deleted before cairn
    /// could finish hashing them.
    private let metadataStore: (any LocalAssetMetadataStore)?

    /// Optional first-observed checksum store. When wired, the
    /// reconciler records `firstObserved` once per id (first-write-
    /// wins) and consults it to split edit-retired SHA1s into
    /// "protect" (matches firstObserved → keep on Immich, the
    /// original-content backup) and "intermediate" (everything else
    /// → quarantine). Default `nil` keeps existing test callers
    /// working unchanged — when absent, all retired SHA1s flow
    /// through the legacy diff-only path.
    private let editRetirement: (any EditRetirementStore)?

    /// Optional sidecar to `ConfirmedDeletedStore` that persists the
    /// source `localIdentifier` per retired checksum. Lets Pending
    /// Review group quarantined entries with inferred orphans
    /// across syncs — the per-scan `sourceLocalIdentifierByChecksum`
    /// in `Result` evaporates after the immediate post-delete sync,
    /// so without this store the linkage is only valid for one pass.
    /// Default `nil` keeps existing test callers working unchanged.
    private let deletionSource: (any DeletionSourceStore)?

    public init(
        hashStore: any LocalHashStore,
        confirmedDeleted: any ConfirmedDeletedStore,
        everSeen: any EverSeenStore,
        tokens: any PersistentChangeTokenStore,
        deferredStore: (any DeferredHashStore)? = nil,
        metadataStore: (any LocalAssetMetadataStore)? = nil,
        editRetirement: (any EditRetirementStore)? = nil,
        deletionSource: (any DeletionSourceStore)? = nil,
        maxAssets: Int? = nil,
        maxICloudBytesPerAsset: Int64? = 100 * 1024 * 1024,
        hardCeilingBytes: Int64? = nil,
        foregroundDrainBudget: Int = 25,
        onHashProgress: @escaping @Sendable (Int, Int, Set<Checksum>) async -> Void = { _, _, _ in },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.hashStore = hashStore
        self.confirmedDeleted = confirmedDeleted
        self.everSeen = everSeen
        self.tokens = tokens
        self.deferredStore = deferredStore
        self.metadataStore = metadataStore
        self.editRetirement = editRetirement
        self.deletionSource = deletionSource
        self.maxAssets = maxAssets
        self.maxICloudBytesPerAsset = maxICloudBytesPerAsset
        self.hardCeilingBytes = hardCeilingBytes
        self.foregroundDrainBudget = foregroundDrainBudget
        self.onHashProgress = onHashProgress
        self.clock = clock
    }

    /// Run one scan. Picks the incremental path when a valid saved
    /// token exists, otherwise falls through to full enumeration.
    /// Throws `Error.notAuthorized` if Photos access has been revoked.
    /// `skipDrain: true` skips the foreground deferred-queue drain —
    /// use for quick auto-syncs where you don't want multi-minute
    /// iCloud downloads blocking the UI.
    public func runDeletionScan(skipDrain: Bool = false) async throws -> Result {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized else {
            throw Error.notAuthorized(status)
        }

        // Try incremental first. Fall back to full enumeration on any of:
        //   - no saved token yet → `.firstRun`
        //   - token unarchive fails (e.g. OS upgrade changed the format) →
        //     `.tokenExpired` (data was lost just the same)
        //   - PhotoKit reports the token as expired → `.tokenExpired`
        if let saved = try await tokens.load() {
            if let token = Self.unarchiveToken(saved.data) {
                do {
                    return try await runIncremental(since: token, skipDrain: skipDrain)
                } catch let ns as NSError where Self.isTokenExpired(ns) {
                    // Drop the stale token and re-enumerate. Next run will
                    // pick up changes against the new baseline.
                    try? await tokens.clear()
                    return try await runFullEnumeration(cause: .tokenExpired)
                }
            }
            // Saved-but-unparseable: treat as expired. The previous baseline's
            // change log is unreachable, so accumulated deletions are
            // negative-signal-only — the gating is the same as a real expiry.
            try? await tokens.clear()
            return try await runFullEnumeration(cause: .tokenExpired)
        }
        return try await runFullEnumeration(cause: .firstRun)
    }

    // MARK: - Incremental path

    /// Processes every `PHPersistentChange` that landed since the saved
    /// token: translates `deletedLocalIdentifiers` into
    /// `ConfirmedDeletedStore.union(_:at:)` writes (starting the per-item
    /// quarantine clock) and `insertedLocalIdentifiers` / `updatedLocalIdentifiers`
    /// into fresh hashes that refresh both `LocalHashStore` and
    /// `EverSeenStore`. Ends with an orphan sweep (`reconcileCacheAgainstLibrary`)
    /// and a best-effort drain of `DeferredHashStore`.
    ///
    /// On `PHPhotosError.persistentChangeTokenExpired` the caller
    /// falls back to `runFullEnumeration()` — Apple doesn't document
    /// the retention window, so token expiry is a normal code path.
    private func runIncremental(since token: PHPersistentChangeToken, skipDrain: Bool = false) async throws -> Result {
        let fetchResult = try PHPhotoLibrary.shared().fetchPersistentChanges(since: token)

        var insertedIds: Set<String> = []
        var updatedIds: Set<String> = []
        var deletedIds: Set<String> = []
        var events = 0

        for change in fetchResult {
            events += 1
            do {
                let details = try change.changeDetails(for: PHObjectType.asset)
                insertedIds.formUnion(details.insertedLocalIdentifiers)
                updatedIds.formUnion(details.updatedLocalIdentifiers)
                deletedIds.formUnion(details.deletedLocalIdentifiers)
            } catch let ns as NSError where ns.domain == PHPhotosErrorDomain
                                          && ns.code == PHPhotosError.persistentChangeDetailsUnavailable.rawValue {
                // Per-change details are unavailable for this specific
                // change — treat as "something happened but we don't know
                // what." Safe fallback: resync that specific range by
                // reinterpreting the library state afterwards, but for now
                // we proceed with the others and accept the miss. A future
                // iteration could trigger a full re-enum in this case.
                continue
            }
        }

        // Library→cache untracked sweep. PHAssets that exist in the visible
        // library but aren't in either `LocalHashStore` or `DeferredHashStore`
        // are entirely invisible to cairn — they were never enumerated, never
        // hashed, never deferred. (Causes: stale CAIRN_ASSET_CAP from a debug
        // run, an interrupted full enum, missed insert events while cairn was
        // suspended.) Find them and merge into `insertedIds` so the existing
        // hash + ever-seen + metadata pipeline picks them up. Subsequent syncs
        // see an empty diff once the gap is closed.
        let untrackedIds = try await discoverUntrackedAssets()
        if !untrackedIds.isEmpty {
            Self.reconLog.notice("[cairn.recon] untracked sweep: \(untrackedIds.count, privacy: .public) PHAssets visible but neither indexed nor queued — adding to insert pipeline")
            insertedIds.formUnion(untrackedIds)
        }

        // Diagnostic log — makes "why didn't my delete propagate?"
        // answerable from the device console without rebuilding.
        Self.logIncrementalHeader(
            events: events,
            inserted: insertedIds,
            updated: updatedIds,
            deleted: deletedIds
        )

        // Resolve deleted identifiers to checksums via the cache AND
        // via the edit-retirement anchor. An identifier the cache
        // doesn't know about simply yields no cached checksums —
        // likely an asset created and destroyed in the same window
        // without us ever hashing it. Including `firstObserved`
        // ensures the original-content SHA1 propagates to quarantine
        // when the asset is genuinely deleted, even if intermediate
        // edits cleared it from the cache earlier.
        var removedChecksums: Set<Checksum> = []
        // Track the source `localIdentifier` per retired checksum so the
        // UI can later collapse a quarantined original and an inferred-
        // orphan edit (which OrphanReconciler resolves through the same
        // localIdentifier) into one card. Filename + creationDate
        // grouping fails when Immich stores microsecond-mismatched
        // creation dates for the original-vs-edit upload pair; the
        // localIdentifier match is unambiguous.
        var sourceLocalIdentifierByChecksum: [Checksum: String] = [:]
        for id in deletedIds {
            let cached = try await hashStore.checksums(for: id)
            removedChecksums.formUnion(cached)
            for c in cached { sourceLocalIdentifierByChecksum[c] = id }
            if let editRetirement {
                let firstObserved = try await editRetirement.firstObserved(for: id)
                removedChecksums.formUnion(firstObserved)
                for c in firstObserved { sourceLocalIdentifierByChecksum[c] = id }
            }
        }

        // Single PHAsset.fetchAssets pass that records metadata for
        // every observed id (so a deletion-before-hash still has
        // correlation data) AND filters update events whose
        // modificationDate didn't actually advance — PhotoKit fires
        // updates for metadata-only changes (favorites, hidden, album
        // moves) that don't change pixel bytes. Skipping those here
        // saves 2,000+ unnecessary re-hashes on a typical relaunch.
        let observed = try await observeAndFilter(insertedIds: insertedIds, updatedIds: updatedIds)
        let staleUpdates = observed.staleUpdates
        if updatedIds.count > 0 && staleUpdates.count != updatedIds.count {
            let skipped = updatedIds.count - staleUpdates.count
            hashLog.notice("[cairn.recon] skipped \(skipped, privacy: .public) update events with unchanged modDate")
        }

        // Capture pre-set checksums for the ids we're about to re-hash.
        // When a user edits a photo (filter, crop, markup), PhotoKit
        // advances modificationDate and we re-hash; `set(_:for:)`
        // replaces the rows. The OLD SHA1 disappears from the cache but
        // stays in EverSeen (which is union-only). We need this snapshot
        // to compute the retired set (`prior \ new`) and decide whether
        // each retired SHA1 is the original-content anchor (protect) or
        // an intermediate edit (quarantine). It also tells us whether
        // an id was previously cached at all — if not, this observation
        // gets seeded into `EditRetirementStore` as the firstObserved
        // anchor for the id.
        let preExistingChecksums = try await hashStore.entries(
            forIdentifiers: insertedIds.union(staleUpdates)
        ).mapValues(\.checksums)

        // Inserted: hash the new assets, stash in local cache + ever-seen.
        // Defer counts from both inserted + updated batches accumulate
        // into the Result.
        let insertedBatch = try await hashAssets(ids: insertedIds)
        var addedChecksums: Set<Checksum> = []
        var retiredByEdit: Set<Checksum> = []
        for (id, checksums) in insertedBatch.checksumsByID {
            try await hashStore.set(checksums, for: id)
            addedChecksums.formUnion(checksums)
            if let prior = preExistingChecksums[id], !prior.isEmpty {
                retiredByEdit.formUnion(prior.subtracting(checksums))
                // Lazy migration: pre-EditRetirementStore caches have
                // no firstObserved anchor. Seed with `prior` (the bytes
                // cairn knew about before this event). First-write-wins,
                // so a no-op if already seeded by an earlier session.
                // Without this, the partition below would treat `prior`
                // as intermediate and quarantine the original on edit.
                try await editRetirement?.recordFirstObserved(prior, for: id)
            } else {
                // No prior cache entry → this is the first time cairn
                // has seen content for this id. Seed the edit-retirement
                // anchor. First-write-wins inside the store; safe to
                // call from any observation site.
                try await editRetirement?.recordFirstObserved(checksums, for: id)
            }
        }
        if !addedChecksums.isEmpty {
            try await everSeen.union(addedChecksums)
        }

        let updatedBatch = try await hashAssets(ids: staleUpdates)
        var updatedChecksums: Set<Checksum> = []
        for (id, checksums) in updatedBatch.checksumsByID {
            try await hashStore.set(checksums, for: id)
            updatedChecksums.formUnion(checksums)
            if let prior = preExistingChecksums[id], !prior.isEmpty {
                retiredByEdit.formUnion(prior.subtracting(checksums))
                // Lazy migration — same reasoning as the inserts branch
                // above. Seed with `prior` so the partition doesn't
                // wrongly classify retired bytes as intermediate.
                try await editRetirement?.recordFirstObserved(prior, for: id)
            } else {
                // "Updated" event for an id we've never cached — treat
                // first observation as the anchor. Without this, an
                // edit-then-delete sequence on a never-cached asset
                // would have no firstObserved to propagate at delete
                // time, leaving the original SHA1 unprotected on Immich.
                try await editRetirement?.recordFirstObserved(checksums, for: id)
            }
        }
        if !updatedChecksums.isEmpty {
            try await everSeen.union(updatedChecksums)
        }

        // Capture pre-mutation state so `unconfirmedByRestoration` reports
        // the actual delta, not the post-`remove` view.
        let allRecentlyObserved = addedChecksums.union(updatedChecksums)
        let priorConfirmed: Set<Checksum>
        if !allRecentlyObserved.isEmpty {
            priorConfirmed = Set(try await confirmedDeleted.snapshot().keys)
        } else {
            priorConfirmed = []
        }

        // Purge the cache for deleted ids so subsequent `allChecksums()`
        // reflects post-deletion state. The actual confirmed-deleted union
        // is deferred until after the orphan sweep — see the `trulyAbsent`
        // filter below for why.
        let now = clock()
        if !deletedIds.isEmpty {
            try await hashStore.removeAll(for: deletedIds)
        }

        // **Orphan safety net.** PhotoKit occasionally reports a
        // soft-delete via a channel other than `deletedLocalIdentifiers`
        // (observed: an "updated" event on the asset's visibility
        // state as it moves to Recently Deleted). Our update path
        // fetches with default options, which exclude hidden/RD
        // assets — so the fetch returns nothing, nothing re-hashes,
        // and the old cache entry is never purged. Result:
        // `indexedCount` drifts above the real visible count and
        // the deletion never propagates to Immich.
        //
        // Belt-and-braces fix: after processing the reported events,
        // diff `LocalHashStore` keys against the current PHAsset
        // fetch. Any id in cache that PhotoKit can't resolve is
        // retired the same way a cleanly-detected delete would be
        // (confirmedDeleted union + cache purge).
        // Protect ids this pass's insert/update paths just hashed
        // from being mis-flagged as orphans. Without this guard,
        // a race between `PHAsset.fetchAssets` (inside
        // `reconcileCacheAgainstLibrary`) and our `hashStore.set`
        // writes can make a just-hashed asset look cache-only and
        // cause the orphan path to delete it.
        // Always run — `events=0` doesn't imply "no drift." The
        // persistent-change log is event-relative-to-the-saved-token,
        // not authoritative for current library state. A deletion that
        // happened before the saved token (e.g. between the previous
        // sync and an app rebuild/reinstall) is invisible to
        // fetchPersistentChanges but must still be propagated, or the
        // negative-signal candidate path silently skips quarantine.
        // The cost is one PHAsset.fetchAssets + a set diff per sync;
        // a few hundred ms on a 7k library. Earlier code gated this
        // on `hasChanges` for relaunch perf; the gate was incorrect.
        let preOrphanCacheCount = try await hashStore.indexedCount()
        let orphanResult = try await reconcileCacheAgainstLibrary(
            alreadyHandledDeletedIds: deletedIds,
            protectedIds: insertedIds.union(updatedIds),
            now: now
        )
        Self.reconLog.notice("[cairn.recon] orphan sweep ran: cache=\(preOrphanCacheCount, privacy: .public) orphans=\(orphanResult.orphanIds.count, privacy: .public) recovered-checksums=\(orphanResult.checksums.count, privacy: .public)")
        if !orphanResult.checksums.isEmpty {
            removedChecksums.formUnion(orphanResult.checksums)
        }
        // Same source-id capture as the explicit-delete path above —
        // orphan-swept checksums need to collapse alongside any
        // inferred-orphan match for the same logical photo. The orphan
        // reconciler captures the per-id mapping before purging the
        // cache because the post-purge state has nothing to query.
        for (c, id) in orphanResult.sourceIdByChecksum {
            sourceLocalIdentifierByChecksum[c] = id
        }
        // Orphan-swept ids may also have firstObserved anchors. Pull
        // those in so the original-content SHA1 propagates to
        // quarantine alongside the cache rows the orphan sweep already
        // recovered. Without this, an asset deleted via the back-
        // channel path that PhotoKit's `deletedLocalIdentifiers`
        // missed would lose its original-content propagation.
        if let editRetirement, !orphanResult.orphanIds.isEmpty {
            for id in orphanResult.orphanIds {
                let anchor = try await editRetirement.firstObserved(for: id)
                removedChecksums.formUnion(anchor)
                for c in anchor { sourceLocalIdentifierByChecksum[c] = id }
            }
        }

        // Filter `removedChecksums` against the post-purge cache. A SHA1
        // shared across two PHAssets (e.g. self-AirDropped duplicate) is
        // still locally present after one is deleted; confirming it as
        // deleted would start a wrongful quarantine clock against an
        // asset the user still has. `allChecksums()` here reflects every
        // cache mutation so far this pass — deleted-id purge, orphan
        // sweep purge, and the insert/update writes above.
        let stillLocal = try await hashStore.allChecksums()
        let trulyAbsent = Self.confirmableDeletions(removed: removedChecksums, stillLocal: stillLocal)
        if !trulyAbsent.isEmpty {
            try await confirmedDeleted.union(trulyAbsent, at: now)
            // Persist the source-id mapping for the truly-absent
            // checksums so later syncs can still group quarantined
            // entries with inferred orphans by their shared origin
            // localIdentifier. Scoped to `trulyAbsent` (not the wider
            // `sourceLocalIdentifierByChecksum`) because anything still
            // present locally hasn't been retired and shouldn't poison
            // the persistent store with a stale mapping.
            if let deletionSource {
                let toRecord = sourceLocalIdentifierByChecksum.filter { trulyAbsent.contains($0.key) }
                if !toRecord.isEmpty {
                    try await deletionSource.record(toRecord)
                }
            }
        }

        // Edit-retirement partition. SHA1s the cache held before this
        // pass that got replaced by new ones (the user edited the
        // photo). Each id's `firstObserved` set is the original-content
        // anchor — those SHA1s are sacred while the id is alive in
        // PhotoKit, even after edits, because Immich's copy of the
        // original is the user's backup. Only intermediate edits
        // (retired ≠ firstObserved) flow through quarantine.
        //
        // Filter against `stillLocal` first so a SHA1 still held under
        // another id (rare — duplicate import) doesn't get wrongly
        // stamped regardless of which bucket it would have landed in.
        let retiredAbsent = retiredByEdit.subtracting(stillLocal)
        if !retiredAbsent.isEmpty {
            // Build the union of firstObserved across every id whose
            // entry got mutated this pass. Cheap — only the ids we
            // re-hashed contribute to retirement, and most have an
            // anchor seeded on first observation.
            var firstObservedUnion: Set<Checksum> = []
            if let editRetirement {
                for id in insertedIds.union(staleUpdates) {
                    let anchor = try await editRetirement.firstObserved(for: id)
                    firstObservedUnion.formUnion(anchor)
                }
            }
            let parts = Self.partitionRetiredByFirstObserved(
                retired: retiredAbsent,
                firstObserved: firstObservedUnion
            )
            if !parts.intermediate.isEmpty {
                try await confirmedDeleted.union(parts.intermediate, at: now)
            }
            Self.reconLog.notice("[cairn.recon] intermediate edits retired \(parts.intermediate.count, privacy: .public) → quarantine; protected \(parts.protected.count, privacy: .public) firstObserved → kept on Immich")
        }

        // Drop edit-retirement anchors for genuinely-deleted ids and
        // orphan-swept ids (PhotoKit reported the deletion through a
        // back channel rather than `deletedLocalIdentifiers`). Done
        // after the union above so a delete in the same pass as an
        // edit (rare but possible: edit, save, then trash) still
        // propagates the firstObserved SHA1 through `removedChecksums`
        // before the anchor disappears.
        let idsToCleanup = deletedIds.union(orphanResult.orphanIds)
        if !idsToCleanup.isEmpty {
            try await editRetirement?.remove(for: idsToCleanup)
        }

        // Restoration: when an insert/update surfaces a checksum that was
        // previously confirmed-deleted, un-confirm it. A subsequent
        // deletion will start a fresh quarantine clock.
        if !allRecentlyObserved.isEmpty {
            try await confirmedDeleted.remove(allRecentlyObserved)
            // Drop the persisted source-id mapping alongside, so a
            // re-deleted asset re-records its current source id rather
            // than carrying a stale one.
            try await deletionSource?.remove(allRecentlyObserved)
        }

        // Save the new token using the library's current token as the
        // safest checkpoint. Using currentChangeToken (rather than any of
        // the per-change tokens) guarantees the next incremental scan sees
        // every event that happened during *this* one, including events
        // that fired between the fetch and this call.
        let newToken = PHPhotoLibrary.shared().currentChangeToken
        try await tokens.save(.init(
            data: Self.archiveToken(newToken),
            savedAt: now
        ))

        // Best-effort drain of queued items. Incremental scans skim the
        // top N (foregroundDrainBudget) deferred entries and try them
        // again under foreground settings. Skipped when the caller
        // passes `skipDrain: true` (e.g. the auto-sync on launch).
        let drained = try await drainInternal(
            softLimitMode: .useSettings,
            budget: skipDrain ? 0 : foregroundDrainBudget
        )

        return Result(
            newlyConfirmedDeleted: trulyAbsent,
            unconfirmedByRestoration: allRecentlyObserved.intersection(priorConfirmed),
            didFullEnumeration: false,
            changeEventsProcessed: events,
            deferredLarge: insertedBatch.deferredLarge + updatedBatch.deferredLarge + drained.batch.deferredLarge,
            deferredLargeBytes: insertedBatch.deferredLargeBytes + updatedBatch.deferredLargeBytes + drained.batch.deferredLargeBytes,
            deferredTimeout: insertedBatch.deferredTimeout + updatedBatch.deferredTimeout + drained.batch.deferredTimeout,
            deferredEmpty: insertedBatch.deferredEmpty + updatedBatch.deferredEmpty + drained.batch.deferredEmpty,
            aboveHardCeiling: insertedBatch.aboveHardCeiling + updatedBatch.aboveHardCeiling + drained.batch.aboveHardCeiling,
            aboveHardCeilingBytes: insertedBatch.aboveHardCeilingBytes + updatedBatch.aboveHardCeilingBytes + drained.batch.aboveHardCeilingBytes,
            drainedFromQueue: drained.successCount,
            recentlyObservedChecksums: allRecentlyObserved,
            sourceLocalIdentifierByChecksum: sourceLocalIdentifierByChecksum,
            untrackedDiscovered: untrackedIds.count
        )
    }

    /// Filter the raw "removed via deletion + orphan sweep" checksum set
    /// down to the subset that's actually absent from the post-purge
    /// cache. A SHA1 shared across two PHAssets (duplicate import,
    /// self-AirDrop) survives the deletion of one and must NOT be
    /// stamped into `ConfirmedDeletedStore` — doing so would start a
    /// wrongful quarantine clock against an asset the user still has.
    /// Internal-but-static so the test target can exercise this without
    /// constructing a full reconciler. `nonisolated` because the body
    /// is pure — no state, no main-thread requirement.
    nonisolated static func confirmableDeletions(
        removed: Set<Checksum>,
        stillLocal: Set<Checksum>
    ) -> Set<Checksum> {
        removed.subtracting(stillLocal)
    }

    /// Pure set-difference for the library→cache untracked sweep:
    /// PHAssets visible in the live library but absent from both
    /// `LocalHashStore` and `DeferredHashStore`. The live
    /// `discoverUntrackedAssets` helper is just this op wrapped around
    /// three PhotoKit / store snapshots; factored out so tests can
    /// exercise the load-bearing logic without a fake PHPhotoLibrary.
    /// `nonisolated` because the body is pure.
    nonisolated static func untrackedFromLibrary(
        liveIds: Set<String>,
        cacheIds: Set<String>,
        deferredIds: Set<String>
    ) -> Set<String> {
        liveIds.subtracting(cacheIds).subtracting(deferredIds)
    }

    /// Pure partition: split edit-retired SHA1s into "protected"
    /// (overlap firstObserved — original content; never quarantine)
    /// and "intermediate" (post-edit residue — quarantine then trash).
    ///
    /// **Why this matters.** When a user edits a photo, PhotoKit
    /// advances `modificationDate` and we re-hash; the old SHA1
    /// retires from the cache but stays alive on Immich. The legacy
    /// behavior unioned every retired SHA1 into `ConfirmedDeletedStore`,
    /// which destroyed the original-content backup 14 days later for
    /// any photo the user kept locally. The fix anchors firstObserved
    /// once per id and exempts those SHA1s from quarantine for as long
    /// as the id is alive. Only intermediate edits (retired SHA1s that
    /// aren't the firstObserved set) flow through to quarantine.
    ///
    /// Internal-but-static so tests exercise the partition without a
    /// full PhotoKit pipeline. `nonisolated` because the body is pure.
    nonisolated static func partitionRetiredByFirstObserved(
        retired: Set<Checksum>,
        firstObserved: Set<Checksum>
    ) -> (protected: Set<Checksum>, intermediate: Set<Checksum>) {
        let protected = retired.intersection(firstObserved)
        let intermediate = retired.subtracting(protected)
        return (protected, intermediate)
    }

    // MARK: - Deferred-queue drain

    /// Drain the entire `DeferredHashStore` without honoring the
    /// foreground soft limit. Called from `BGProcessingTask` slots and
    /// the manual Settings → "Hash now" action.
    ///
    /// The hard ceiling still applies — assets above it were never
    /// queued, but a user who lowered the ceiling after queueing
    /// wouldn't expect retroactive fetches anyway.
    ///
    /// The returned `Result` mirrors `runDeletionScan()` but only
    /// carries drain-related fields; deletion-tracking fields stay
    /// zero because a drain isn't a deletion scan.
    @discardableResult
    public func drainDeferred() async throws -> Result {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized else {
            throw Error.notAuthorized(status)
        }
        let drained = try await drainInternal(softLimitMode: .unlimited, budget: .max)
        return Result(
            newlyConfirmedDeleted: [],
            unconfirmedByRestoration: [],
            didFullEnumeration: false,
            changeEventsProcessed: 0,
            deferredLarge: drained.batch.deferredLarge,
            deferredLargeBytes: drained.batch.deferredLargeBytes,
            deferredTimeout: drained.batch.deferredTimeout,
            deferredEmpty: drained.batch.deferredEmpty,
            aboveHardCeiling: drained.batch.aboveHardCeiling,
            aboveHardCeilingBytes: drained.batch.aboveHardCeilingBytes,
            drainedFromQueue: drained.successCount
        )
    }

    /// Shared body for the foreground mini-drain and the background
    /// full drain. Reads up to `budget` entries from
    /// `DeferredHashStore`, filters them against the current soft
    /// limit, fetches the matching `PHAsset`s, re-hashes under
    /// `softLimitMode`, and unions fresh checksums into `everSeen`
    /// (matching the insert/update paths). Successful rows drop off
    /// the queue via `hashAssets`' batched remove; still-too-large
    /// and timed-out rows re-upsert so `firstDeferredAt` stays
    /// accurate for age tracking.
    ///
    /// Returns the batch stats plus count of queue items that actually
    /// hashed on this pass (not the same as `batch.checksumsByID.count`
    /// — hashing may have produced checksums the cache already knew
    /// about; here we care about "how many we took off the queue").
    private func drainInternal(
        softLimitMode: SoftLimitMode,
        budget: Int
    ) async throws -> (batch: HashBatchResult, successCount: Int) {
        guard let deferredStore, budget > 0 else {
            return (HashBatchResult(), 0)
        }
        let queued = try await deferredStore.snapshot()
        if queued.isEmpty {
            return (HashBatchResult(), 0)
        }

        // **Pre-filter** so we don't waste a PHAsset fetch + hash call
        // on items we already know will re-defer. The queue records the
        // reason + size at defer time, so we can cheaply predict the
        // outcome of a retry under the current settings:
        //
        //   - `.tooLarge` with a known size > current soft limit →
        //     skip. Foreground won't hash it; the background drain
        //     (which passes `.unlimited`) will, eventually.
        //   - `.timedOut` → always retry. Transient by nature.
        //   - `.noHashableResources` → always retry. Cheap.
        //   - Unknown size → retry (let the pipeline re-measure).
        //
        // For the BG `.unlimited` path, everything qualifies except
        // items above the hard ceiling. The soft limit is a foreground
        // budget concern; the hard ceiling is a permanent scope boundary.
        let softLimitBytes = self.maxICloudBytesPerAsset
        let hardCeiling = self.hardCeilingBytes
        let candidates: [DeferredHashEntry]
        switch softLimitMode {
        case .unlimited:
            candidates = queued.filter { entry in
                guard let hardCeiling,
                      let size = entry.sizeBytes else { return true }
                return size <= hardCeiling
            }
        case .useSettings:
            candidates = queued.filter { entry in
                guard entry.reason == .tooLarge,
                      let size = entry.sizeBytes else {
                    return true
                }
                if let hardCeiling, size > hardCeiling { return false }
                guard let softLimitBytes else { return true }
                return size <= softLimitBytes
            }
        }
        if candidates.isEmpty {
            return (HashBatchResult(), 0)
        }

        // **Smallest-first.** iOS grants background slots of bounded
        // duration (often tens of seconds for BGProcessingTask, rarely
        // the full "few minutes" quota), and each drained asset
        // requires a full iCloud download. Processing small items
        // first:
        //   - maximizes item throughput per slot (clear more of the
        //     queue before iOS terminates us),
        //   - reduces wasted work if iOS kills us mid-download (a
        //     partial 3.5GB fetch is worse than a finished 100MB one),
        //   - matches the user's intuition: "the queue is shrinking"
        //     reads well when the count drops fast.
        // Unknown-size rows (`.timedOut`, `.noHashableResources`) sort
        // after known sizes — we'd rather handle measurable work
        // first and leave the edge cases for last. Final tiebreak on
        // `firstDeferredAt` so identical-size items stay stable
        // across runs.
        let ordered = candidates.sorted { lhs, rhs in
            let l = lhs.sizeBytes ?? .max
            let r = rhs.sizeBytes ?? .max
            if l != r { return l < r }
            return lhs.firstDeferredAt < rhs.firstDeferredAt
        }
        let toProcess = Array(ordered.prefix(budget))
        let idsToProcess = toProcess.map { $0.localIdentifier }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: idsToProcess, options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetch.count)
        fetch.enumerateObjects { asset, _, _ in assets.append(asset) }

        // Drop any ids that PhotoKit no longer knows about (asset was
        // deleted while queued). Those rows are stale — remove them
        // from the queue so we don't re-try forever.
        let livingIds = Set(assets.map { $0.localIdentifier })
        let stale = Set(idsToProcess).subtracting(livingIds)
        if !stale.isEmpty {
            try? await deferredStore.remove(stale)
        }

        // Skip assets that were already hashed in a prior run (e.g.
        // a previous "Hash now" tap that succeeded but was cancelled
        // before the bulk deferred-queue removal completed). Match by
        // modificationDate so PhotoKit edits trigger a re-hash. This
        // avoids re-downloading large iCloud assets every retry.
        let cachedEntries = try await hashStore.entries(forIdentifiers: Set(assets.map(\.localIdentifier)))
        var alreadyHashed: Set<String> = []
        for asset in assets {
            guard let entry = cachedEntries[asset.localIdentifier], !entry.checksums.isEmpty else { continue }
            if let cachedDate = entry.modificationDate,
               let currentDate = asset.modificationDate,
               cachedDate == currentDate {
                alreadyHashed.insert(asset.localIdentifier)
            }
        }
        if !alreadyHashed.isEmpty {
            try? await deferredStore.remove(alreadyHashed)
        }
        let assetsToHash = assets.filter { !alreadyHashed.contains($0.localIdentifier) }

        // Pass `reportProgressWithTotal` so `onHashProgress` actually
        // fires during drains. Without it, `library.indexed` wouldn't
        // tick (the callback is the only code path that reads
        // `indexedCount()` live) and `syncProgress` would stay nil —
        // user sees "Syncing…" with no progress hint for minutes.
        let batch = try await hashAssets(
            assets: assetsToHash,
            softLimitMode: softLimitMode,
            reportProgressWithTotal: assetsToHash.count
        )

        // Union freshly-hashed checksums into ever-seen — matches the
        // insert/update paths. Without this, a queued item that finally
        // hashes wouldn't enter the reconciliation surface.
        var fresh: Set<Checksum> = []
        for (_, cks) in batch.checksumsByID { fresh.formUnion(cks) }
        if !fresh.isEmpty {
            try? await everSeen.union(fresh)
        }
        return (batch, batch.checksumsByID.count)
    }

    // MARK: - Full-enumeration path

    /// Walk the entire user library, hash every asset, rebuild
    /// `LocalHashStore` from scratch, and checkpoint the current
    /// `PHPersistentChangeToken`. Runs on first scan, after token
    /// expiry, or when `tokens.load()` returns nil. Does **not** union
    /// anything into `ConfirmedDeletedStore` — a full enumeration is a
    /// resync, not a positive deletion signal. Default `cause` keeps
    /// existing test callers working without changes.
    private func runFullEnumeration(cause: FullEnumerationCause = .firstRun) async throws -> Result {
        // Capture the baseline *before* we enumerate, so any changes that
        // happen during enumeration are picked up by the next incremental
        // scan rather than lost to the gap.
        let baselineToken = PHPhotoLibrary.shared().currentChangeToken

        // Enumerate the full library, hashing per-asset, rebuilding the
        // local hash cache from scratch. We don't union into
        // confirmed-deleted here — a full enumeration is a resync, not a
        // positive deletion signal. `hashAllCurrentAssets` persists each
        // asset's checksums into `hashStore` as it goes (resume-friendly)
        // and seeds the edit-retirement anchor for ids it hashes for the
        // first time.
        let batch = try await hashAllCurrentAssets()
        var allChecksums: Set<Checksum> = []
        for (_, checksums) in batch.checksumsByID {
            allChecksums.formUnion(checksums)
        }
        if !allChecksums.isEmpty {
            try await everSeen.union(allChecksums)
        }

        let now = clock()
        try await tokens.save(.init(
            data: Self.archiveToken(baselineToken),
            savedAt: now
        ))

        return Result(
            newlyConfirmedDeleted: [],
            unconfirmedByRestoration: [],
            didFullEnumeration: true,
            fullEnumerationCause: cause,
            changeEventsProcessed: 0,
            deferredLarge: batch.deferredLarge,
            deferredLargeBytes: batch.deferredLargeBytes,
            deferredTimeout: batch.deferredTimeout,
            deferredEmpty: batch.deferredEmpty,
            aboveHardCeiling: batch.aboveHardCeiling,
            aboveHardCeilingBytes: batch.aboveHardCeilingBytes,
            recentlyObservedChecksums: allChecksums
        )
    }

    // MARK: - Hashing helpers

    /// Hash every asset visible in the user library, keyed by
    /// `localIdentifier`. The only hashing path long enough to drive
    /// `onHashProgress`.
    ///
    /// **Resume semantics.** Asset ids already in `LocalHashStore`
    /// short-circuit without re-hashing — cancellation-safe by
    /// design. Stale rows (PhotoKit `modificationDate` advanced past
    /// the cached one) re-hash; rows with no cached modDate (legacy
    /// pre-field rows, tests that don't wire it) also re-hash so we
    /// err toward correctness. The incremental path picks up any
    /// edits that happened between cancellation and resume.
    private func hashAllCurrentAssets() async throws -> HashBatchResult {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.includeAssetSourceTypes = [.typeUserLibrary]
        // Sort descending by creationDate so the testing cap
        // picks the **most recent N** assets, not the oldest. In
        // a real testing loop the user is adding new photos /
        // screenshots to verify behavior; covering those directly
        // (rather than ancient library photos that happen to sort
        // first) matches intent. Only `creationDate` is passed to
        // PhotoKit — its `sortDescriptors` allowlist is narrow;
        // the in-memory tiebreaker below handles identical
        // timestamps (bursts, imports).
        options.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: false),
        ]

        let fetchResult = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in assets.append(asset) }

        // Stable secondary sort. Primary is descending creationDate
        // (newest first); localIdentifier tiebreak gives full
        // determinism across runs — same N assets selected each
        // time so a capped test loop stays reproducible.
        assets.sort { lhs, rhs in
            let l = lhs.creationDate ?? .distantPast
            let r = rhs.creationDate ?? .distantPast
            if l != r { return l > r }
            return lhs.localIdentifier < rhs.localIdentifier
        }

        // Testing cap — picks the newest N assets (see sort above).
        // Lets on-device testers hash a small, recency-biased sample
        // rather than wait through a full-library pass.
        if let cap = maxAssets, assets.count > cap {
            assets = Array(assets.prefix(cap))
        }

        // Record metadata up-front for the entire enumeration set —
        // even if hashing is interrupted (cancellation, BG slot
        // expiration), we'll still have filename + creationDate for
        // every observed asset, ready for the orphan-correlation path.
        try await recordFullEnumerationMetadata(assets: assets)

        // Resume: split assets into "already hashed" (skip) and "need
        // hashing" (actual work). The cached subset still counts toward
        // progress — otherwise a resumed scan would show 0/N initially
        // and confusingly reach `total - cached` at completion.
        //
        // Staleness: an asset whose PhotoKit `modificationDate` advances
        // past the one we recorded in the cache has changed pixel bytes
        // (crop, filter, re-import). Its cached checksum is now lying to
        // us, so re-hash. Entries missing a cached modDate — legacy rows
        // from before this field existed, or tests not wiring it — are
        // treated as stale so we err toward correctness.
        let existing = try await hashStore.snapshot()
        var cached: [String: Set<Checksum>] = [:]
        var toHash: [PHAsset] = []
        toHash.reserveCapacity(assets.count)
        for asset in assets {
            guard let hit = existing[asset.localIdentifier], !hit.isEmpty else {
                toHash.append(asset)
                continue
            }
            let cachedDate = try? await hashStore.modificationDate(for: asset.localIdentifier)
            if let cachedDate, let currentDate = asset.modificationDate, cachedDate == currentDate {
                // Unchanged — trust the cache.
                cached[asset.localIdentifier] = hit
            } else {
                // modDate missing or diverged → re-hash.
                toHash.append(asset)
            }
        }

        let total = assets.count
        let resumedFrom = cached.count
        let start = Date()
        let startMsg = "[cairn.hash] full-enum start: total=\(total) resuming-cached=\(resumedFrom) to-hash=\(toHash.count)"
        hashLog.notice("\(startMsg, privacy: .public)")
        print(startMsg)   // also to stdout so `make device-run --console` shows live.

        // Seed progress with the cached count so the UI immediately
        // reflects "resumed" state rather than dropping back to 0.
        await onHashProgress(resumedFrom, total, [])

        var fresh = try await hashAssets(
            assets: toHash,
            reportProgressWithTotal: total,
            initialDone: resumedFrom
        )

        let elapsed = Date().timeIntervalSince(start)
        let perAssetMs = toHash.isEmpty ? 0 : (elapsed * 1000 / Double(toHash.count))
        let doneMsg = "[cairn.hash] full-enum done: total=\(total) resumed=\(resumedFrom) hashed=\(fresh.checksumsByID.count) elapsed=\(Int(elapsed * 1000))ms per-asset=\(String(format: "%.1f", perAssetMs))ms"
        hashLog.notice("\(doneMsg, privacy: .public)")
        print(doneMsg)

        // Seed edit-retirement anchors for ids that had no prior cache
        // entry — this enum is their first observation. First-write-
        // wins inside the store; safe to call for ids that already
        // have an anchor (returns immediately). Skipping ids whose
        // prior cache row exists keeps the original anchor stable
        // across re-enumerations.
        if let editRetirement {
            for asset in toHash {
                guard existing[asset.localIdentifier]?.isEmpty ?? true,
                      let newChecksums = fresh.checksumsByID[asset.localIdentifier],
                      !newChecksums.isEmpty else { continue }
                try await editRetirement.recordFirstObserved(newChecksums, for: asset.localIdentifier)
            }
        }

        // Fold the "resumed" cache into the fresh batch's checksum map
        // so the caller gets the full picture. Defer counts stay as
        // computed — cached assets aren't deferred, they're already done.
        fresh.checksumsByID.merge(cached) { new, _ in new }
        return fresh
    }

    /// Bulk-record metadata for a list of PHAssets (full enumeration
    /// path). Same as `recordObservedMetadata(ids:)` but skips the
    /// PhotoKit fetch — we already have the assets in hand.
    private func recordFullEnumerationMetadata(assets: [PHAsset]) async throws {
        guard let metadataStore, !assets.isEmpty else { return }
        let now = clock()
        var entries: [LocalAssetMetadata] = []
        entries.reserveCapacity(assets.count)
        for asset in assets {
            let resources = PHAssetResource.assetResources(for: asset)
            let primary = PhotoKitPhotoEnumerator.selectPrimaryResource(from: resources)
            let size = (primary?.value(forKey: "fileSize") as? NSNumber)?.int64Value
            entries.append(LocalAssetMetadata(
                localIdentifier: asset.localIdentifier,
                originalFileName: primary?.originalFilename,
                creationDate: asset.creationDate,
                modificationDate: asset.modificationDate,
                fileSize: size,
                observedAt: now
            ))
        }
        try await metadataStore.record(entries)
    }

    /// Result of a combined metadata-record + stale-filter pass:
    /// metadata for every id has been recorded, and `staleUpdates`
    /// contains the subset of `updatedIds` whose modificationDate
    /// actually advanced past the cached one (i.e. real edits, not
    /// metadata-only PhotoKit churn).
    private struct ObservationResult {
        let staleUpdates: Set<String>
    }

    /// Single-pass observer for incremental insert/update events:
    ///   1. Fetch PHAssets for `insertedIds ∪ updatedIds` once.
    ///   2. Record metadata (filename, creationDate, size) for each
    ///      so we have correlation data even if hashing later fails.
    ///   3. Compare `modificationDate` against the cache to skip
    ///      no-op update events (PhotoKit fires for favorites, hidden,
    ///      album moves — none change pixel bytes).
    /// Reading PHAsset properties + PHAssetResource is fast; we want
    /// to do it once, not three times across separate helpers.
    private func observeAndFilter(
        insertedIds: Set<String>,
        updatedIds: Set<String>
    ) async throws -> ObservationResult {
        let allIds = insertedIds.union(updatedIds)
        guard !allIds.isEmpty else { return ObservationResult(staleUpdates: []) }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: Array(allIds), options: nil)
        let now = clock()
        var entries: [LocalAssetMetadata] = []
        var currentDates: [String: Date] = [:]
        entries.reserveCapacity(fetch.count)
        currentDates.reserveCapacity(fetch.count)
        fetch.enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            let primary = PhotoKitPhotoEnumerator.selectPrimaryResource(from: resources)
            let size = (primary?.value(forKey: "fileSize") as? NSNumber)?.int64Value
            entries.append(LocalAssetMetadata(
                localIdentifier: asset.localIdentifier,
                originalFileName: primary?.originalFilename,
                creationDate: asset.creationDate,
                modificationDate: asset.modificationDate,
                fileSize: size,
                observedAt: now
            ))
            if let date = asset.modificationDate {
                currentDates[asset.localIdentifier] = date
            }
        }
        if let metadataStore, !entries.isEmpty {
            try await metadataStore.record(entries)
        }
        // Stale-filter just the update set. Inserts always need hashing;
        // updates only when modDate actually advanced.
        var stale: Set<String> = []
        stale.reserveCapacity(updatedIds.count)
        for id in updatedIds {
            let cachedDate = try? await hashStore.modificationDate(for: id)
            let currentDate = currentDates[id]
            if let cachedDate, let currentDate, cachedDate == currentDate {
                continue
            }
            stale.insert(id)
        }
        return ObservationResult(staleUpdates: stale)
    }


    /// Hash specific assets by local identifier. Identifiers PhotoKit
    /// no longer resolves (asset was deleted between detection and
    /// hashing) silently drop out of the result.
    private func hashAssets(ids: Set<String>) async throws -> HashBatchResult {
        guard !ids.isEmpty else { return HashBatchResult() }
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in assets.append(asset) }
        return try await hashAssets(assets: assets)
    }

    /// How this batch treats the soft iCloud-download limit:
    ///   - `.useSettings` honors `maxICloudBytesPerAsset`. Default for
    ///     foreground scans.
    ///   - `.unlimited` removes the soft cap entirely (the hard ceiling
    ///     still applies). Used by `BGProcessingTask` slots and the
    ///     manual "Hash now" drain — both contexts where the user has
    ///     opted into unlimited fetches.
    enum SoftLimitMode: Sendable {
        case useSettings
        case unlimited
    }

    /// Hash the given assets concurrently and persist results as they
    /// land. Pass `reportProgressWithTotal: nil` for small
    /// insert/update batches; the full-enumeration path passes the
    /// total so progress events fire.
    ///
    /// **Parallelism.** Up to `maxConcurrentHashes` assets hash
    /// simultaneously via a `TaskGroup`. `PHAssetResourceManager` is
    /// documented as thread-safe; `hashStore` is an actor serializing
    /// writes internally. Biggest win is iCloud-bound libraries
    /// (parallel network fetches saturate bandwidth); on-device
    /// libraries still see 1.5–2× speedup.
    ///
    /// **Cancellation.** Each child task calls
    /// `Task.checkCancellation()`; parent cancellation propagates via
    /// `TaskGroup`. Per-asset hashes that finished before the cancel
    /// point already persisted inline via `hashStore.set`, so resume
    /// picks up cleanly.
    ///
    /// **Progress throttling.** Callbacks fire every 25 assets or
    /// every 250ms, whichever comes first. Completion order rather
    /// than input order (the `TaskGroup` yields as tasks finish), but
    /// the counter advances monotonically regardless.

    private func hashAssets(
        assets: [PHAsset],
        softLimitMode: SoftLimitMode = .useSettings,
        reportProgressWithTotal total: Int? = nil,
        initialDone: Int = 0
    ) async throws -> HashBatchResult {
        var out = HashBatchResult()
        var done = initialDone
        var lastReportedDone = initialDone
        var lastReportedAt = Date()
        let progressEveryN = 25
        let progressEveryMs: TimeInterval = 0.25
        var pendingChecksums: Set<Checksum> = []

        // Running stats so the end-of-run summary can call out whether
        // iCloud download was the bottleneck. Per-asset slow-outlier
        // logging (threshold 500ms for "slow," 2000ms for "very slow")
        // surfaces individual problem assets to the devicectl console /
        // Console.app in real time.
        var slowCount = 0
        var verySlowCount = 0
        var totalHashMillis: Double = 0
        let slowThresholdMs: Double = 500
        let verySlowThresholdMs: Double = 2000

        // Capture thresholds as locals so the `@Sendable` task closures
        // below can reference them without touching `self`. Timeout
        // only applies in foreground mode; drain gets `nil` so
        // multi-GB downloads aren't clipped mid-fetch (see the
        // doc comment on `perAssetTimeoutSeconds`).
        let softLimit: Int64? = (softLimitMode == .unlimited) ? nil : maxICloudBytesPerAsset
        let hardCeiling: Int64? = hardCeilingBytes
        let timeout: TimeInterval? = (softLimitMode == .unlimited)
            ? nil
            : perAssetTimeoutSeconds
        let now = clock()
        // Upsert buffer: defer-queue writes are batched at the end of
        // the batch rather than per-asset, so the SwiftData actor only
        // serves one `save()` instead of N small transactions.
        var deferredUpserts: [DeferredHashEntry] = []
        // Successful re-hashes remove their previously-queued entry.
        // Batched for the same reason.
        var successfullyHashedIDs: Set<String> = []

        try await withThrowingTaskGroup(of: HashResult.self) { group in
            var iterator = assets.makeIterator()
            var inFlight = 0

            // Prime the group with up to `maxConcurrentHashes` tasks.
            // Without this, `group.next()` would deadlock waiting for
            // work we haven't scheduled yet.
            for _ in 0..<min(maxConcurrentHashes, assets.count) {
                guard let asset = iterator.next() else { break }
                group.addTask {
                    try await Self.hashOneAsset(
                        asset,
                        softLimitBytes: softLimit,
                        hardCeilingBytes: hardCeiling,
                        timeoutSeconds: timeout
                    )
                }
                inFlight += 1
            }

            while inFlight > 0 {
                guard let result = try await group.next() else { break }
                inFlight -= 1

                if let reason = result.deferReason {
                    // Log individual defer events — useful for seeing
                    // what's getting skipped. Large ones log bytes so
                    // you can tune the threshold with real data.
                    switch reason {
                    case .tooLarge(let bytes):
                        out.deferredLarge += 1
                        out.deferredLargeBytes += bytes
                        deferredUpserts.append(DeferredHashEntry(
                            localIdentifier: result.assetID,
                            reason: .tooLarge,
                            sizeBytes: bytes,
                            firstDeferredAt: now
                        ))
                        let msg = "[cairn.hash] deferred-large: id=\(result.assetID.prefix(12))… would-download=\(Self.formatBytes(bytes))"
                        hashLog.notice("\(msg, privacy: .public)")
                        print(msg)
                    case .timedOut:
                        out.deferredTimeout += 1
                        deferredUpserts.append(DeferredHashEntry(
                            localIdentifier: result.assetID,
                            reason: .timedOut,
                            sizeBytes: nil,
                            firstDeferredAt: now
                        ))
                        let msg = "[cairn.hash] deferred-timeout: id=\(result.assetID.prefix(12))… after=\(Int(result.elapsedMs))ms"
                        hashLog.notice("\(msg, privacy: .public)")
                        print(msg)
                    case .noHashableResources:
                        out.deferredEmpty += 1
                        deferredUpserts.append(DeferredHashEntry(
                            localIdentifier: result.assetID,
                            reason: .noHashableResources,
                            sizeBytes: nil,
                            firstDeferredAt: now
                        ))
                    case .aboveHardCeiling(let bytes):
                        // Not counted in the `deferred*` buckets because
                        // it's not deferred — it's out-of-scope.
                        // Surfaced via the log so on-device testers see
                        // what was permanently skipped.
                        out.aboveHardCeiling += 1
                        out.aboveHardCeilingBytes += bytes
                        let msg = "[cairn.hash] above-hard-ceiling: id=\(result.assetID.prefix(12))… would-download=\(Self.formatBytes(bytes)) (out-of-scope)"
                        hashLog.notice("\(msg, privacy: .public)")
                        print(msg)
                    }
                } else if !result.checksums.isEmpty {
                    out.checksumsByID[result.assetID] = result.checksums
                    successfullyHashedIDs.insert(result.assetID)
                    pendingChecksums.formUnion(result.checksums)
                    // Persist after each successful hash so a
                    // cancellation doesn't waste the work. Serialized
                    // inside the hashStore actor; the few-ms cost is
                    // dwarfed by the hash itself.
                    try? await hashStore.set(
                        result.checksums,
                        for: result.assetID,
                        modificationDate: result.modificationDate
                    )
                    // Also drop the deferred-queue entry per-asset.
                    // The end-of-batch bulk remove is too late if the
                    // task gets cancelled mid-drain — large iCloud
                    // downloads are exactly when this happens.
                    if let deferredStore {
                        try? await deferredStore.remove([result.assetID])
                    }
                }

                totalHashMillis += result.elapsedMs
                if result.elapsedMs >= slowThresholdMs { slowCount += 1 }
                if result.elapsedMs >= verySlowThresholdMs {
                    verySlowCount += 1
                    let msg = "[cairn.hash] slow-asset: id=\(result.assetID.prefix(12))… took=\(Int(result.elapsedMs))ms resources=\(result.resourceCount) — probably iCloud fetch"
                    hashLog.notice("\(msg, privacy: .public)")
                    print(msg)
                }

                done += 1
                if let total {
                    let ticks = done - lastReportedDone
                    let elapsed = Date().timeIntervalSince(lastReportedAt)
                    if ticks >= progressEveryN || elapsed >= progressEveryMs || done == total {
                        let batch = pendingChecksums
                        pendingChecksums = []
                        await onHashProgress(done, total, batch)
                        lastReportedDone = done
                        lastReportedAt = Date()
                    }
                }

                // Feed the next asset into the group to keep
                // `maxConcurrentHashes` tasks in flight.
                if let next = iterator.next() {
                    group.addTask {
                        try await Self.hashOneAsset(
                            next,
                            softLimitBytes: softLimit,
                            hardCeilingBytes: hardCeiling,
                            timeoutSeconds: timeout
                        )
                    }
                    inFlight += 1
                }
            }
        }

        // Commit defer-queue writes in one batched pass per batch —
        // cheaper than per-asset saves and keeps the `DeferredHashStore`
        // transaction surface small. Successful re-hashes drop any
        // prior queue entry; defer outcomes upsert (first-write-wins
        // on `firstDeferredAt`). Hard-ceiling outcomes are intentionally
        // absent — they're out-of-scope, not deferred.
        if let deferredStore {
            if !deferredUpserts.isEmpty {
                try? await deferredStore.upsert(deferredUpserts)
            }
            if !successfullyHashedIDs.isEmpty {
                try? await deferredStore.remove(successfullyHashedIDs)
            }
        }

        // Summary — lets users confirm the iCloud hypothesis without
        // reading every per-asset line. "200 of 250 were slow" →
        // library is heavily iCloud-optimized, pipeline is network-bound.
        if !assets.isEmpty {
            let mean = totalHashMillis / Double(assets.count)
            var deferParts: [String] = []
            if out.deferredLarge > 0 {
                deferParts.append("deferred-large=\(out.deferredLarge)(\(Self.formatBytes(out.deferredLargeBytes)))")
            }
            if out.deferredTimeout > 0 { deferParts.append("deferred-timeout=\(out.deferredTimeout)") }
            if out.deferredEmpty > 0 { deferParts.append("deferred-empty=\(out.deferredEmpty)") }
            if out.aboveHardCeiling > 0 {
                deferParts.append("above-hard-ceiling=\(out.aboveHardCeiling)(\(Self.formatBytes(out.aboveHardCeilingBytes)))")
            }
            let deferSuffix = deferParts.isEmpty ? "" : " " + deferParts.joined(separator: " ")
            let summary = "[cairn.hash] batch summary: n=\(assets.count) concurrency=\(maxConcurrentHashes) mean-per-asset=\(String(format: "%.1f", mean))ms slow(>\(Int(slowThresholdMs))ms)=\(slowCount) very-slow(>\(Int(verySlowThresholdMs))ms)=\(verySlowCount)\(deferSuffix)"
            hashLog.notice("\(summary, privacy: .public)")
            print(summary)
        }

        return out
    }

    /// Shim that keeps the log-line format consistent with the rest
    /// of the app. A `Self.formatBytes` call site avoids touching
    /// every `"deferred-large=...(\(Self.formatBytes(...)))"` site in
    /// this file if the underlying helper ever moves.
    private static func formatBytes(_ bytes: Int64) -> String {
        CairnTimeHelpers.formatBytesCompact(bytes)
    }

    /// Hash one asset's resources with a size pre-check and optional
    /// timeout. Returns either a successful hash, a defer decision
    /// (too-large iCloud fetch / timeout / no hashable resources /
    /// above hard ceiling), or propagates `CancellationError` when
    /// the surrounding Task was cancelled.
    ///
    /// Declared `static` so the enclosing `TaskGroup` can call it
    /// without capturing `self`. PhotoKit's hashing primitives are
    /// already static, `HashResult` is `Sendable`, concurrency stays
    /// boring.
    private static func hashOneAsset(
        _ asset: PHAsset,
        softLimitBytes: Int64?,
        hardCeilingBytes: Int64?,
        timeoutSeconds: TimeInterval?
    ) async throws -> HashResult {
        try Task.checkCancellation()
        let start = Date()
        let resources = PhotoKitPhotoEnumerator.resourcesToHash(for: asset)

        guard !resources.isEmpty else {
            return HashResult(
                assetID: asset.localIdentifier,
                checksums: [],
                modificationDate: asset.modificationDate,
                elapsedMs: 0,
                resourceCount: 0,
                deferReason: .noHashableResources
            )
        }

        // Size pre-check. Sum bytes of any resource that would require
        // an iCloud fetch (not already locally available). Hard ceiling
        // wins over soft limit — if we're over the permanent-skip
        // bound, short-circuit with `.aboveHardCeiling` so the caller
        // knows not to queue the asset.
        var downloadBytes: Int64 = 0
        for resource in resources {
            let local = PhotoKitPhotoEnumerator.resourceIsLocallyAvailable(resource) ?? false
            if !local, let bytes = PhotoKitPhotoEnumerator.resourceFileSize(resource) {
                downloadBytes += bytes
            }
        }
        if let hardCeilingBytes, downloadBytes > hardCeilingBytes {
            return HashResult(
                assetID: asset.localIdentifier,
                checksums: [],
                modificationDate: asset.modificationDate,
                elapsedMs: Date().timeIntervalSince(start) * 1000,
                resourceCount: resources.count,
                deferReason: .aboveHardCeiling(bytes: downloadBytes)
            )
        }
        if let softLimitBytes, downloadBytes > softLimitBytes {
            return HashResult(
                assetID: asset.localIdentifier,
                checksums: [],
                modificationDate: asset.modificationDate,
                elapsedMs: Date().timeIntervalSince(start) * 1000,
                resourceCount: resources.count,
                deferReason: .tooLarge(bytes: downloadBytes)
            )
        }

        // Race the hashing against the per-asset timeout — but only
        // when a timeout was configured (foreground mode). In
        // `.unlimited` mode we hash directly with no timer, so big
        // iCloud videos aren't clipped mid-download. Cancellation
        // still propagates via parent-task cancellation regardless,
        // so iOS BG expiration / user navigation-away still work.
        var checksums: Set<Checksum> = []
        var timedOut = false
        for resource in resources {
            do {
                let checksum: Checksum
                if let timeoutSeconds {
                    checksum = try await withThrowingTaskGroup(of: Checksum.self) { group in
                        group.addTask {
                            try await PhotoKitPhotoEnumerator.hash(
                                resource: resource,
                                assetLocalIdentifier: asset.localIdentifier
                            )
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                            throw TimeoutSentinel()
                        }
                        defer { group.cancelAll() }
                        guard let first = try await group.next() else {
                            throw TimeoutSentinel()
                        }
                        return first
                    }
                } else {
                    // No timeout. Hash directly — caller has opted
                    // into "fetch as long as needed" (drain mode).
                    checksum = try await PhotoKitPhotoEnumerator.hash(
                        resource: resource,
                        assetLocalIdentifier: asset.localIdentifier
                    )
                }
                checksums.insert(checksum)
            } catch is TimeoutSentinel {
                timedOut = true
                break
            } catch is CancellationError {
                // Propagate up so the outer TaskGroup's cancellation
                // propagation works as expected.
                throw CancellationError()
            } catch {
                // Tolerate a single resource's failure — a motion video
                // can be missing while the still hashes fine, and the
                // next update event re-surfaces the missing one.
                continue
            }
        }

        let elapsed = Date().timeIntervalSince(start) * 1000
        if timedOut {
            return HashResult(
                assetID: asset.localIdentifier,
                checksums: [],
                modificationDate: asset.modificationDate,
                elapsedMs: elapsed,
                resourceCount: resources.count,
                deferReason: .timedOut
            )
        }
        return HashResult(
            assetID: asset.localIdentifier,
            checksums: checksums,
            modificationDate: asset.modificationDate,
            elapsedMs: elapsed,
            resourceCount: resources.count,
            deferReason: nil
        )
    }

    /// "Timeout won the race" sentinel thrown inside the per-asset
    /// race. Not exposed outside the reconciler — callers read the
    /// actionable "no checksums + `deferReason == .timedOut`" shape
    /// from `HashResult` instead.
    private struct TimeoutSentinel: Swift.Error {}

    /// Why a per-asset hash didn't produce checksums. Aggregated in
    /// the batch summary so `make device-run` output shows the
    /// breakdown (`deferred-large=312 timed-out=8`).
    enum DeferReason: Sendable {
        /// Expected iCloud download exceeded `maxICloudBytesPerAsset`.
        /// Persists to `DeferredHashStore`; the next foreground scan
        /// retries it if it fits the current soft limit, and the BG
        /// drain takes it regardless.
        case tooLarge(bytes: Int64)
        /// One of the resource fetches exceeded `perAssetTimeoutSeconds`.
        /// Usually a transient network stall. Persists to
        /// `DeferredHashStore` for next-slot retry.
        case timedOut
        /// PHAsset had no resources we knew how to hash — adjustment-
        /// only stubs, post-edit artifacts. Rare; persisted so the
        /// count surfaces in UI even though retry rarely helps.
        case noHashableResources
        /// iCloud download exceeds the user's hard ceiling. Out of
        /// scope — **not** persisted to the defer queue, no checksum,
        /// no `EverSeen` row.
        case aboveHardCeiling(bytes: Int64)
    }

    /// One asset's hashing result. Declared at type scope (rather than
    /// nested in `hashAssets`) so the `static` `hashOneAsset` can
    /// return it without reaching across function-local scope.
    /// Success shape: `deferReason == nil` and non-empty `checksums`.
    /// Anything else is a defer of some flavor.
    private struct HashResult: Sendable {
        let assetID: String
        let checksums: Set<Checksum>
        let modificationDate: Date?
        let elapsedMs: Double
        let resourceCount: Int
        let deferReason: DeferReason?
    }

    /// Aggregated output from a single `hashAssets` batch — successful
    /// checksums (the caller populates stores with these) plus
    /// per-reason defer counts (surfaced in the public `Result` and in
    /// the journal). Internal so the public `Result` can accumulate
    /// across multiple batches (e.g. insert + update + drain in the
    /// incremental path).
    private struct HashBatchResult: Sendable {
        var checksumsByID: [String: Set<Checksum>] = [:]
        var deferredLarge: Int = 0
        var deferredLargeBytes: Int64 = 0
        var deferredTimeout: Int = 0
        var deferredEmpty: Int = 0
        var aboveHardCeiling: Int = 0
        var aboveHardCeilingBytes: Int64 = 0
    }

    // MARK: - Orphan cleanup

    /// Safety net for soft-deletes PhotoKit reported through a channel
    /// other than `deletedLocalIdentifiers` (observed: "updated"
    /// events as assets move into Recently Deleted). Iterates the live
    /// user library, subtracts those ids from `LocalHashStore`'s
    /// keys, and treats any leftover cached id as a missed delete —
    /// union into `ConfirmedDeletedStore` (starting the quarantine
    /// clock) and purge the cache.
    ///
    /// `alreadyHandledDeletedIds` skips what the explicit delete path
    /// already processed this pass. `protectedIds` shields ids we
    /// just hashed on the insert/update paths from a race where the
    /// `PHAsset.fetchAssets` snapshot predates our `hashStore.set`
    /// writes.
    ///
    /// Cheap: `PHAsset.fetchAssets` is an index query and the
    /// subtract is a hash-set op. Runs at the end of every
    /// incremental scan.
    /// Find PHAssets visible in the user library that are neither in
    /// `LocalHashStore` nor in `DeferredHashStore` — i.e. invisible to
    /// cairn's normal pipeline. Returns the localIdentifiers so the
    /// caller can fold them into `insertedIds` and let the standard
    /// hash + metadata + ever-seen flow handle them.
    ///
    /// Cheap when the gap is empty: one `PHAsset.fetchAssets` call (which
    /// the orphan sweep also does — could share if we ever notice the
    /// duplicate cost) plus two store snapshots (`allLocalIdentifiers`,
    /// `deferredStore.snapshot()`), all set-membership-only.
    private func discoverUntrackedAssets() async throws -> Set<String> {
        let opts = PHFetchOptions()
        opts.includeHiddenAssets = false
        opts.includeAssetSourceTypes = [.typeUserLibrary]
        let fetch = PHAsset.fetchAssets(with: opts)
        var liveIds: Set<String> = []
        liveIds.reserveCapacity(fetch.count)
        fetch.enumerateObjects { asset, _, _ in liveIds.insert(asset.localIdentifier) }

        let cacheIds = try await hashStore.allLocalIdentifiers()
        var deferredIds: Set<String> = []
        if let deferredStore {
            let snapshot = try await deferredStore.snapshot()
            deferredIds.reserveCapacity(snapshot.count)
            for entry in snapshot {
                deferredIds.insert(entry.localIdentifier)
            }
        }

        return Self.untrackedFromLibrary(
            liveIds: liveIds,
            cacheIds: cacheIds,
            deferredIds: deferredIds
        )
    }

    private func reconcileCacheAgainstLibrary(
        alreadyHandledDeletedIds: Set<String>,
        protectedIds: Set<String>,
        now: Date
    ) async throws -> (checksums: Set<Checksum>, orphanIds: Set<String>, sourceIdByChecksum: [Checksum: String]) {
        // Include hidden assets so Live Photo motion videos (which
        // live in `hidden` visibility) don't get flagged as orphans.
        let opts = PHFetchOptions()
        opts.includeHiddenAssets = true
        opts.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared]
        let fetch = PHAsset.fetchAssets(with: opts)
        var liveIds: Set<String> = []
        liveIds.reserveCapacity(fetch.count)
        fetch.enumerateObjects { asset, _, _ in liveIds.insert(asset.localIdentifier) }

        // Use the keys-only fetch — we don't need the actual checksums
        // here, just set-membership. On 7k+ libraries this saves a
        // materially expensive load.
        let cacheIds = try await hashStore.allLocalIdentifiers()
        // Candidate orphans = cache ids that:
        //  - aren't in the live library (so really gone), AND
        //  - aren't already accounted for by the explicit delete
        //    path earlier this pass, AND
        //  - aren't in `protectedIds` (ids this pass's insert/update
        //    handlers just touched). The protection prevents a race
        //    where PhotoKit's index-query snapshot predates our
        //    `hashStore.set(...)` writes for those ids, making them
        //    appear to be cache-only orphans even though they just
        //    finished hashing.
        let orphans = cacheIds
            .subtracting(liveIds)
            .subtracting(alreadyHandledDeletedIds)
            .subtracting(protectedIds)

        guard !orphans.isEmpty else {
            return ([], [], [:])
        }

        // Fetch checksums for just the orphan ids — much smaller set
        // than the full library. Capture the per-id mapping while we're
        // here so the caller can pass it through to the UI grouping
        // path; reconstructing it post-purge would require re-querying
        // an already-cleared cache.
        var recoveredChecksums: Set<Checksum> = []
        var sourceIdByChecksum: [Checksum: String] = [:]
        for id in orphans {
            let cks = try await hashStore.checksums(for: id)
            recoveredChecksums.formUnion(cks)
            for c in cks { sourceIdByChecksum[c] = id }
        }

        let sample = orphans.prefix(3).map { String($0.prefix(12)) + "…" }.joined(separator: ", ")
        let msg = "[cairn.recon] orphan cleanup: \(orphans.count) cached id(s) no longer in library → \(recoveredChecksums.count) checksum(s) confirmed-deleted via safety net (sample: \(sample))"
        Self.reconLog.notice("\(msg, privacy: .public)")
        print(msg)

        // Purge orphan ids from the cache. The confirmed-deleted union
        // is the caller's responsibility — it filters against the
        // post-purge cache so checksums still present under another id
        // (duplicate SHA1) aren't wrongly stamped.
        try await hashStore.removeAll(for: orphans)
        return (recoveredChecksums, orphans, sourceIdByChecksum)
    }

    // MARK: - Diagnostic logging

    /// Reconciliation-pipeline logger, distinct from `hashLog` so
    /// Console.app filters to just the recon path without drowning in
    /// per-asset hash lines. Predicate:
    /// `subsystem == "app.cairn.ios" AND category == "recon"`.
    private static let reconLog = Logger(subsystem: "app.cairn.ios", category: "recon")

    /// Dumps the event-bucket breakdown at the top of each
    /// `runIncremental` call so "did PhotoKit actually report my
    /// delete?" is answerable from the device console without a
    /// rebuild. Samples the first 3 ids of each bucket (truncated to
    /// 12 chars) for cross-reference.
    private static func logIncrementalHeader(
        events: Int,
        inserted: Set<String>,
        updated: Set<String>,
        deleted: Set<String>
    ) {
        func sample(_ ids: Set<String>) -> String {
            guard !ids.isEmpty else { return "" }
            return ids.prefix(3)
                .map { String($0.prefix(12)) + "…" }
                .joined(separator: ", ")
        }
        var parts = [
            "events=\(events)",
            "inserted=\(inserted.count)",
            "updated=\(updated.count)",
            "deleted=\(deleted.count)",
        ]
        if !inserted.isEmpty { parts.append("ins-sample=[\(sample(inserted))]") }
        if !updated.isEmpty  { parts.append("upd-sample=[\(sample(updated))]") }
        if !deleted.isEmpty  { parts.append("del-sample=[\(sample(deleted))]") }
        let msg = "[cairn.recon] incremental: " + parts.joined(separator: " ")
        reconLog.notice("\(msg, privacy: .public)")
        print(msg)
    }

    // MARK: - Token archiving

    /// Encode a `PHPersistentChangeToken` as bytes for
    /// `PersistentChangeTokenStore`. `PHPersistentChangeToken`
    /// conforms to `NSSecureCoding`, which is the documented path for
    /// durable storage; `requiringSecureCoding: true` enforces typed
    /// unarchiving on the other end.
    static func archiveToken(_ token: PHPersistentChangeToken) -> Data {
        do {
            return try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        } catch {
            // Should never fail for PhotoKit's own types, but we'd
            // rather lose a token and force full enumeration than
            // crash. Empty data fails `unarchiveToken` → full-enum
            // path on next scan.
            return Data()
        }
    }

    /// Inverse of `archiveToken`. Returns `nil` on empty input or any
    /// unarchive failure, which the caller treats as "no saved token"
    /// and falls through to full enumeration.
    static func unarchiveToken(_ data: Data) -> PHPersistentChangeToken? {
        guard !data.isEmpty else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: PHPersistentChangeToken.self,
            from: data
        )
    }

    /// True if `error` is PhotoKit's "the change log no longer
    /// contains this token" signal. Apple doesn't document the
    /// retention window, so handle this as a normal code path
    /// (switch to full enumeration), not an exceptional one.
    static func isTokenExpired(_ error: NSError) -> Bool {
        error.domain == PHPhotosErrorDomain
            && error.code == PHPhotosError.persistentChangeTokenExpired.rawValue
    }
}

#endif
