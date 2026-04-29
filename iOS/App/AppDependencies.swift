import Foundation
import SwiftUI
import SwiftData
import Photos
import os
import CryptoKit
import CairnCore
import CairnIOSCore

private let syncLog = Logger(subsystem: "app.cairn.ios", category: "sync")

/// Bridges `PHPhotoLibraryChangeObserver` (NSObject protocol) into a
/// closure-based callback we can wire from `AppDependencies`. Holds a
/// strong reference to the observer so PhotoKit keeps delivering events;
/// nilled out on sign-out.
///
/// Hands the raw `PHChange` to the callback so the host can compute
/// inserted/deleted deltas against a tracked `PHFetchResult` — early
/// enough to record metadata before the asset disappears (the cull-
/// burst case where the user takes and deletes a photo within the
/// debounced-sync window).
private final class PhotoLibraryChangeBridge: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    let onChange: @Sendable (PHChange) -> Void
    init(onChange: @escaping @Sendable (PHChange) -> Void) { self.onChange = onChange }
    func photoLibraryDidChange(_ change: PHChange) { onChange(change) }
}

@MainActor
@Observable
final class AppDependencies {

    // MARK: - Global stores (shared across all servers)

    let secretStore: KeychainSecretStore
    let settingsStore: UserDefaultsSettingsStore
    let photos: PhotoKitPhotoEnumerator
    let globalContainer: ModelContainer
    let localHashStore: SwiftDataLocalHashStore
    let deferredHashStore: SwiftDataDeferredHashStore
    let localAssetMetadataStore: SwiftDataLocalAssetMetadataStore

    // MARK: - Per-server stores (nil until activateServer runs)

    private(set) var currentPartitionKey: ServerPartitionKey?
    /// Timestamp the *current* API key was first verified for this
    /// (URL, userId) account on this device. Read from the per-key
    /// activation map in Keychain at bootstrap and at every successful
    /// `verifyServer` call. Drives the runs/journal-tail UI filter so
    /// rotating to a new key starts a fresh-looking history (the journal
    /// file itself is intact). `.distantPast` for upgrade installs that
    /// predate per-key activation tracking — preserves their existing
    /// history. `nil` until `activateServer` has run.
    private(set) var currentKeyActivatedAt: Date?
    private(set) var serverContainer: ModelContainer?
    private(set) var everSeenStore: SwiftDataEverSeenStore?
    private(set) var exclusionStore: SwiftDataExclusionStore?
    private(set) var confirmedDeletedStore: SwiftDataConfirmedDeletedStore?
    private(set) var deletionSourceStore: SwiftDataDeletionSourceStore?
    private(set) var tokenStore: SwiftDataPersistentChangeTokenStore?
    private(set) var thumbnailStore: SwiftDataThumbnailStore?
    private(set) var editRetirementStore: SwiftDataEditRetirementStore?
    private(set) var statusSnapshotStore: SwiftDataStatusSnapshotStore?
    private(set) var journal: DeletionJournal?

    var persistentChangeReconciler: PhotoKitPersistentChangeReconciler? {
        guard let localHash = Optional(localHashStore),
              let confirmed = confirmedDeletedStore,
              let everSeen = everSeenStore,
              let tokens = tokenStore else { return nil }

        let limitMB = model.settings.iCloudDownloadLimitMB
        let bytesLimit: Int64? = limitMB > 0 ? Int64(limitMB) * 1024 * 1024 : nil
        let ceilingMB = model.settings.iCloudMaxEverBytesMB
        let ceilingBytes: Int64? = (ceilingMB.map { $0 > 0 } ?? false)
            ? Int64(ceilingMB!) * 1024 * 1024
            : nil

        let isLimitedAccess = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited
        let activeScope = model.settings.indexingScope
        return PhotoKitPersistentChangeReconciler(
            hashStore: localHash,
            confirmedDeleted: confirmed,
            everSeen: everSeen,
            tokens: tokens,
            deferredStore: deferredHashStore,
            metadataStore: localAssetMetadataStore,
            editRetirement: editRetirementStore,
            deletionSource: deletionSourceStore,
            maxAssets: Self.resolveTestingAssetCap(),
            maxICloudBytesPerAsset: bytesLimit,
            hardCeilingBytes: ceilingBytes,
            requireExplicitDeletionEvent: isLimitedAccess,
            scope: activeScope,
            onHashProgress: { [weak self] done, total, newChecksums in
                // Fetch all MainActor-isolated state in one hop.
                struct Snapshot {
                    let hashStore: SwiftDataLocalHashStore?
                    let serverSet: Set<Checksum>?
                    let deferredStore: SwiftDataDeferredHashStore?
                    let ceilingBytes: Int64?
                }
                let snap: Snapshot = await MainActor.run {
                    guard let self else {
                        return Snapshot(hashStore: nil, serverSet: nil, deferredStore: nil, ceilingBytes: nil)
                    }
                    let mb = self.model.settings.iCloudMaxEverBytesMB
                    let bytes: Int64? = (mb.map { $0 > 0 } ?? false) ? Int64(mb!) * 1024 * 1024 : nil
                    return Snapshot(
                        hashStore: self.localHashStore,
                        serverSet: self.serverChecksumSet,
                        deferredStore: self.deferredHashStore,
                        ceilingBytes: bytes
                    )
                }
                guard let hashStore = snap.hashStore else {
                    await MainActor.run { self?.model.syncProgress = .init(hashed: done, total: total) }
                    return
                }
                let indexed = (try? await hashStore.indexedCount()) ?? 0
                let batchMatched: Int = {
                    guard let serverSet = snap.serverSet else { return 0 }
                    return newChecksums.filter { serverSet.contains($0) }.count
                }()
                // Recompute deferred queue counts so the sync card's
                // "queued" line ticks down live as items get removed
                // per-asset by the drain loop. Without this the label
                // stays stale until end-of-drain.
                var queueCount = 0
                var queueAboveCeiling = 0
                var queueBytes: Int64 = 0
                if let deferredStore = snap.deferredStore {
                    let entries = (try? await deferredStore.snapshot()) ?? []
                    for entry in entries {
                        if let cb = snap.ceilingBytes, let size = entry.sizeBytes, size > cb {
                            queueAboveCeiling += 1
                        } else {
                            queueCount += 1
                            if let size = entry.sizeBytes { queueBytes += size }
                        }
                    }
                }
                await MainActor.run {
                    guard let self else { return }
                    self.model.syncProgress = .init(hashed: done, total: total)
                    let prevMatched = self.model.library.matched
                    self.model.library = self.model.library
                        .with(indexed: indexed, matched: prevMatched + batchMatched)
                    if snap.deferredStore != nil {
                        self.model.deferredQueue = .init(
                            count: queueCount,
                            aboveCeiling: queueAboveCeiling,
                            totalKnownBytes: queueBytes
                        )
                    }
                }
            }
        )
    }

    nonisolated static let massOffloadRecentWindow: TimeInterval = 24 * 60 * 60

    static func resolveTestingAssetCap() -> Int? {
        let key = "CAIRN_ASSET_CAP"
        let ud = UserDefaults.standard
        if let raw = ProcessInfo.processInfo.environment[key], !raw.isEmpty {
            if let n = Int(raw), n > 0 {
                ud.set(n, forKey: key)
                return n
            }
            ud.removeObject(forKey: key)
            return nil
        }
        let stored = ud.integer(forKey: key)
        return stored > 0 ? stored : nil
    }

    private(set) var immichClient: ImmichClient?

    /// Foreground PhotoKit change observer. Hashes inserts immediately
    /// when cairn is open so a take→delete in the same session doesn't
    /// lose the photo's checksum (and therefore the chance to propagate
    /// the deletion to the server).
    private var photoLibraryBridge: PhotoLibraryChangeBridge?
    private var pendingForegroundSyncTask: Task<Void, Never>?

    /// Wall-clock time of the most recent `requestSync` completion.
    /// `scheduleForegroundSync` uses this to suppress sync triggers
    /// that arrive in the immediate post-sync window — those are
    /// almost always `photoLibraryDidChange` events fired by PhotoKit
    /// in response to iCloud asset downloads cairn's own hash pipeline
    /// caused, NOT genuine new user activity. Without the cooldown the
    /// observer + scheduler form a self-perpetuating loop where every
    /// sync triggers the next one.
    private var lastSyncEndedAt: Date?

    /// How long after a sync ends to ignore observer-triggered sync
    /// requests. Picked to comfortably cover the iCloud activity tail
    /// from a long sync (most events arrive within a few seconds of
    /// sync end). Real user actions — taking a photo, deleting one —
    /// produce events that show up well outside this window.
    private static let postSyncObserverCooldown: TimeInterval = 15

    /// Tracked fetch the foreground observer diffs against. Required to
    /// turn a `PHChange` into `insertedObjects` without re-enumerating
    /// the whole library — that's how we capture metadata eagerly,
    /// before the debounced-sync runs (which is too late if the user
    /// deletes the asset in the meantime).
    private var trackedLibraryFetch: PHFetchResult<PHAsset>?

    /// Server-side checksum set, populated early in the sync so the
    /// hash-progress callback can compute a running "matched" count.
    /// Cleared at the start of each reconciliation and filled once
    /// the server fetch completes.
    private var serverChecksumSet: Set<Checksum>?

    private(set) var thumbnailLoader: ImmichThumbnailLoader?

    // MARK: - Model wired into the UI

    let model: CairnAppModel

    // MARK: - Init

    init() {
        let secretStore = KeychainSecretStore()
        let settingsStore = UserDefaultsSettingsStore()
        let photos = PhotoKitPhotoEnumerator()

        let container: ModelContainer = {
            if let disk = try? CairnSwiftDataContainer.makeGlobal() {
                return disk
            }
            do {
                return try CairnSwiftDataContainer.makeGlobal(inMemory: true)
            } catch {
                fatalError("cairn can't initialize a SwiftData container on disk OR in memory — \(error). The app requires at least one of these to function. If this keeps happening, check Settings → Storage for free space and reinstall cairn.")
            }
        }()

        self.secretStore = secretStore
        self.settingsStore = settingsStore
        self.photos = photos
        self.globalContainer = container
        self.localHashStore = SwiftDataLocalHashStore(container: container)
        self.deferredHashStore = SwiftDataDeferredHashStore(container: container)
        self.localAssetMetadataStore = SwiftDataLocalAssetMetadataStore(container: container)

        let actions = AppDependencies.makePreviewActions()
        self.model = CairnAppModel(
            needsOnboarding: false,
            actions: actions
        )
        model.isBootstrapping = true

        rewireActions()
    }

    // MARK: - Server activation

    func activateServer(url: URL, apiKey: String, userId: String? = nil) throws {
        let key = ServerPartitionKey(from: url, userId: userId)

        // One-time migration: if a previous build left a URL-only
        // partition directory at this URL, rename it in place to the
        // new (URL, userId) shape. Only triggers when userId is
        // present (otherwise the legacy dirname IS the new dirname);
        // best-effort — if rename fails (file in use, permission
        // issue) we leave the legacy dir alone and create a fresh
        // one, accepting state loss but avoiding a hard failure.
        if userId != nil {
            Self.migrateLegacyServerPartitionIfNeeded(url: url, userId: userId)
        }

        let containerURL = Self.serverContainerURL(for: key)
        let container: ModelContainer = {
            if let disk = try? CairnSwiftDataContainer.makePerServer(url: containerURL) {
                return disk
            }
            do {
                return try CairnSwiftDataContainer.makePerServer(url: containerURL, inMemory: true)
            } catch {
                fatalError("cairn can't initialize per-server SwiftData container — \(error)")
            }
        }()

        self.currentPartitionKey = key
        self.serverContainer = container
        self.everSeenStore = SwiftDataEverSeenStore(container: container)
        self.exclusionStore = SwiftDataExclusionStore(container: container)
        self.confirmedDeletedStore = SwiftDataConfirmedDeletedStore(container: container)
        self.deletionSourceStore = SwiftDataDeletionSourceStore(container: container)
        self.tokenStore = SwiftDataPersistentChangeTokenStore(container: container)
        self.editRetirementStore = SwiftDataEditRetirementStore(container: container)
        self.statusSnapshotStore = SwiftDataStatusSnapshotStore(container: container)
        let thumbStore = SwiftDataThumbnailStore(container: container)
        self.thumbnailStore = thumbStore

        let journalURL = Self.serverJournalURL(for: key)
        self.journal = DeletionJournal(path: journalURL)

        self.immichClient = ImmichClient(baseURL: url, apiKey: apiKey)
        self.thumbnailLoader = ImmichThumbnailLoader(
            baseURL: url,
            apiKey: apiKey,
            onFetched: { assetId, data in
                try? await thumbStore.saveThumbnail(assetId: assetId, data: data)
            }
        )
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-CAIRN_SCREENSHOT_MODE") {
            AppDependencies.seedFromFixtures(into: model)
            // Without this, CairnAppRoot's loading-screen gate stays on
            // and the main tab bar never renders — every UI test that
            // calls `waitForMainTabs` then times out at 15s and fails.
            // The non-fixture branches below all clear the flag before
            // returning; the fixture branch must too.
            model.isBootstrapping = false
            return
        }
        #endif


        var url = try? secretStore.serverURL()
        var apiKey = try? secretStore.apiKey()
        #if DEBUG
        if url == nil || apiKey == nil {
            let ud = UserDefaults.standard
            let env = ProcessInfo.processInfo.environment
            if let seedURL = (env["CAIRN_DEV_SEED_URL"] ?? ud.string(forKey: "CAIRN_DEV_SEED_URL")).flatMap(URL.init(string:)),
               let seedKey = env["CAIRN_DEV_SEED_KEY"] ?? ud.string(forKey: "CAIRN_DEV_SEED_KEY"),
               !seedKey.isEmpty {
                syncLog.info("[cairn.boot] using seed credentials (Keychain unavailable or empty)")
                url = seedURL
                apiKey = seedKey
                try? secretStore.setServerURL(seedURL)
                try? secretStore.setAPIKey(seedKey)
            }
        }
        #endif
        guard let url, let apiKey else {
            model.needsOnboarding = true
            model.isBootstrapping = false
            return
        }

        Self.migrateFromLegacyIfNeeded(serverURL: url)
        // Per-user partitioning: prefer the cached userId from a
        // previous successful verify. nil falls back to URL-only
        // partitioning (matches pre-migration behavior). The
        // opportunistic-fetch path runs lazily on the next sync via
        // `refreshUserIdentityIfNeeded` — bootstrap doesn't block on
        // network reachability.
        let cachedUserId = try? secretStore.userId()
        do {
            try activateServer(url: url, apiKey: apiKey, userId: cachedUserId)
        } catch {
            // SwiftData container creation failed and the in-memory
            // fallback in `activateServer` already trapped, OR the
            // function itself doesn't currently throw (the `try?` was
            // legacy). Either way, log so a future failure surfaces
            // somewhere, and fall back to onboarding.
            syncLog.error("[cairn.boot] activateServer failed: \(String(describing: error), privacy: .public)")
            model.needsOnboarding = true
            model.isBootstrapping = false
            return
        }

        // Per-key activation timestamp — drives the runs/journal-tail
        // filter so rotating to a new API key (still same Immich user)
        // gives a fresh-looking history. Bootstrap path: if this key's
        // fingerprint isn't in the map, seed with `.distantPast` so
        // existing users upgrading to per-key activation tracking
        // don't lose their visible history. The verifyServer path
        // seeds with `now` for genuinely-new keys.
        let bootFingerprint = Self.apiKeyFingerprint(apiKey)
        self.currentKeyActivatedAt = Self.upsertKeyActivation(
            in: secretStore,
            fingerprint: bootFingerprint,
            seedAt: .distantPast
        )

        #if DEBUG
        if ProcessInfo.processInfo.environment["CAIRN_RESET"] == "1" {
            // Bootstrap-time debug reset. Use the same aggregated-
            // failure pattern so a Keychain or SwiftData hiccup
            // surfaces in the log instead of being silently dropped.
            let lh = self.localHashStore
            let tk = self.tokenStore
            let eh = self.everSeenStore
            let cd = self.confirmedDeletedStore
            let ds = self.deletionSourceStore
            let er = self.editRetirementStore
            let ss = self.statusSnapshotStore
            var ops: [(label: String, body: @Sendable () async throws -> Void)] = [
                ("local hash cache", { try await lh.clear() }),
            ]
            if let tk { ops.append(("change-token store", { try await tk.clear() })) }
            if let eh { ops.append(("ever-seen store", { try await eh.clear() })) }
            if let cd { ops.append(("confirmed-deleted store", { try await cd.clear() })) }
            if let ds { ops.append(("deletion-source store", { try await ds.clear() })) }
            if let er { ops.append(("edit-retirement store", { try await er.clear() })) }
            if let ss { ops.append(("status snapshot store", { try await ss.clear() })) }
            let failures = await Self.aggregateClears(ops)
            if !failures.isEmpty {
                let detail = failures.map { "\($0.label): \(Self.describeSyncError($0.error))" }.joined(separator: "; ")
                syncLog.error("[cairn.reset.debug] partial failure: \(detail, privacy: .public)")
            }
        }
        #endif

        model.needsOnboarding = false
        model.serverHost = url.host() ?? url.absoluteString
        model.serverURL = url
        model.apiKey = apiKey
        model.apiKeyMasked = AppDependencies.mask(apiKey)
        model.settings = (try? await settingsStore.load()) ?? .defaults

        if let client = immichClient {
            let start = Date()
            do {
                let pong = try await client.ping()
                let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
                syncLog.info("[cairn.boot] server healthy: ping=\(pong), \(latencyMs)ms")
                model.connectionStatus = .healthy(latencyMs: latencyMs)
                model.degraded = .none
            } catch {
                syncLog.info("[cairn.boot] ping failed: \(error)")
                if let degraded = Self.degradedState(for: error) {
                    model.degraded = degraded
                    model.connectionStatus = degraded == .authStale ? .authStale : .offline
                }
            }
            if let stats = try? await client.assetStatistics() {
                model.library = model.library.with(server: stats.total)
            }
            if let keyInfo = try? await client.apiKeyInfo() {
                let missing = ImmichClient.missingPermissions(granted: keyInfo.permissions)
                model.missingPermissions = missing
                if !missing.isEmpty {
                    syncLog.info("[cairn.boot] missing permissions: \(missing.joined(separator: ", "))")
                }
            }
            // Opportunistic identity refresh for legacy installs. If
            // we activated with `userId: nil` (cache empty), fetch
            // identity now that we have a working client. Persist;
            // user-visible re-activation happens on next launch (we
            // don't swap containers underneath an active sync).
            if cachedUserId == nil, let identity = try? await client.usersMe() {
                try? secretStore.setUserIdentity(id: identity.id, email: identity.email)
                syncLog.notice("[cairn.boot] cached user identity: \(identity.email, privacy: .public) (\(identity.id, privacy: .public)). New partition takes effect on next launch.")
            }
        }

        await refreshExcludedChecksums()
        await refreshQuarantineCount()

        let tokenExists = (try? await tokenStore?.load()) != nil
        model.hasCompletedInitialScan = tokenExists

        await refreshLibrarySizeStats()

        // Restore last-known status counts so Status doesn't render
        // blank until the next sync completes. Cosmetic only — a load
        // failure leaves the model at defaults rather than aborting
        // bootstrap. The next `performLiveReconciliation` will overwrite
        // these with fresh values.
        //
        // `try? await store?.load()` flattens both error and store-nil
        // into a single `StatusSnapshot??`; collapse to `StatusSnapshot?`
        // before the conditional bind.
        let restoredSnapshot: StatusSnapshot? = await {
            guard let store = statusSnapshotStore else { return nil }
            return try? await store.load()
        }()
        if let snapshot = restoredSnapshot {
            let current = model.library
            model.library = current.with(
                matched: snapshot.matchedCount,
                candidates: snapshot.deleteCandidatesCount
            )
            model.inferredOrphanCount = snapshot.inferredOrphanCount
            model.lastCheckedAt = snapshot.computedAt
            // `pendingReviewCount` lives on `model.reconciliation` so we
            // can't surface the saved count without fabricating a fake
            // `LiveReconciliation`. The Status pending-review badge
            // already falls back to `model.quarantineCount` (restored
            // separately from `ConfirmedDeletedStore`) so it's not
            // blank in practice — the saved count is recorded for
            // forensic completeness and used when the model gets
            // re-saved after user actions.
            _ = snapshot.pendingReviewCount
        }

        if let cap = Self.resolveTestingAssetCap() {
            syncLog.info("[cairn.boot] testing asset cap in effect: \(cap)")
        } else {
            syncLog.info("[cairn.boot] no asset cap — full library will be hashed")
        }

        // Buffer enough history for the user to scroll back through
        // recent activity on Status without leaving the screen. 500
        // rows ≈ months of normal use; reading them once costs the
        // same I/O as the full `readAll` we already run for runs.
        // Settings → Clear journal still exists for anyone who wants
        // the slate wiped.
        await refreshJournalTail()

        await refreshDeferredQueueSummary()
        await refreshRunsList()

        rewireActions()
        registerPhotoLibraryObserver()
        model.isBootstrapping = false
    }

    /// Register a foreground PhotoKit change observer. When the photo
    /// library changes (insert, update, delete), eagerly record metadata
    /// for the inserted assets (filename + creationDate + size) so the
    /// orphan reconciler can match them against the server even if
    /// they're deleted before cairn finishes hashing them. Then schedule
    /// a debounced incremental sync so new photos get hashed within
    /// seconds — closing the take→quickly-delete window without waiting
    /// for background refresh.
    private func registerPhotoLibraryObserver() {
        guard photoLibraryBridge == nil else { return }
        guard Self.isUsablePhotoAuth(PHPhotoLibrary.authorizationStatus(for: .readWrite)) else { return }

        // Build the tracked fetch synchronously here on MainActor.
        // `changeDetails(for:)` requires a fetch result against which
        // PHChange can compute deltas. The same options as
        // `refreshLibrarySizeStats` so observed inserts mirror what
        // reconciliation will see.
        let opts = PHFetchOptions()
        opts.includeHiddenAssets = false
        opts.includeAssetSourceTypes = [.typeUserLibrary]
        self.trackedLibraryFetch = PHAsset.fetchAssets(with: opts)

        let bridge = PhotoLibraryChangeBridge { [weak self] change in
            // PhotoKit calls this on a background queue. Hop to
            // MainActor before touching `trackedLibraryFetch` and
            // before kicking the metadata-record task off the actor.
            Task { @MainActor [weak self] in
                self?.handlePhotoLibraryChange(change)
                self?.scheduleForegroundSync()
            }
        }
        PHPhotoLibrary.shared().register(bridge)
        photoLibraryBridge = bridge
        syncLog.info("[cairn.boot] photo library observer registered")
    }

    /// Pull `insertedObjects` out of the tracked fetch and snapshot
    /// metadata for each one before the debounced sync runs. Without
    /// this hop, an asset added and then deleted within the 1.5s
    /// debounce never gets metadata recorded — and `OrphanReconciler`
    /// has nothing to match against.
    private func handlePhotoLibraryChange(_ change: PHChange) {
        guard let tracked = trackedLibraryFetch,
              let details = change.changeDetails(for: tracked) else { return }
        // Update the tracked fetch to the post-change snapshot so the
        // *next* event diffs against the right baseline.
        self.trackedLibraryFetch = details.fetchResultAfterChanges

        // Diagnostic — tells us whether the observer fired live (vs
        // cairn being suspended during the edit) and what the change
        // details report. When orphan-matching fails to surface an
        // edited-then-deleted asset, this is the first line to check:
        // if `chg=0` for an edit, the observer didn't see it and the
        // metadata pipeline falls back to scan-time (which can't fetch
        // a deleted asset).
        syncLog.notice("[cairn.observer] photoLibraryDidChange: ins=\(details.insertedObjects.count, privacy: .public) chg=\(details.changedObjects.count, privacy: .public) rm=\(details.removedObjects.count, privacy: .public)")

        // Cover both new assets AND edits-of-existing-assets. PhotoKit
        // surfaces edits as `changedObjects` (modificationDate advances,
        // bytes change). Without including them here, the observer-
        // time metadata path misses the edit-then-delete race: the
        // metadata for the about-to-be-edited id never gets refreshed,
        // and if the user deletes within the debounce window, the scan-
        // time fallback (`observeAndFilter`) can't fetch the deleted
        // asset to record metadata either, leaving OrphanReconciler with
        // nothing to match against asset_E on the server.
        let toCapture = details.insertedObjects + details.changedObjects
        guard !toCapture.isEmpty else { return }
        let now = Date()
        var entries: [LocalAssetMetadata] = []
        entries.reserveCapacity(toCapture.count)
        for asset in toCapture {
            let resources = PHAssetResource.assetResources(for: asset)
            // Primary = the same resource cairn hashes (`.fullSizePhoto`
            // for edits, `.photo` otherwise). Aligning with the hash
            // pipeline AND with Immich's own upload-resource selection
            // so the filename we record matches what Immich stores.
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
        let store = self.localAssetMetadataStore
        Task {
            // Best-effort: a write failure here is non-fatal — the
            // scan-time metadata recording in `observeAndFilter` is
            // still in place as a fallback.
            try? await store.record(entries)
        }
    }

    private func unregisterPhotoLibraryObserver() {
        guard let bridge = photoLibraryBridge else { return }
        PHPhotoLibrary.shared().unregisterChangeObserver(bridge)
        photoLibraryBridge = nil
        trackedLibraryFetch = nil
    }

    /// Debounced sync trigger from the change observer. Coalesces bursts
    /// of events (e.g. import of 50 photos firing 50 changes) into one
    /// sync run.
    ///
    /// Suppresses triggers in the post-sync cooldown window — `chg=N`
    /// events fired by PhotoKit in response to iCloud downloads our
    /// previous sync caused would otherwise immediately schedule a new
    /// sync, forming a self-perpetuating loop.
    private func scheduleForegroundSync() {
        pendingForegroundSyncTask?.cancel()
        pendingForegroundSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled, !self.model.isSyncing else { return }
            if let last = self.lastSyncEndedAt,
               Date().timeIntervalSince(last) < Self.postSyncObserverCooldown {
                syncLog.info("[cairn.observer] suppressing post-sync trigger; cooldown not expired")
                return
            }
            try? await self.model.actions.requestSync()
        }
    }

    // MARK: - Scheduled scan (called by BGAppRefreshTask)

    @discardableResult
    func runScheduledScan() async throws -> PhotoKitPersistentChangeReconciler.Result {
        guard let reconciler = persistentChangeReconciler else {
            throw CancellationError()
        }
        return try await reconciler.runDeletionScan()
    }

    @discardableResult
    func runBackgroundDrain() async throws -> (
        scan: PhotoKitPersistentChangeReconciler.Result,
        drain: PhotoKitPersistentChangeReconciler.Result
    ) {
        guard let reconciler = persistentChangeReconciler else {
            throw CancellationError()
        }
        let scan = try await reconciler.runDeletionScan()
        let drain = try await reconciler.drainDeferred()
        return (scan, drain)
    }

    /// Backfill `LocalAssetMetadataStore` for cached ids that are still
    /// alive in PhotoKit but missing from the metadata store. The
    /// observer-time eager handler only captures events while cairn is
    /// alive — older photos and observer-suspended-edits leave gaps.
    /// Without this pass, OrphanReconciler can't match the affected
    /// assets when they later get edited+deleted fast.
    ///
    /// Idempotent: only writes for ids that don't already have a
    /// metadata entry, and reads via a single `snapshot()` call. Cheap
    /// on warm caches; a few seconds the first time.
    @MainActor
    private func backfillMetadataIfNeeded(visibleFetch: PHFetchResult<PHAsset>) async {
        let metadataSnapshot = (try? await self.localAssetMetadataStore.snapshot()) ?? []
        let knownIds = Set(metadataSnapshot.map(\.localIdentifier))
        let cacheIds = (try? await self.localHashStore.allLocalIdentifiers()) ?? []
        let missingFromMetadata = cacheIds.subtracting(knownIds)
        guard !missingFromMetadata.isEmpty else { return }

        // Intersect with currently-alive PHAssets — we can only
        // capture metadata for assets PhotoKit can still hand us. Build
        // a quick lookup from the visibleFetch to avoid an N×M scan.
        var liveById: [String: PHAsset] = [:]
        liveById.reserveCapacity(visibleFetch.count)
        visibleFetch.enumerateObjects { asset, _, _ in
            liveById[asset.localIdentifier] = asset
        }
        let backfillTargets = missingFromMetadata.compactMap { liveById[$0] }
        guard !backfillTargets.isEmpty else { return }

        let now = Date()
        var entries: [LocalAssetMetadata] = []
        entries.reserveCapacity(backfillTargets.count)
        for asset in backfillTargets {
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
        do {
            try await self.localAssetMetadataStore.record(entries)
            syncLog.notice("[cairn.metadata] backfilled \(entries.count, privacy: .public) entries (cache=\(cacheIds.count, privacy: .public) had-metadata=\(knownIds.count, privacy: .public) still-missing=\(missingFromMetadata.count - entries.count, privacy: .public) — those PHAssets are no longer fetchable)")
        } catch {
            syncLog.error("[cairn.metadata] backfill failed: \(Self.describeSyncError(error), privacy: .public)")
        }
    }

    // MARK: - Live reconciliation

    @MainActor
    fileprivate func performLiveReconciliation(
        client: ImmichClient,
        everSeen: SwiftDataEverSeenStore,
        exclusions: SwiftDataExclusionStore,
        confirmed: SwiftDataConfirmedDeletedStore
    ) async throws {
        let syncStart = Date()

        await refreshLibrarySizeStats()

        // Refresh server count concurrently — don't block the scan.
        // Bootstrap already seeded this value; this just picks up
        // any changes since last launch.
        Task { [weak self] in
            guard let stats = try? await client.assetStatistics() else { return }
            await MainActor.run { self?.model.library = self!.model.library.with(server: stats.total) }
        }

        serverChecksumSet = nil
        let hashStoreRef = self.localHashStore
        let serverAssetsTask = Task { [weak self] () -> [ServerAsset] in
            let assets = try await client.listAllAssets()
            let checksums = Set(assets.map(\.checksum))
            let nonTrashed = assets.filter { !$0.isTrashed }.count
            // Seed matched from already-cached hashes so a resumed scan
            // doesn't show 0 matched until the final reconciliation.
            let localChecksums = (try? await hashStoreRef.allChecksums()) ?? []
            let initialMatched = checksums.intersection(localChecksums).count
            await MainActor.run {
                self?.serverChecksumSet = checksums
                if let self {
                    self.model.library = self.model.library.with(server: nonTrashed, matched: initialMatched)
                }
            }
            return assets
        }

        guard let reconciler = persistentChangeReconciler else {
            throw CancellationError()
        }
        model.syncPhase = .hashing
        let t0 = Date()
        let scan = try await reconciler.runDeletionScan(skipDrain: true)
        syncLog.info("[cairn.sync] scan took \(Int(Date().timeIntervalSince(t0) * 1000))ms (events=\(scan.changeEventsProcessed))")
        let burst = scan.newlyConfirmedDeleted.count

        try Task.checkCancellation()
        model.syncPhase = .fetchingServer
        let t1 = Date()
        let local = try await self.localHashStore.allChecksums()
        let indexedCount = try await self.localHashStore.indexedCount()

        let visibleFetchOptions = PHFetchOptions()
        visibleFetchOptions.includeHiddenAssets = false
        visibleFetchOptions.includeAssetSourceTypes = [.typeUserLibrary]
        let visibleFetch = PHAsset.fetchAssets(with: visibleFetchOptions)
        var totalVisibleAssets = visibleFetch.count
        if let cap = Self.resolveTestingAssetCap(), totalVisibleAssets > cap {
            totalVisibleAssets = cap
        }

        syncLog.info("[cairn.sync] local checksums fetched in \(Int(Date().timeIntervalSince(t1) * 1000))ms (\(indexedCount) entries)")

        // Bulk metadata backfill: cairn's observer-time metadata path
        // only covers events fired while cairn is alive (foreground or
        // recently active). Older photos cached before the metadata
        // store existed, OR observed during a window when cairn was
        // suspended, end up in `LocalHashStore` without a matching
        // `LocalAssetMetadataStore` row. Without metadata, the orphan
        // reconciler can't match those assets if they later get
        // edited-then-deleted-fast (the eager observer can miss the
        // change, and observeAndFilter can't fetch a deleted asset).
        // Snapshot metadata for any cached id that's still alive in
        // PhotoKit but missing from the store. Idempotent —
        // `record(_:)` upserts, so repeating the call is cheap.
        await backfillMetadataIfNeeded(visibleFetch: visibleFetch)

        let t2 = Date()
        let everSeenSet = try await everSeen.snapshot()
        let exclusionSet = Set(try await exclusions.snapshot().keys)
        let confirmedMap = try await confirmed.snapshot()

        // Edit-retirement: union the firstObserved SHA1s for every
        // alive `localIdentifier` into the "current local" set the
        // engine sees. Effect: while a photo is alive in PhotoKit,
        // its original-content anchor never enters the candidate
        // diff, even if intermediate edits have replaced its
        // current-bytes SHA1 in `LocalHashStore`. Without this
        // union, edited-but-kept photos would have their original
        // SHA1 silently classified as a deletion candidate (it's in
        // ever-seen, absent from current-bytes), and the wrong-
        // semantics fix would be only half-applied.
        var editRetirementHeld: Set<Checksum> = []
        if let editRetirementStore {
            let snapshot = try await editRetirementStore.snapshot()
            if !snapshot.isEmpty {
                var liveLocalIds = Set<String>()
                liveLocalIds.reserveCapacity(visibleFetch.count)
                visibleFetch.enumerateObjects { asset, _, _ in
                    liveLocalIds.insert(asset.localIdentifier)
                }
                for (id, anchorSet) in snapshot where liveLocalIds.contains(id) {
                    editRetirementHeld.formUnion(anchorSet)
                }
            }
        }
        let extendedLocal = local.union(editRetirementHeld)

        // Wrongly-stamped quarantine cleanup. Pre-fix code paths (and
        // the EditRetirementStore-migration era) may have stamped the
        // original SHA1 of an edited photo into ConfirmedDeletedStore
        // when the edit ran. Now that it's anchored as firstObserved
        // for a live id, it must NOT be sitting in quarantine — the
        // edit-retirement contract is "anchor protects, no quarantine."
        // Drop any held checksum from ConfirmedDeletedStore on every
        // sync. Idempotent: nothing to remove for assets that never
        // hit the buggy path. Mirrors the existing `confirmedDeleted.remove(allRecentlyObserved)`
        // restoration step but covers the wider "anchored by alive id"
        // surface, including assets not edited this scan.
        if !editRetirementHeld.isEmpty {
            try? await confirmed.remove(editRetirementHeld)
        }

        syncLog.info("[cairn.sync] store snapshots took \(Int(Date().timeIntervalSince(t2) * 1000))ms (edit-retirement-held=\(editRetirementHeld.count))")
        let t3 = Date()
        let serverAssets = try await serverAssetsTask.value
        syncLog.info("[cairn.sync] server fetch took \(Int(Date().timeIntervalSince(t3) * 1000))ms (\(serverAssets.count) assets)")

        try Task.checkCancellation()
        model.syncPhase = .reconciling

        // Thumbhash population runs after reconciliation completes —
        // don't block the user-facing result for cache warming.
        let thumbhashWork: [(assetId: String, data: Data)] = {
            guard thumbnailStore != nil else { return [] }
            return serverAssets.compactMap { asset in
                guard everSeenSet.contains(asset.checksum),
                      let hash = asset.thumbhash,
                      let data = Data(base64Encoded: hash) else { return nil }
                return (assetId: asset.id, data: data)
            }
        }()
        let settings = model.settings

        // Scope-aware indexing: when the user has restricted cairn to
        // specific albums, fetch the album-tag map and pass it (along
        // with the active scope) into the engine. The engine filters
        // EverSeen entries to only those whose tags intersect the scope
        // before computing candidates — out-of-scope photos quietly
        // exclude themselves from the diff. `nil` for full-library mode
        // (the default) preserves the legacy behavior.
        let everSeenAlbumTags: [Checksum: Set<String>]?
        let selectedAlbumScope: Set<String>?
        switch settings.indexingScope {
        case .fullLibrary:
            everSeenAlbumTags = nil
            selectedAlbumScope = nil
        case .selectedAlbums(let albumIds):
            everSeenAlbumTags = (try? await everSeen.snapshotWithTags()) ?? [:]
            selectedAlbumScope = albumIds
        }

        // Limited Photo Access guard: when iOS is exposing only the
        // user's selected subset, force `.strict` regardless of the
        // user's stored preference. Combined with the reconciler-side
        // `requireExplicitDeletionEvent` flag, this means selection
        // changes that vanish photos from PhotoKit go to pendingReview
        // instead of trash. The user's original strictness setting is
        // preserved in `CairnSettings`; if they switch back to full
        // access later, normal behavior resumes.
        let limitedAccess = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited
        let effectiveStrictness: DeletionStrictness = limitedAccess
            ? .strict
            : settings.deletionStrictness

        var result = ReconciliationEngine.compute(.init(
            serverAssets: serverAssets,
            currentLocalChecksums: extendedLocal,
            everSeenChecksums: everSeenSet,
            excludedChecksums: exclusionSet,
            confirmedDeletedAt: confirmedMap,
            now: Date(),
            quarantineDays: settings.quarantineDays,
            strictness: effectiveStrictness,
            everSeenAlbumTags: everSeenAlbumTags,
            selectedAlbumScope: selectedAlbumScope
        ))

        // Token-expiry safety gate. A full re-enumeration triggered by an
        // expired (or unparseable) persistent-change token means the change
        // events that would have stamped quarantine clocks are gone — every
        // deletion accumulated during the dormant window arrives as a
        // negative-signal-only candidate. Promote them all into the pending
        // bucket so the user reviews them before anything trashes,
        // regardless of strictness.
        let wasTokenExpiry = scan.fullEnumerationCause == .tokenExpired
        if wasTokenExpiry {
            result = result.gatedForReview()
        }

        // Orphan reconciliation. Catches the cull-burst case the
        // SHA1-based reconciler can't see: photo taken, uploaded to
        // Immich, and deleted locally before cairn could hash it. By
        // the time we look, the bytes are gone — `EverSeenStore` never
        // got the checksum. We match server assets against the metadata
        // we captured at observer time (filename + creationDate). See
        // `OrphanReconciler` for the match algorithm. Orphans land in
        // `pendingReviewCandidates` regardless of strictness; the user
        // must approve.
        var inferredOrphanLocalIds: [Checksum: String] = [:]
        do {
            let metadataSnapshot = try await self.localAssetMetadataStore.snapshot()
            syncLog.notice("[cairn.orphan] starting match: serverAssets=\(serverAssets.count, privacy: .public) metadata=\(metadataSnapshot.count, privacy: .public) everSeen=\(everSeenSet.count, privacy: .public)")
            if !metadataSnapshot.isEmpty {
                var presentLocalIds = Set<String>()
                presentLocalIds.reserveCapacity(visibleFetch.count)
                visibleFetch.enumerateObjects { asset, _, _ in
                    presentLocalIds.insert(asset.localIdentifier)
                }
                // Surface orphan candidate counts BEFORE the match so we
                // can tell whether the gate is filtering them out vs the
                // match algorithm not finding correlations.
                let nonTrashedNonEverSeen = serverAssets.filter { !$0.isTrashed && !everSeenSet.contains($0.checksum) }
                let absentMetadataCount = metadataSnapshot.filter { !presentLocalIds.contains($0.localIdentifier) }.count
                syncLog.notice("[cairn.orphan] gate: server-non-trashed-non-everSeen=\(nonTrashedNonEverSeen.count, privacy: .public) metadata-for-absent-ids=\(absentMetadataCount, privacy: .public) presentLocalIds=\(presentLocalIds.count, privacy: .public)")
                let orphans = OrphanReconciler.match(
                    serverAssets: serverAssets,
                    everSeen: everSeenSet,
                    metadata: metadataSnapshot,
                    presentLocalIdentifiers: presentLocalIds
                )
                syncLog.notice("[cairn.orphan] match result: \(orphans.count, privacy: .public) orphans found")
                if !orphans.isEmpty {
                    let existingPendingChecksums = Set(result.pendingReviewCandidates.map(\.checksum))
                    let existingDeleteChecksums = Set(result.deleteCandidates.map(\.checksum))
                    var pending = result.pendingReviewCandidates
                    for orphan in orphans {
                        inferredOrphanLocalIds[orphan.serverAsset.checksum] = orphan.matchedMetadata.localIdentifier
                        // By definition, orphans aren't in everSeen and
                        // therefore can't be in deleteCandidates; the
                        // pending dedup is defensive in case future
                        // engine changes blur the line.
                        guard !existingPendingChecksums.contains(orphan.serverAsset.checksum),
                              !existingDeleteChecksums.contains(orphan.serverAsset.checksum) else { continue }
                        pending.append(orphan.serverAsset)
                    }
                    result = ReconciliationOutput(
                        deleteCandidates: result.deleteCandidates,
                        newlyObservedChecksums: result.newlyObservedChecksums,
                        assetsInEverSeen: result.assetsInEverSeen,
                        excludedCandidateCount: result.excludedCandidateCount,
                        pendingReviewCandidates: pending,
                        heldByQuarantineCandidates: result.heldByQuarantineCandidates
                    )
                    syncLog.info("[cairn.sync] inferred \(orphans.count) orphan(s) via metadata match")
                }
            }
        } catch {
            // Metadata snapshot is best-effort; a SwiftData fetch failure
            // shouldn't poison the whole reconciliation. The standard
            // ever-seen reconciler still ran and its results are fine.
            syncLog.error("[cairn.sync] orphan match skipped: \(Self.describeSyncError(error), privacy: .public)")
        }

        let serverNonTrashed = serverAssets.filter { !$0.isTrashed }.count
        let liveLibrary = CairnFixtures.LibrarySize(
            local: totalVisibleAssets,
            indexed: indexedCount,
            server: serverNonTrashed,
            matched: result.assetsInEverSeen,
            candidates: result.deleteCandidates.count
        )
        // Merge the source-id mapping from three sources, in
        // precedence order:
        //   1. Persistent `deletionSourceStore` snapshot — the
        //      authoritative record for items not retired in this
        //      pass; survives across syncs so quarantined entries
        //      from previous scans keep their grouping linkage.
        //   2. This scan's `sourceLocalIdentifierByChecksum` —
        //      most-recent retire from a particular id; overrides
        //      the persistent record for items just retired.
        //   3. Inferred orphans — filename-matching is the most
        //      authoritative for items the SHA1 reconciler can't
        //      see (deleted before hash, never in everSeen).
        // Each step overwrites collisions so later sources win.
        var mergedSourceIds: [Checksum: String] = [:]
        if let deletionSourceStore {
            mergedSourceIds = (try? await deletionSourceStore.snapshot()) ?? [:]
        }
        for (checksum, localId) in scan.sourceLocalIdentifierByChecksum {
            mergedSourceIds[checksum] = localId
        }
        for (checksum, localId) in inferredOrphanLocalIds {
            mergedSourceIds[checksum] = localId
        }
        model.reconciliation = .init(
            deleteCandidates: result.deleteCandidates,
            pendingReviewCandidates: result.pendingReviewCandidates,
            heldByQuarantineCandidates: result.heldByQuarantineCandidates,
            confirmedDeletedAt: confirmedMap,
            quarantineDays: settings.quarantineDays,
            inferredOrphanLocalIdentifiers: inferredOrphanLocalIds,
            firstObservedAnchors: editRetirementHeld,
            sourceLocalIdentifiersByChecksum: mergedSourceIds
        )
        model.library = liveLibrary
        model.lastScanBurstCount = burst
        model.inferredOrphanCount = inferredOrphanLocalIds.count
        model.lastScanWasTokenExpiryFullEnum = wasTokenExpiry
        model.hasCompletedInitialScan = true
        model.lastCheckedAt = model.reconciliation?.computedAt
        await persistSnapshotFromModel()

        // Detect "user restored locally what cairn already trashed on
        // Immich." Intersect this scan's freshly-observed checksums
        // against successful trash runs from the journal (within
        // Immich's 30-day hard-delete window). A non-empty intersection
        // means the Immich mobile app's upload will silently no-op
        // because the asset is still in Immich trash with the same
        // SHA1 — silent data divergence the user can't see until the
        // server purges. The Status banner surfaces the count so the
        // user can restore on Immich too.
        if let journal {
            let entries = (try? await journal.readAll()) ?? []
            let trashedIndex = JournalReader.recentlyTrashedChecksums(
                in: entries,
                withinDays: 30
            )
            let observed = scan.recentlyObservedChecksums
            var matches: [Checksum: JournalReader.TrashedRecord] = [:]
            for cs in observed {
                if let record = trashedIndex[cs] {
                    matches[cs] = record
                }
            }
            model.restoredAfterCairnTrash = matches
        }

        let isEventfulSync = scan.didFullEnumeration
            || scan.changeEventsProcessed > 0
            || scan.drainedFromQueue > 0
        if isEventfulSync, let journal {
            let runId = "\(ISO8601DateFormatter().string(from: Date()))-\(UUID().uuidString.prefix(8))"
            let elapsedMs = Int(Date().timeIntervalSince(syncStart) * 1000)
            do {
                try await journal.append(.init(
                    runId: runId,
                    event: .syncCompleted(
                        indexed: indexedCount,
                        candidates: result.deleteCandidates.count,
                        pendingReview: result.pendingReviewCandidates.count,
                        deferredLarge: scan.deferredLarge,
                        deferredLargeBytes: scan.deferredLargeBytes,
                        deferredTimeout: scan.deferredTimeout,
                        elapsedMs: elapsedMs
                    )
                ))
                // Sync-transitions companion event: record edit-
                // retirement partitioning and per-source attribution
                // of confirmed deletions. Only fires when at least one
                // count is non-zero so the journal isn't spammed with
                // empty transition rows on quiet syncs. Same runId as
                // the syncCompleted above so the journal-tail banding
                // groups them visually.
                let totalTransitions = scan.editsProtected
                    + scan.editsQuarantined
                    + scan.confirmedFromPhotoKit
                    + scan.confirmedFromOrphanSweep
                if totalTransitions > 0 {
                    try? await journal.append(.init(
                        runId: runId,
                        event: .syncTransitions(
                            editsProtected: scan.editsProtected,
                            editsQuarantined: scan.editsQuarantined,
                            confirmedFromPhotoKit: scan.confirmedFromPhotoKit,
                            confirmedFromOrphanSweep: scan.confirmedFromOrphanSweep
                        )
                    ))
                }
            } catch {
                // The sync itself succeeded; only the forensic journal
                // entry failed to write. Don't alert the user — that
                // makes a successful sync look like an error. Log for
                // diagnostics; the next sync will record a fresh entry.
                syncLog.error("[cairn.sync] journal write failed: \(Self.describeSyncError(error), privacy: .public)")
            }
        }

        // Buffer enough history for the user to scroll back through
        // recent activity on Status without leaving the screen. 500
        // rows ≈ months of normal use; reading them once costs the
        // same I/O as the full `readAll` we already run for runs.
        // Settings → Clear journal still exists for anyone who wants
        // the slate wiped.
        await refreshJournalTail()

        await refreshDeferredQueueSummary()
        await refreshRunsList()
        await refreshQuarantineCount()

        if result.deleteCandidates.isEmpty && result.pendingReviewCandidates.isEmpty {
            showStatusToast(.upToDate(indexed: indexedCount, total: totalVisibleAssets))
        } else {
            model.syncToast = nil
        }

        if let thumbStore = thumbnailStore, !thumbhashWork.isEmpty {
            Task {
                try? await thumbStore.saveThumbhashes(thumbhashWork)
                let thumbhashCap = self.model.settings.thumbhashCapMB * 1024 * 1024
                try? await thumbStore.evictThumbhashes(overCapBytes: thumbhashCap)
                let thumbnailCap = self.model.settings.thumbnailCacheCapMB * 1024 * 1024
                try? await thumbStore.evictThumbnails(overCapBytes: thumbnailCap)
            }
        }
    }

    /// Repopulate `model.journalTail` from the on-disk journal. Called
    /// inline at sync end and from every mutating action (trash, restore,
    /// exclude) so the Status journal card reflects the new event
    /// immediately rather than waiting for the next sync to roll
    /// through. Silent-no-op when the journal isn't yet wired or the
    /// read fails — preserves the previous tail rather than blanking it.
    @MainActor
    fileprivate func refreshJournalTail() async {
        guard let journal else { return }
        guard let recent = try? await journal.lastEntries(limit: 500) else { return }
        // Per-key activation filter: hide entries that predate the
        // current API key's first verify. Keeps the user's mental
        // model "this key sees what this key did" consistent without
        // destroying the on-disk journal. `.distantPast` on bootstrap
        // upgrade installs means no filtering, so existing users see
        // everything.
        let cutoff = currentKeyActivatedAt ?? .distantPast
        let filtered = recent.filter { $0.timestamp >= cutoff }
        model.journalTail = Array(CairnFixtures.JournalTailEntry.from(entries: filtered).reversed())
    }

    @MainActor
    fileprivate func refreshRunsList() async {
        guard let journal else {
            model.runs = []
            model.runAssets = [:]
            return
        }
        let entries = (try? await journal.readAll()) ?? []
        // Filter to entries that happened on/after this key's first
        // verify. See `refreshJournalTail` for the rationale.
        let cutoff = currentKeyActivatedAt ?? .distantPast
        let visibleEntries = entries.filter { $0.timestamp >= cutoff }
        let summaries = JournalReader.summarize(visibleEntries)
        model.runs = summaries.compactMap(CairnFixtures.RunFixture.from)

        var perRun: [String: [CairnFixtures.CandidateFixture]] = [:]
        for entry in visibleEntries {
            guard case .planningTrash(let targets) = entry.event else { continue }
            var seen: Set<String> = Set((perRun[entry.runId] ?? []).compactMap(\.assetId))
            var bucket = perRun[entry.runId] ?? []
            for target in targets where !seen.contains(target.assetId) {
                bucket.append(CairnFixtures.CandidateFixture.from(target))
                seen.insert(target.assetId)
            }
            perRun[entry.runId] = bucket
        }
        model.runAssets = perRun
    }

    @MainActor
    fileprivate func refreshLibrarySizeStats() async {
        // Resolve scope membership once. `.selectedAlbums(...)` rescopes
        // both the "Phone" count and the "Indexed" intersection so the
        // numbers reflect the user's chosen managed slice rather than
        // the full device library. `.fullLibrary` keeps legacy semantics.
        let activeScope = model.settings.indexingScope
        let membership: PhotoKitScopeEnumerator.Membership? = await Task.detached(priority: .userInitiated) {
            PhotoKitScopeEnumerator.membershipMap(for: activeScope)
        }.value

        let totalVisible: Int
        if let membership {
            // `.selectedAlbums(...)` — count is the union of localIds
            // across selected albums. `Phone` reads as "photos cairn
            // can manage right now," consistent with the engine's
            // scope filter.
            var n = membership.localIds.count
            if let cap = Self.resolveTestingAssetCap(), n > cap { n = cap }
            totalVisible = n
        } else {
            let opts = PHFetchOptions()
            opts.includeHiddenAssets = false
            opts.includeAssetSourceTypes = [.typeUserLibrary]
            let fetch = PHAsset.fetchAssets(with: opts)
            var n = fetch.count
            if let cap = Self.resolveTestingAssetCap(), n > cap { n = cap }
            totalVisible = n
        }

        // "Indexed" counts **PHAssets** (localIdentifiers), not raw
        // SHA1 checksums. A Live Photo is one PHAsset that produces
        // two SHA1s (still + paired motion), and counting checksums
        // would double-count those rows; counting PHAssets matches
        // the "On iPhone" stat unit-for-unit so they're directly
        // comparable.
        //
        // Per-account scoping: LocalHashStore is global (content-
        // addressed cache shared across accounts on this device).
        // The per-account filter is "this localId's checksums
        // intersect the active account's EverSeen" — that excludes
        // localIds cached for OTHER accounts whose checksums never
        // entered this account's view. Without it the count would
        // inflate when a user switches accounts on the same device.
        //
        // Per-scope filter: when scope is restricted to selected
        // albums, additionally require the localId to be in the
        // scope membership map. Out-of-scope localIds drop out.
        //
        // When EverSeen is unavailable (server not yet activated,
        // identity not yet cached, or transient SwiftData hiccup),
        // surface `indexedKnown: false` so the UI shows "—" instead
        // of a stale count.
        if let everSeen = self.everSeenStore,
           let entries = try? await self.localHashStore.snapshot(),
           let observed = try? await everSeen.snapshot() {
            var indexedAssets = 0
            for (localId, checksums) in entries {
                // Per-account filter — at least one of this localId's
                // checksums must be in the active account's EverSeen.
                guard !checksums.intersection(observed).isEmpty else { continue }
                // Per-scope filter — when restricted, require the
                // localId to belong to a selected album.
                if let membership, !membership.localIds.contains(localId) { continue }
                indexedAssets += 1
            }
            model.library = model.library.with(local: totalVisible, indexed: indexedAssets, indexedKnown: true)
        } else {
            model.library = model.library.with(local: totalVisible, indexedKnown: false)
        }
    }

    /// Capture the current status counts to disk so the next cold launch
    /// can render them before sync runs. Best-effort cosmetic — failures
    /// log and bail; nothing user-visible depends on this succeeding.
    @MainActor
    fileprivate func persistSnapshotFromModel() async {
        guard let store = statusSnapshotStore else { return }
        let snapshot = StatusSnapshot(
            deleteCandidatesCount: model.library.candidates,
            matchedCount: model.library.matched,
            pendingReviewCount: model.reconciliation?.pendingReviewCandidates.count ?? 0,
            inferredOrphanCount: model.inferredOrphanCount,
            computedAt: model.reconciliation?.computedAt ?? model.lastCheckedAt ?? Date()
        )
        do {
            try await store.save(snapshot)
        } catch {
            syncLog.error("[cairn.snapshot] save failed: \(Self.describeSyncError(error), privacy: .public)")
        }
    }

    @MainActor
    fileprivate func showStatusToast(_ toast: CairnAppModel.SyncToast) {
        model.syncToast = toast
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(CairnAppModel.SyncToast.autoDismissSeconds * 1_000_000_000))
            guard self?.model.syncToast == toast else { return }
            // Explicit withAnimation here so the auto-dismiss is
            // animated even though the mutation happens inside a
            // detached Task. The `cairnBannerAnimation(value:)`
            // modifier on StatusScreen *should* be enough — it
            // watches bannerVisibilityKey which includes
            // `syncToast != nil` — but in practice SwiftUI doesn't
            // always pick up the animation context for state
            // mutations originating from Task contexts. Wrapping
            // here guarantees the .transition(.cairnBanner) on the
            // banner runs with the canonical springy timing.
            withAnimation(.cairnSpring) {
                self?.model.syncToast = nil
            }
        }
    }

    @MainActor
    /// Refresh `EverSeenStore` album tags to match the currently
    /// selected scope. Called from a SwiftUI `.onChange` in
    /// CairnAppRoot whenever `model.settings.indexingScope` mutates.
    /// No-op for `.fullLibrary` (the engine bypasses the tag filter
    /// in that mode, so tags don't need to match anything). For
    /// `.selectedAlbums`, walks each selected album once via
    /// `PHAssetCollection.fetchAssetCollections`, builds a
    /// `[Checksum: Set<albumId>]` map by joining album membership
    /// against `LocalHashStore`'s `[localId: Set<Checksum>]`, and
    /// upserts via `recordObserved`. Idempotent.
    fileprivate func recomputeScopeTagsImpl() async {
        let scope = await MainActor.run { model.settings.indexingScope }
        guard case .selectedAlbums(let albumIds) = scope, !albumIds.isEmpty else {
            return
        }
        guard let everSeenStore = self.everSeenStore else { return }

        // PhotoKit enumeration of selected albums runs off-main —
        // potentially hundreds of localIdentifiers across multiple
        // albums, and we don't want to block any animations while it's
        // happening.
        let albumMembership = await Task.detached(priority: .userInitiated) {
            Self.enumerateAlbumMembership(albumIds: albumIds)
        }.value

        // Join with LocalHashStore: for each known localId in any
        // selected album, attribute its checksums to the album set.
        let allHashes: [String: Set<Checksum>]
        do {
            allHashes = try await self.localHashStore.snapshot()
        } catch {
            syncLog.error("[cairn.scope] hash-store snapshot failed during tag rebuild: \(Self.describeSyncError(error), privacy: .public)")
            return
        }

        var tagsByChecksum: [Checksum: Set<String>] = [:]
        for (localId, albumIdSet) in albumMembership {
            guard let checksums = allHashes[localId] else { continue }
            for checksum in checksums {
                tagsByChecksum[checksum, default: []].formUnion(albumIdSet)
            }
        }

        do {
            try await everSeenStore.recordObserved(tagsByChecksum)
            syncLog.info("[cairn.scope] tagged \(tagsByChecksum.count, privacy: .public) ever-seen entries across \(albumIds.count, privacy: .public) selected album(s)")
        } catch {
            syncLog.error("[cairn.scope] recordObserved failed during tag rebuild: \(Self.describeSyncError(error), privacy: .public)")
        }
    }

    /// Build a `[localId: Set<albumId>]` inverted map by enumerating
    /// each selected `PHAssetCollection`'s assets. Albums that don't
    /// resolve (deleted from Photos.app since the user picked them)
    /// are silently skipped — the Settings UI will surface the missing-
    /// album warning separately.
    nonisolated static func enumerateAlbumMembership(albumIds: Set<String>) -> [String: Set<String>] {
        let identifiers = Array(albumIds)
        let collections = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: identifiers,
            options: nil
        )
        var inverted: [String: Set<String>] = [:]
        collections.enumerateObjects { collection, _, _ in
            let albumId = collection.localIdentifier
            // Include hidden assets so Live Photo motion videos and
            // user-hidden items (which can still be in albums) show up
            // and align with how the reconciler enumerates the library.
            let assetOpts = PHFetchOptions()
            assetOpts.includeHiddenAssets = true
            let assets = PHAsset.fetchAssets(in: collection, options: assetOpts)
            assets.enumerateObjects { asset, _, _ in
                inverted[asset.localIdentifier, default: []].insert(albumId)
            }
        }
        return inverted
    }

    fileprivate func refreshDeferredQueueSummary() async {
        let entries = (try? await deferredHashStore.snapshot()) ?? []
        let ceilingMB = model.settings.iCloudMaxEverBytesMB
        let ceilingBytes: Int64? = ceilingMB.flatMap { $0 > 0 ? Int64($0) * 1024 * 1024 : nil }

        var actionable = 0
        var aboveCeiling = 0
        var bytes: Int64 = 0
        for entry in entries {
            if let ceilingBytes, let size = entry.sizeBytes, size > ceilingBytes {
                aboveCeiling += 1
            } else {
                actionable += 1
                if let size = entry.sizeBytes { bytes += size }
            }
        }
        model.deferredQueue = .init(count: actionable, aboveCeiling: aboveCeiling, totalKnownBytes: bytes)
    }

    /// Empty every backing store the index touches: per-(URL, userId)
    /// engine state (ever-seen, confirmed-deleted, change-token, edit
    /// retirement, deletion source, status snapshot) plus the global
    /// content-addressed caches (local hash store, deferred queue,
    /// metadata store). Returns aggregated failures so the caller can
    /// surface a partial-success message rather than silently dropping
    /// errors. Shared between `resetIndex` (this account only) and
    /// `resetIndexAllAccounts` (which adds disk-level partition cleanup
    /// on top).
    @MainActor
    fileprivate func clearCurrentPartitionStores() async -> [(label: String, error: Swift.Error)] {
        let lh = self.localHashStore
        let dh = self.deferredHashStore
        let eh = self.everSeenStore
        let cd = self.confirmedDeletedStore
        let tk = self.tokenStore
        let er = self.editRetirementStore
        let ds = self.deletionSourceStore
        let mdStore = self.localAssetMetadataStore
        let ss = self.statusSnapshotStore

        // Aggregate failures so a single store's hiccup doesn't leave
        // the user with partial-but-silent state. The metadata store
        // is the input to the orphan matcher; clearing the index
        // without it would leave stale rows that could resurrect
        // ghost orphans.
        var ops: [(label: String, body: @Sendable () async throws -> Void)] = [
            ("local hash cache", { try await lh.clear() }),
            ("deferred queue", { try await dh.clear() }),
            ("metadata store", { try await mdStore.clear() }),
        ]
        if let eh { ops.append(("ever-seen store", { try await eh.clear() })) }
        if let cd { ops.append(("confirmed-deleted store", { try await cd.clear() })) }
        if let tk { ops.append(("change-token store", { try await tk.clear() })) }
        if let er { ops.append(("edit-retirement store", { try await er.clear() })) }
        if let ds { ops.append(("deletion-source store", { try await ds.clear() })) }
        if let ss { ops.append(("status snapshot store", { try await ss.clear() })) }
        return await Self.aggregateClears(ops)
    }

    /// Reset every transient `model` field that derives from the
    /// engine state we just cleared. Doesn't touch credentials,
    /// settings, or excluded entries — those survive a reset by design.
    /// Shared between `resetIndex` and `resetIndexAllAccounts`.
    @MainActor
    fileprivate func resetModelAfterIndexClear() {
        self.model.reconciliation = nil
        self.model.library = .empty
        self.model.lastScanBurstCount = 0
        self.model.inferredOrphanCount = 0
        self.model.lastScanWasTokenExpiryFullEnum = false
        self.model.restoredAfterCairnTrash = [:]
        self.model.syncProgress = nil
        self.model.hasCompletedInitialScan = false
        self.model.didAutoSyncThisSession = false
        self.model.deferredQueue = .empty
        self.model.journalTail = []
        self.model.runs = []
        self.model.runAssets = [:]
        self.model.lastCheckedAt = nil
    }

    /// Walk every per-(URL, userId) partition directory under
    /// `Application Support/servers/` and `Documents/servers/`, remove
    /// each one EXCEPT the current partition's. The current
    /// partition's SwiftData container is open against those files;
    /// deleting underneath it would crash. Caller is expected to have
    /// already cleared the current partition's stores via
    /// `clearCurrentPartitionStores()` so the in-memory state matches.
    nonisolated fileprivate static func removeOtherPartitionsOnDisk(except currentKey: ServerPartitionKey?) {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let serversDir = appSupport.appending(path: "servers")
        let docsServersDir = documentsDirectory().appending(path: "servers")
        let currentName = currentKey?.directoryName

        // SwiftData containers and their `-shm` / `-wal` siblings live
        // in `Application Support/servers/`. Match by name prefix so
        // we catch all three files for each non-current partition.
        if let entries = try? fm.contentsOfDirectory(at: serversDir, includingPropertiesForKeys: nil) {
            for e in entries {
                let name = e.lastPathComponent
                if let cur = currentName,
                   name == "\(cur).store" || name == "\(cur).store-shm" || name == "\(cur).store-wal" {
                    continue
                }
                do { try fm.removeItem(at: e) } catch {
                    syncLog.error("[cairn.reset.all] couldn't remove \(name, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }

        // Journal directories live in `Documents/servers/<dirName>/`.
        if let entries = try? fm.contentsOfDirectory(at: docsServersDir, includingPropertiesForKeys: nil) {
            for e in entries {
                let name = e.lastPathComponent
                if let cur = currentName, name == cur { continue }
                do { try fm.removeItem(at: e) } catch {
                    syncLog.error("[cairn.reset.all] couldn't remove journal dir \(name, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    fileprivate func refreshExcludedChecksums() async {
        guard let exclusionStore else {
            await MainActor.run { self.model.excludedChecksums = [] }
            return
        }
        let snapshot = (try? await exclusionStore.snapshot()) ?? [:]
        let keys = Set(snapshot.keys.map(\.base64))
        await MainActor.run { self.model.excludedChecksums = keys }
    }

    fileprivate func refreshQuarantineCount() async {
        guard let confirmed = confirmedDeletedStore else {
            await MainActor.run { self.model.quarantineCount = 0 }
            return
        }
        let snapshot = (try? await confirmed.snapshot()) ?? [:]
        let days = await model.settings.quarantineDays
        let cutoff = Date().addingTimeInterval(-TimeInterval(days) * 86_400)
        let inQuarantine = snapshot.values.filter { $0 > cutoff }.count
        await MainActor.run { self.model.quarantineCount = inQuarantine }
    }

    func checkServerHealth() async {
        guard let client = immichClient else { return }
        let start = Date()
        do {
            _ = try await client.ping()
            let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
            model.degraded = .none
            model.connectionStatus = .healthy(latencyMs: latencyMs)
        } catch {
            let degraded = Self.degradedState(for: error)
            if let degraded {
                model.degraded = degraded
                model.connectionStatus = degraded == .authStale ? .authStale : .offline
            } else {
                model.connectionStatus = .offline
            }
        }
    }

    /// User-facing error copy for a Photos auth status that blocks
    /// sync. cairn now accepts `.limited` (PhotoKit transparently scopes
    /// fetches to the user's selection, and the reconciler applies a
    /// `requireExplicitDeletionEvent` guard so selection changes don't
    /// look like deletions). `.denied`, `.restricted`, and
    /// `.notDetermined` still block — this message is for those.
    nonisolated fileprivate static func photosAuthMessage(for status: PHAuthorizationStatus) -> String {
        return "cairn needs Photos access to find deleted photos. Open Settings \u{2192} cairn \u{2192} Photos and grant access (full or limited)."
    }

    nonisolated fileprivate static func isUsablePhotoAuth(_ status: PHAuthorizationStatus) -> Bool {
        return status == .authorized || status == .limited
    }

    /// Stable, anonymous-ish identifier for an API key. SHA256 of the
    /// raw key bytes, hex-truncated to 16 chars (64 bits → ample
    /// collision resistance among the small number of keys a single
    /// user generates over a device's lifetime). Used as the map key
    /// in `MutableSecretStore.keyActivationMap()` so we can answer
    /// "have I seen this exact key before?" without storing the key
    /// itself in the map. Defense-in-depth — the Keychain is already
    /// encrypted, but a fingerprint-only map limits blast radius if
    /// the json blob is ever logged or exfiltrated.
    nonisolated fileprivate static func apiKeyFingerprint(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    /// Read-modify-write the per-key activation map. If `fingerprint`
    /// already has an entry, returns it unchanged (preserves history
    /// when the user rotates back to a previously-used key). Otherwise
    /// inserts `seedAt` and persists. Returns the activation timestamp
    /// the caller should remember for filtering. Failures are logged
    /// and surface as `.distantPast` so a Keychain hiccup never hides
    /// the user's history.
    nonisolated fileprivate static func upsertKeyActivation(
        in store: any MutableSecretStore,
        fingerprint: String,
        seedAt: Date
    ) -> Date {
        var map = (try? store.keyActivationMap()) ?? [:]
        if let existing = map[fingerprint] {
            return existing
        }
        map[fingerprint] = seedAt
        do {
            try store.setKeyActivationMap(map)
        } catch {
            syncLog.error("[cairn.boot] failed to persist key activation map: \(String(describing: error), privacy: .public)")
            return .distantPast
        }
        return seedAt
    }

    nonisolated fileprivate static func degradedState(for error: Swift.Error) -> StatusScreen.Degraded? {
        if let e = error as? ImmichClientError {
            switch e {
            case .httpStatus(let code, _):
                if code == 401 || code == 403 { return .authStale }
                if code >= 500 { return .serverDown }
                return nil
            case .invalidURL:
                return nil
            case .unexpectedResponse:
                return .serverDown
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return .serverDown
        }
        return nil
    }

    /// Run a batch of async-throwing operations, collecting failures
    /// without short-circuiting. Used by destructive paths (sign-out,
    /// reset-index, etc.) where one failed store-clear shouldn't
    /// prevent the rest from being attempted, but the user still
    /// needs to know something went wrong rather than seeing "ok"
    /// after a half-completed reset.
    nonisolated fileprivate static func aggregateClears(
        _ ops: [(label: String, body: @Sendable () async throws -> Void)]
    ) async -> [(label: String, error: Swift.Error)] {
        var failures: [(label: String, error: Swift.Error)] = []
        for op in ops {
            do {
                try await op.body()
            } catch {
                failures.append((op.label, error))
            }
        }
        return failures
    }

    /// Format a failures list for `model.lastError`. Shows a friendly
    /// summary plus the labels of what didn't clear; the full error
    /// detail goes to the syncLog.
    nonisolated fileprivate static func summarizeClearFailures(
        action: String,
        _ failures: [(label: String, error: Swift.Error)]
    ) -> String {
        let labels = failures.map(\.label).joined(separator: ", ")
        if failures.count == 1 {
            return "\(action) didn't fully complete — \(labels) couldn't be cleared. Some data may persist on this device."
        }
        return "\(action) didn't fully complete — \(failures.count) items couldn't be cleared (\(labels)). Some data may persist on this device."
    }

    nonisolated fileprivate static func describeSyncError(_ error: Swift.Error) -> String {
        if let e = error as? ImmichClientError {
            switch e {
            case .httpStatus(let code, let body):
                if code == 401 { return "Immich rejected the API key (HTTP 401). Try re-verifying in Settings." }
                if code == 403 { return "API key is missing scopes. Need asset.read + asset.delete + tag.*." }
                if code >= 500 { return "Immich server error (HTTP \(code)). Try again in a minute." }
                return "Immich returned HTTP \(code): \(body.prefix(200))"
            case .unexpectedResponse(let msg):
                return "Unexpected Immich response: \(msg)"
            case .invalidURL:
                return "The Immich URL looks malformed. Fix it in Settings."
            }
        }
        if let e = error as? PhotoKitPhotoEnumerator.Error {
            switch e {
            case .notAuthorized:
                return "cairn needs Full Photos access. Settings → cairn → Photos → All Photos."
            case .resourceReadFailed(_, let msg):
                return "Couldn't read a photo's bytes: \(msg). iCloud offline?"
            case .noHashableResource(let id):
                return "An asset had no readable bytes (\(id.prefix(8))…). Skipped."
            }
        }
        return String(describing: error)
    }

    // MARK: - Action wiring

    private func rewireActions() {
        let secrets = self.secretStore

        let actions = CairnAppActions(
            requestSync: { [weak self] in
                guard let self else { return }
                await MainActor.run {
                    self.model.isSyncing = true
                    self.model.lastError = nil
                    if let paused = self.model.pausedSyncElapsedSeconds {
                        self.model.syncStartedAt = Date().addingTimeInterval(-paused)
                        self.model.pausedSyncElapsedSeconds = nil
                    } else {
                        self.model.syncProgress = nil
                        self.model.syncStartedAt = Date()
                    }
                }

                guard let client = await self.immichClient else {
                    await MainActor.run {
                        self.model.lastError = "Not signed in yet. Complete onboarding first."
                        self.model.isSyncing = false
                        self.model.syncPhase = .idle
                    }
                    return
                }
                guard let everSeen = await self.everSeenStore,
                      let exclusions = await self.exclusionStore,
                      let confirmed = await self.confirmedDeletedStore else {
                    await MainActor.run {
                        self.model.lastError = "No server activated. Complete onboarding first."
                        self.model.isSyncing = false
                        self.model.syncPhase = .idle
                    }
                    return
                }

                let photoStatus = await MainActor.run { PHPhotoLibrary.authorizationStatus(for: .readWrite) }
                let effectiveStatus: PHAuthorizationStatus
                if photoStatus == .notDetermined {
                    effectiveStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                } else {
                    effectiveStatus = photoStatus
                }
                if Self.isUsablePhotoAuth(effectiveStatus) {
                    // Photos was just (or is now) granted. The bootstrap-
                    // time observer registration silently skipped if auth
                    // wasn't granted yet, so register here to catch the
                    // post-grant case.
                    await MainActor.run { self.registerPhotoLibraryObserver() }
                }
                guard Self.isUsablePhotoAuth(effectiveStatus) else {
                    let message = AppDependencies.photosAuthMessage(for: effectiveStatus)
                    await MainActor.run {
                        self.model.lastError = message
                        self.model.isSyncing = false
                        self.model.syncPhase = .idle
                        self.model.syncStartedAt = nil
                    }
                    return
                }

                do {
                    try await self.performLiveReconciliation(
                        client: client,
                        everSeen: everSeen,
                        exclusions: exclusions,
                        confirmed: confirmed
                    )
                    await MainActor.run {
                        self.model.isSyncing = false
                        self.model.syncPhase = .idle
                        self.model.syncProgress = nil
                        self.model.syncStartedAt = nil
                        self.model.pausedSyncElapsedSeconds = nil
                        self.model.degraded = .none
                        self.lastSyncEndedAt = Date()
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        let elapsed = self.model.syncStartedAt.map {
                            Date().timeIntervalSince($0)
                        } ?? 0
                        self.model.pausedSyncElapsedSeconds = max(0, elapsed)
                        self.model.syncStartedAt = nil
                        self.model.isSyncing = false
                        self.model.syncPhase = .idle
                        self.lastSyncEndedAt = Date()
                    }
                } catch {
                    let degraded = Self.degradedState(for: error)
                    let desc = Self.describeSyncError(error)
                    syncLog.info("[cairn.sync] requestSync failed: \(desc)")
                    await MainActor.run {
                        self.model.lastError = desc
                        self.model.isSyncing = false
                        self.model.syncPhase = .idle
                        self.model.syncProgress = nil
                        self.model.syncStartedAt = nil
                        self.model.pausedSyncElapsedSeconds = nil
                        if let degraded { self.model.degraded = degraded }
                        self.lastSyncEndedAt = Date()
                    }
                }
            },
            confirmTrash: { [weak self] in
                guard let self,
                      let client = await self.immichClient,
                      let journal = await self.journal,
                      let live = await self.model.reconciliation,
                      !live.deleteCandidates.isEmpty else { return }
                let runId = "\(ISO8601DateFormatter().string(from: Date()))-\(UUID().uuidString.prefix(8))"
                let orchestrator = TrashOrchestrator(writer: client, journal: journal)
                do {
                    let result = try await orchestrator.run(
                        runId: runId,
                        candidates: live.deleteCandidates,
                        assetsInPurview: live.deleteCandidates.count + live.pendingReviewCandidates.count,
                        dryRun: false
                    )
                    let trashedCount = result.trashedAssetIds.count
                    await MainActor.run {
                        self.model.reconciliation = nil
                        if trashedCount > 0 {
                            let current = self.model.library
                            self.model.library = current.with(
                                server: max(0, current.server - trashedCount),
                                matched: max(0, current.matched - trashedCount),
                                candidates: max(0, current.candidates - trashedCount)
                            )
                        }
                    }
                    await self.persistSnapshotFromModel()
                    await self.refreshRunsList()
                    await self.refreshJournalTail()
                } catch {
                    // Surface the error via model.lastError (the UI alert
                    // binding reads this). We deliberately don't re-throw:
                    // every caller invokes the action via `Task { try? await
                    // ... }`, so a re-throw silently vanishes anyway.
                    // Setting lastError is the single source of truth.
                    await MainActor.run {
                        self.model.lastError = Self.describeSyncError(error)
                    }
                    await self.refreshRunsList()
                    await self.refreshJournalTail()
                }
            },
            restore: { [weak self] assetIds, runId in
                guard let self,
                      let client = await self.immichClient,
                      let journal = await self.journal else { return }
                let orch = RestoreOrchestrator(writer: client, journal: journal)
                let scope: Set<String>? = assetIds.isEmpty ? nil : Set(assetIds)
                do {
                    let summary = try await orch.restore(fromRunId: runId, assetIds: scope)

                    // Local-state cleanup that the orchestrator (which
                    // is platform-agnostic and lives in CairnCore)
                    // can't do: clear ConfirmedDeletedStore for the
                    // restored checksums and add them to ExclusionStore.
                    // Without this, the next sync re-flags these as
                    // deletion candidates because:
                    //   - the photo is still missing locally (restore
                    //     puts it back on Immich, not on the device)
                    //   - ConfirmedDeleted still holds the original
                    //     "deleted at T" stamp → past-quarantine →
                    //     `deleteCandidates` → re-trashed
                    // The user's "restore" intent semantically matches
                    // exclude — "preserve this asset on Immich." Mirrors
                    // the cleanup that `excludePending` does.
                    let entries = (try? await journal.readAll()) ?? []
                    var planningTargets: [JournalEntry.TrashTarget] = []
                    for entry in entries where entry.runId == runId {
                        if case .planningTrash(let targets) = entry.event {
                            planningTargets = targets
                        }
                    }
                    let restoredIdSet = Set(summary.restoredAssetIds)
                    let restoredChecksumStrings = planningTargets
                        .filter { restoredIdSet.contains($0.assetId) }
                        .map(\.checksum)
                    let cks = Set(restoredChecksumStrings.map { Checksum(base64: $0) })

                    if !cks.isEmpty {
                        try? await self.confirmedDeletedStore?.remove(cks)
                        try? await self.deletionSourceStore?.remove(cks)
                        if let exclusions = await self.exclusionStore {
                            let now = Date()
                            let exclusionEntries: [Checksum: ExclusionMetadata] = Dictionary(
                                uniqueKeysWithValues: cks.map {
                                    ($0, ExclusionMetadata(addedAt: now, fromRunId: runId, reason: "restored-from-run"))
                                }
                            )
                            try? await exclusions.insert(exclusionEntries)
                            // Forensic symmetry with `excludePending`:
                            // record the implicit exclusion in the
                            // journal so a later reader can see why
                            // these checksums became excluded.
                            try? await journal.append(.init(
                                timestamp: now,
                                runId: runId,
                                event: .assetsExcluded(
                                    checksums: restoredChecksumStrings,
                                    fromRunId: runId
                                )
                            ))
                        }
                        await self.refreshExcludedChecksums()
                        // Prune the in-memory reconciliation so the
                        // restored checksums don't keep showing up as
                        // candidates until the next sync. Also nudge
                        // `model.library.server` and `.matched` upward
                        // by the count Immich actually restored — same
                        // pattern `approvePending` uses to drop server
                        // count on trash. Without this, the Status
                        // page's counters lag a sync behind every
                        // restore (visible in demos).
                        let restoredServerCount = summary.restoredAssetIds.count
                        await MainActor.run {
                            guard let existing = self.model.reconciliation else { return }
                            self.model.reconciliation = .init(
                                deleteCandidates: existing.deleteCandidates.filter { !cks.contains($0.checksum) },
                                pendingReviewCandidates: existing.pendingReviewCandidates.filter { !cks.contains($0.checksum) },
                                heldByQuarantineCandidates: existing.heldByQuarantineCandidates.filter { !cks.contains($0.checksum) },
                                confirmedDeletedAt: existing.confirmedDeletedAt.filter { !cks.contains($0.key) },
                                quarantineDays: existing.quarantineDays,
                                computedAt: existing.computedAt,
                                inferredOrphanLocalIdentifiers: existing.inferredOrphanLocalIdentifiers.filter { !cks.contains($0.key) },
                                firstObservedAnchors: existing.firstObservedAnchors,
                                sourceLocalIdentifiersByChecksum: existing.sourceLocalIdentifiersByChecksum.filter { !cks.contains($0.key) }
                            )
                            if restoredServerCount > 0 {
                                let current = self.model.library
                                self.model.library = current.with(
                                    server: current.server + restoredServerCount,
                                    matched: current.matched + restoredServerCount
                                )
                            }
                        }
                    }

                    await self.refreshRunsList()
                    await self.refreshJournalTail()
                } catch {
                    // Surface the error via model.lastError (the UI alert
                    // binding reads this). We deliberately don't re-throw:
                    // every caller invokes the action via `Task { try? await
                    // ... }`, so a re-throw silently vanishes anyway.
                    // Setting lastError is the single source of truth.
                    await MainActor.run {
                        self.model.lastError = Self.describeSyncError(error)
                    }
                    await self.refreshRunsList()
                    await self.refreshJournalTail()
                }
            },
            exclude: { [weak self] checksums, filenames, runId in
                guard let self,
                      let exclusions = await self.exclusionStore,
                      let journal = await self.journal else { return }
                let entries: [Checksum: ExclusionMetadata] = Dictionary(
                    uniqueKeysWithValues: checksums.map {
                        (Checksum(base64: $0), ExclusionMetadata(addedAt: Date(), fromRunId: runId, reason: nil))
                    }
                )
                do {
                    try await exclusions.insert(entries)
                    try await journal.append(.init(
                        runId: runId,
                        event: .assetsExcluded(checksums: checksums, fromRunId: runId)
                    ))
                    await self.refreshExcludedChecksums()
                    await self.refreshJournalTail()
                } catch {
                    await MainActor.run {
                        self.model.lastError = Self.describeSyncError(error)
                    }
                }
                _ = filenames
            },
            unexclude: { [weak self] checksums in
                guard let self,
                      let exclusions = await self.exclusionStore else { return }
                let cks = Set(checksums.map { Checksum(base64: $0) })
                do {
                    try await exclusions.remove(cks)
                    await self.refreshExcludedChecksums()
                } catch {
                    await MainActor.run {
                        self.model.lastError = Self.describeSyncError(error)
                    }
                }
            },
            approvePending: { [weak self] checksums in
                guard let self,
                      let client = await self.immichClient,
                      let journal = await self.journal,
                      let live = await self.model.reconciliation else { return }
                let wanted = Set(checksums)
                let candidates = (live.pendingReviewCandidates + live.heldByQuarantineCandidates)
                    .filter { wanted.contains($0.checksum.base64) }
                guard !candidates.isEmpty else { return }
                // Capture the orphan→localId mapping for the candidates
                // we're about to trash. After a successful trash the
                // metadata rows are no longer useful (the asset's gone
                // both locally and on the server) and would keep
                // re-matching on subsequent syncs.
                let orphanMetadataLocalIds: Set<String> = Set(candidates.compactMap {
                    live.inferredOrphanLocalIdentifiers[$0.checksum]
                })
                let runId = "\(ISO8601DateFormatter().string(from: Date()))-\(UUID().uuidString.prefix(8))"
                let orchestrator = TrashOrchestrator(writer: client, journal: journal)
                do {
                    let result = try await orchestrator.run(
                        runId: runId,
                        candidates: candidates,
                        assetsInPurview: live.deleteCandidates.count + live.pendingReviewCandidates.count,
                        dryRun: false
                    )
                    let trashedCount = result.trashedAssetIds.count
                    if !orphanMetadataLocalIds.isEmpty {
                        try? await self.localAssetMetadataStore.remove(orphanMetadataLocalIds)
                    }
                    let cks = Set(wanted.map { Checksum(base64: $0) })
                    try? await self.deletionSourceStore?.remove(cks)
                    await MainActor.run {
                        guard let existing = self.model.reconciliation else { return }
                        let prunedOrphanMap = existing.inferredOrphanLocalIdentifiers
                            .filter { !wanted.contains($0.key.base64) }
                        let prunedSourceIds = existing.sourceLocalIdentifiersByChecksum
                            .filter { !wanted.contains($0.key.base64) }
                        self.model.reconciliation = .init(
                            deleteCandidates: existing.deleteCandidates,
                            pendingReviewCandidates: existing.pendingReviewCandidates.filter { !wanted.contains($0.checksum.base64) },
                            heldByQuarantineCandidates: existing.heldByQuarantineCandidates.filter { !wanted.contains($0.checksum.base64) },
                            confirmedDeletedAt: existing.confirmedDeletedAt,
                            quarantineDays: existing.quarantineDays,
                            computedAt: existing.computedAt,
                            inferredOrphanLocalIdentifiers: prunedOrphanMap,
                            firstObservedAnchors: existing.firstObservedAnchors,
                            sourceLocalIdentifiersByChecksum: prunedSourceIds
                        )
                        self.model.inferredOrphanCount = prunedOrphanMap.count
                        if trashedCount > 0 {
                            let current = self.model.library
                            self.model.library = current.with(
                                server: max(0, current.server - trashedCount),
                                matched: max(0, current.matched - trashedCount)
                            )
                        }
                    }
                    await self.persistSnapshotFromModel()
                    await self.refreshRunsList()
                    await self.refreshJournalTail()
                } catch {
                    // Surface the error via model.lastError (the UI alert
                    // binding reads this). We deliberately don't re-throw:
                    // every caller invokes the action via `Task { try? await
                    // ... }`, so a re-throw silently vanishes anyway.
                    // Setting lastError is the single source of truth.
                    await MainActor.run {
                        self.model.lastError = Self.describeSyncError(error)
                    }
                    await self.refreshRunsList()
                    await self.refreshJournalTail()
                }
            },
            excludePending: { [weak self] checksums in
                guard let self,
                      let exclusions = await self.exclusionStore,
                      let confirmed = await self.confirmedDeletedStore else { return }
                let now = Date()
                var entries: [Checksum: ExclusionMetadata] = [:]
                let cks = Set(checksums.map { Checksum(base64: $0) })
                for checksum in cks {
                    entries[checksum] = ExclusionMetadata(addedAt: now, fromRunId: nil, reason: "pending-review")
                }
                do {
                    try await exclusions.insert(entries)
                    try await confirmed.remove(cks)
                    try? await self.deletionSourceStore?.remove(cks)
                    // Audit symmetry with the regular `exclude` path —
                    // the pending-review bulk-exclude was previously
                    // silent in the journal, so excluded-via-review
                    // items had no forensic trail. Use a synthetic
                    // runId so the row groups with whatever previous
                    // run flagged the items, but `fromRunId: nil`
                    // matches the actual semantics (this isn't tied
                    // to a specific run; the user picked them off
                    // pending review).
                    if let journal = await self.journal {
                        let pendingExcludeRunId = "pending-review-\(ISO8601DateFormatter().string(from: now))"
                        try? await journal.append(.init(
                            timestamp: now,
                            runId: pendingExcludeRunId,
                            event: .assetsExcluded(checksums: checksums, fromRunId: nil)
                        ))
                    }
                    await MainActor.run {
                        guard let existing = self.model.reconciliation else { return }
                        let prunedOrphanMap = existing.inferredOrphanLocalIdentifiers.filter { !cks.contains($0.key) }
                        let prunedSourceIds = existing.sourceLocalIdentifiersByChecksum.filter { !cks.contains($0.key) }
                        self.model.reconciliation = .init(
                            deleteCandidates: existing.deleteCandidates,
                            pendingReviewCandidates: existing.pendingReviewCandidates.filter { !cks.contains($0.checksum) },
                            heldByQuarantineCandidates: existing.heldByQuarantineCandidates.filter { !cks.contains($0.checksum) },
                            confirmedDeletedAt: existing.confirmedDeletedAt.filter { !cks.contains($0.key) },
                            quarantineDays: existing.quarantineDays,
                            computedAt: existing.computedAt,
                            inferredOrphanLocalIdentifiers: prunedOrphanMap,
                            firstObservedAnchors: existing.firstObservedAnchors,
                            sourceLocalIdentifiersByChecksum: prunedSourceIds
                        )
                        self.model.inferredOrphanCount = prunedOrphanMap.count
                    }
                    await self.persistSnapshotFromModel()
                    await self.refreshJournalTail()
                } catch {
                    await MainActor.run {
                        self.model.lastError = Self.describeSyncError(error)
                    }
                }
            },
            dismissPending: { [weak self] checksums in
                guard let self,
                      let confirmed = await self.confirmedDeletedStore,
                      let everSeen = await self.everSeenStore else { return }
                let cks = Set(checksums.map { Checksum(base64: $0) })
                // Resolve source localIdentifiers BEFORE we mutate
                // anything — both maps live on the in-memory
                // reconciliation snapshot, which we'll prune below.
                // Need them to wipe `LocalAssetMetadataStore` rows so
                // the orphan reconciler can't re-surface these assets
                // on the next sync via filename + creationDate match.
                let sourceLocalIds: Set<String> = await MainActor.run {
                    guard let existing = self.model.reconciliation else { return [] }
                    var ids: Set<String> = []
                    for c in cks {
                        if let id = existing.sourceLocalIdentifiersByChecksum[c] {
                            ids.insert(id)
                        }
                        if let id = existing.inferredOrphanLocalIdentifiers[c] {
                            ids.insert(id)
                        }
                    }
                    return ids
                }
                let metadataStore = await MainActor.run { self.localAssetMetadataStore }
                do {
                    try await confirmed.remove(cks)
                    try await everSeen.remove(cks)
                    try? await self.deletionSourceStore?.remove(cks)
                    // Without this, the orphan reconciler at
                    // `OrphanReconciler.match` finds the asset on the
                    // next sync — `everSeen` no longer contains the
                    // checksum (we just removed), but the metadata row
                    // still satisfies the filename + creationDate +
                    // absent-localId filters → it reappears as an
                    // "unconfirmed" entry in PendingReview, contradicting
                    // dismiss's "removes from the pending list" copy.
                    if !sourceLocalIds.isEmpty {
                        try? await metadataStore.remove(sourceLocalIds)
                    }
                    await MainActor.run {
                        guard let existing = self.model.reconciliation else { return }
                        let prunedOrphanMap = existing.inferredOrphanLocalIdentifiers.filter { !cks.contains($0.key) }
                        let prunedSourceIds = existing.sourceLocalIdentifiersByChecksum.filter { !cks.contains($0.key) }
                        self.model.reconciliation = .init(
                            deleteCandidates: existing.deleteCandidates,
                            pendingReviewCandidates: existing.pendingReviewCandidates.filter { !cks.contains($0.checksum) },
                            heldByQuarantineCandidates: existing.heldByQuarantineCandidates.filter { !cks.contains($0.checksum) },
                            confirmedDeletedAt: existing.confirmedDeletedAt.filter { !cks.contains($0.key) },
                            quarantineDays: existing.quarantineDays,
                            computedAt: existing.computedAt,
                            inferredOrphanLocalIdentifiers: prunedOrphanMap,
                            firstObservedAnchors: existing.firstObservedAnchors,
                            sourceLocalIdentifiersByChecksum: prunedSourceIds
                        )
                        self.model.inferredOrphanCount = prunedOrphanMap.count
                    }
                    await self.refreshQuarantineCount()
                    await self.persistSnapshotFromModel()
                } catch {
                    await MainActor.run {
                        self.model.lastError = Self.describeSyncError(error)
                    }
                }
            },
            loadDeferredEntries: { [weak self] in
                guard let self else { return [] }
                let store = await MainActor.run { self.deferredHashStore }
                return (try? await store.snapshot()) ?? []
            },
            exportData: { [weak self] scope in
                guard let self else { throw CancellationError() }
                let (partitionKey, everSeen, exclusions, journal, settings) = await MainActor.run {
                    (self.currentPartitionKey, self.everSeenStore, self.exclusionStore, self.journal, self.model.settings)
                }

                var serverPayloads: [CairnExportPayload.ServerPayload] = []

                switch scope {
                case .currentServer:
                    guard let partitionKey, let everSeen, let exclusions, let journal else {
                        throw CancellationError()
                    }
                    let payload = try await Self.buildServerPayload(
                        key: partitionKey, everSeen: everSeen, exclusions: exclusions, journal: journal
                    )
                    serverPayloads.append(payload)

                case .allServers:
                    if let partitionKey, let everSeen, let exclusions, let journal {
                        let payload = try await Self.buildServerPayload(
                            key: partitionKey, everSeen: everSeen, exclusions: exclusions, journal: journal
                        )
                        serverPayloads.append(payload)
                    }

                    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    let serversDir = appSupport.appending(path: "servers")
                    if let entries = try? FileManager.default.contentsOfDirectory(
                        at: serversDir, includingPropertiesForKeys: nil
                    ) {
                        let currentDirName = partitionKey?.directoryName
                        for entry in entries {
                            let dirName = entry.deletingPathExtension().lastPathComponent
                            guard dirName != currentDirName else { continue }
                            guard entry.pathExtension == "store" else { continue }

                            guard let container = try? CairnSwiftDataContainer.makePerServer(url: entry) else { continue }
                            let otherEverSeen = SwiftDataEverSeenStore(container: container)
                            let otherExclusions = SwiftDataExclusionStore(container: container)

                            let normalizedURL = dirName.replacingOccurrences(of: "_", with: "://", range: dirName.range(of: "_"))
                            let otherKey = ServerPartitionKey(from: URL(string: normalizedURL) ?? URL(string: "https://\(dirName)")!)

                            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                                .appending(path: "servers").appending(path: dirName)
                            let journalURL = docs.appending(path: "deletion-journal.jsonl")
                            let otherJournal = DeletionJournal(path: journalURL)

                            let payload = try await Self.buildServerPayload(
                                key: otherKey, everSeen: otherEverSeen, exclusions: otherExclusions, journal: otherJournal
                            )
                            serverPayloads.append(payload)
                        }
                    }
                }

                let deviceName = await MainActor.run { UIDevice.current.name }
                let export = CairnExportPayload(
                    exportedFrom: deviceName,
                    servers: serverPayloads,
                    settings: settings
                )

                let data = try CairnExportPayload.encode(export)
                let dateStr = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                let fileName = "cairn-export-\(dateStr).json"
                let tempURL = FileManager.default.temporaryDirectory.appending(path: fileName)
                try data.write(to: tempURL, options: .atomic)
                return tempURL
            },
            importData: { [weak self] fileURL, applySettings in
                guard let self else { throw CancellationError() }
                let accessed = fileURL.startAccessingSecurityScopedResource()
                defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }

                let data = try Data(contentsOf: fileURL)
                let payload = try CairnExportPayload.decode(from: data)

                let (partitionKey, everSeen, exclusions, journal, settingsStore) = await MainActor.run {
                    (self.currentPartitionKey, self.everSeenStore, self.exclusionStore, self.journal, self.settingsStore)
                }

                var totalEverSeenAdded = 0
                var totalExclusionsAdded = 0
                var totalJournalLines = 0
                var processedServers = 0

                for serverPayload in payload.servers {
                    guard let partitionKey,
                          serverPayload.partitionKey == partitionKey.directoryName,
                          let everSeen, let exclusions, let journal else {
                        continue
                    }
                    processedServers += 1

                    let newChecksums = Set(serverPayload.everSeen.map { Checksum(base64: $0) })
                    let existing = try await everSeen.snapshot()
                    let actuallyNew = newChecksums.subtracting(existing)
                    if !actuallyNew.isEmpty {
                        try await everSeen.union(actuallyNew)
                    }
                    totalEverSeenAdded += actuallyNew.count

                    let existingExclusions = try await exclusions.snapshot()
                    var newExclusions: [Checksum: ExclusionMetadata] = [:]
                    for record in serverPayload.exclusions {
                        let ck = Checksum(base64: record.checksum)
                        if existingExclusions[ck] == nil {
                            newExclusions[ck] = ExclusionMetadata(
                                addedAt: record.addedAt,
                                fromRunId: record.fromRunId,
                                reason: record.reason
                            )
                        }
                    }
                    if !newExclusions.isEmpty {
                        try await exclusions.insert(newExclusions)
                        totalExclusionsAdded += newExclusions.count
                    }

                    if !serverPayload.journal.isEmpty {
                        try await journal.appendRawLines(serverPayload.journal)
                        totalJournalLines += serverPayload.journal.count
                    }
                }

                var didApplySettings = false
                if applySettings, let importedSettings = payload.settings {
                    try await settingsStore.save(importedSettings)
                    await MainActor.run { self.model.settings = importedSettings }
                    didApplySettings = true
                }

                await self.refreshExcludedChecksums()
                await self.refreshRunsList()
                await self.refreshJournalTail()

                return CairnImportResult(
                    everSeenAdded: totalEverSeenAdded,
                    exclusionsAdded: totalExclusionsAdded,
                    journalLinesAppended: totalJournalLines,
                    settingsApplied: didApplySettings,
                    serverCount: processedServers
                )
            },
            bulkExcludeRecentOffload: { [weak self] in
                guard let self,
                      let exclusions = await self.exclusionStore,
                      let confirmed = await self.confirmedDeletedStore else { return }
                let cutoff = Date().addingTimeInterval(-Self.massOffloadRecentWindow)
                do {
                    let snapshot = try await confirmed.snapshot()
                    let recent = snapshot.filter { $0.value >= cutoff }.keys
                    let cks = Set(recent)
                    guard !cks.isEmpty else { return }
                    let now = Date()
                    let entries: [Checksum: ExclusionMetadata] = Dictionary(
                        uniqueKeysWithValues: cks.map { ($0, ExclusionMetadata(addedAt: now, fromRunId: nil, reason: "mass-offload")) }
                    )
                    try await exclusions.insert(entries)
                    try await confirmed.remove(cks)
                    try? await self.deletionSourceStore?.remove(cks)
                    await MainActor.run {
                        guard let existing = self.model.reconciliation else { return }
                        let prunedOrphanMap = existing.inferredOrphanLocalIdentifiers.filter { !cks.contains($0.key) }
                        let prunedSourceIds = existing.sourceLocalIdentifiersByChecksum.filter { !cks.contains($0.key) }
                        self.model.reconciliation = .init(
                            deleteCandidates: existing.deleteCandidates,
                            pendingReviewCandidates: existing.pendingReviewCandidates.filter { !cks.contains($0.checksum) },
                            heldByQuarantineCandidates: existing.heldByQuarantineCandidates.filter { !cks.contains($0.checksum) },
                            confirmedDeletedAt: existing.confirmedDeletedAt.filter { !cks.contains($0.key) },
                            quarantineDays: existing.quarantineDays,
                            computedAt: existing.computedAt,
                            inferredOrphanLocalIdentifiers: prunedOrphanMap,
                            firstObservedAnchors: existing.firstObservedAnchors,
                            sourceLocalIdentifiersByChecksum: prunedSourceIds
                        )
                        self.model.inferredOrphanCount = prunedOrphanMap.count
                        self.model.lastScanBurstCount = 0
                        self.model.lastScanWasTokenExpiryFullEnum = false
                        self.model.restoredAfterCairnTrash = [:]
                    }
                    await self.persistSnapshotFromModel()
                } catch {
                    await MainActor.run {
                        self.model.lastError = Self.describeSyncError(error)
                    }
                }
            },
            verifyServer: { [weak self] urlString, key in
                guard let url = ImmichClient.parseServerURL(urlString) else {
                    return SetupScreen.ServerVerifyResult(
                        success: false,
                        assetCount: nil,
                        errorMessage: "That doesn't look like a valid URL. Try the full hostname, like immich.example.com."
                    )
                }
                let probe = ImmichClient(baseURL: url, apiKey: key)
                do {
                    let assets = try await probe.listAllAssets()
                    // Fetch the Immich user identity so we can partition
                    // per-server state by (URL, userId). Best-effort: an
                    // older Immich version that lacks /users/me, or a
                    // transient API hiccup, leaves us in URL-only-
                    // partition mode (graceful degradation — bootstrap
                    // will retry on next successful sync).
                    let identity: ImmichClient.UserIdentity? = try? await probe.usersMe()
                    if let self {
                        try? secrets.setServerURL(url)
                        try? secrets.setAPIKey(key)
                        if let identity {
                            try? secrets.setUserIdentity(id: identity.id, email: identity.email)
                        }
                        let priorPartitionKey = await MainActor.run { self.currentPartitionKey }
                        try? await MainActor.run {
                            try self.activateServer(url: url, apiKey: key, userId: identity?.id)
                        }
                        let newPartitionKey = await MainActor.run { self.currentPartitionKey }
                        let partitionChanged = priorPartitionKey != newPartitionKey

                        // Per-key activation timestamp. New keys (never
                        // seen before) seed `now` so their runs/journal-
                        // tail UI starts fresh. Returning to a previously-
                        // used key preserves that key's prior activation
                        // → its history is restored. Same for partition
                        // changes (the key is logically new for the new
                        // user too) — handled by the same upsert call
                        // because fingerprint is per-key, not per-user.
                        let fingerprint = AppDependencies.apiKeyFingerprint(key)
                        let activatedAt = AppDependencies.upsertKeyActivation(
                            in: secrets,
                            fingerprint: fingerprint,
                            seedAt: Date()
                        )
                        await MainActor.run { self.currentKeyActivatedAt = activatedAt }

                        let serverCount = assets.filter { !$0.isTrashed }.count
                        await MainActor.run {
                            self.model.serverHost = url.host() ?? url.absoluteString
                            self.model.serverURL = url
                            self.model.apiKey = key
                            self.model.apiKeyMasked = AppDependencies.mask(key)
                            self.model.library = self.model.library.with(server: serverCount)

                            // When the user verifies into a *different*
                            // partition (typically: same URL, different
                            // user account on a re-onboard or replay-
                            // onboarding flow), the model still holds the
                            // prior partition's runs / journal / indexed
                            // / reconciliation / etc. Clear the transient
                            // bits that don't have a refresh helper so
                            // the post-onboarding UI doesn't render
                            // Account A's data while standing on Account
                            // B's stores. Refresh helpers below repopulate
                            // the rest from the newly-activated partition.
                            if partitionChanged {
                                self.model.reconciliation = nil
                                self.model.lastScanBurstCount = 0
                                self.model.inferredOrphanCount = 0
                                self.model.lastScanWasTokenExpiryFullEnum = false
                                self.model.restoredAfterCairnTrash = [:]
                                self.model.lastCheckedAt = nil
                                self.model.lastError = nil
                                self.serverChecksumSet = nil
                            }
                        }

                        if let tokenStore = await self.tokenStore {
                            let tokenExists = (try? await tokenStore.load()) != nil
                            await MainActor.run { self.model.hasCompletedInitialScan = tokenExists }
                        }
                        await self.refreshExcludedChecksums()
                        if partitionChanged {
                            await self.refreshQuarantineCount()
                            await self.refreshJournalTail()
                            await self.refreshRunsList()
                            await self.refreshLibrarySizeStats()
                        }

                        await MainActor.run {
                            self.rewireActions()
                            self.registerPhotoLibraryObserver()
                        }
                    }
                    return SetupScreen.ServerVerifyResult(success: true, assetCount: assets.count, errorMessage: nil)
                } catch {
                    return SetupScreen.ServerVerifyResult(success: false, assetCount: nil, errorMessage: String(describing: error))
                }
            },
            retryConnection: { [weak self] in
                // Re-ping the configured server and refresh
                // connectionStatus + degraded. Wired to the "Retry"
                // button on the server-unreachable banner so a
                // transient blip can be cleared without running a
                // full sync.
                await self?.checkServerHealth()
            },
            requestPhotosAccess: {
                // PhotoKit's `requestAuthorization` only shows the
                // system prompt for `.notDetermined`. Once the user
                // has denied, it returns `.denied` immediately — the
                // user has to change the setting in iOS Settings.
                // Pre-check status and deep-link there so the
                // onboarding button does something useful.
                let prior = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                if prior == .denied || prior == .restricted {
                    await MainActor.run {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    return .denied
                }
                let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                switch status {
                case .authorized: return .full
                case .limited:    return .limited
                default:          return .denied
                }
            },
            currentPhotoAuthStatus: {
                // No prompt — pure read. SetupScreen calls this on
                // step appear and on app foreground to reflect the
                // user's actual decision (or lack of one).
                let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                switch status {
                case .notDetermined: return nil
                case .authorized:    return .full
                case .limited:       return .limited
                default:             return .denied
                }
            },
            requestBackgroundRefresh: {
                await MainActor.run { UIApplication.shared.backgroundRefreshStatus == .available }
            },
            resetIndex: { [weak self] in
                guard let self else { return }
                let failures = await self.clearCurrentPartitionStores()
                if !failures.isEmpty {
                    let detail = failures.map { "\($0.label): \(Self.describeSyncError($0.error))" }.joined(separator: "; ")
                    syncLog.error("[cairn.reset] partial failure: \(detail, privacy: .public)")
                }
                await MainActor.run {
                    self.resetModelAfterIndexClear()
                    if failures.isEmpty {
                        self.showStatusToast(.indexReset)
                    } else {
                        self.model.lastError = Self.summarizeClearFailures(action: "Reset index", failures)
                    }
                }
            },
            resetIndexAllAccounts: { [weak self] in
                guard let self else { return }
                // Step 1: clear the current partition's stores + global
                // caches via the same path `resetIndex` uses.
                let failures = await self.clearCurrentPartitionStores()
                if !failures.isEmpty {
                    let detail = failures.map { "\($0.label): \(Self.describeSyncError($0.error))" }.joined(separator: "; ")
                    syncLog.error("[cairn.reset.all] partial failure: \(detail, privacy: .public)")
                }

                // Step 2: rm -rf every per-(URL, userId) partition dir
                // on disk EXCEPT the current one (its container is
                // open against those files; deleting underneath an
                // open SwiftData container is unsafe). The current
                // partition was already emptied via .clear() in
                // step 1.
                let currentKey = await MainActor.run { self.currentPartitionKey }
                Self.removeOtherPartitionsOnDisk(except: currentKey)

                // Step 3: reset the per-key activation map. After
                // nuking everything cairn knew, the only meaningful
                // entry is the current key starting now.
                let key = await MainActor.run { self.model.apiKey }
                let fp = AppDependencies.apiKeyFingerprint(key)
                let now = Date()
                try? secrets.setKeyActivationMap([fp: now])
                await MainActor.run { self.currentKeyActivatedAt = now }

                await MainActor.run {
                    self.resetModelAfterIndexClear()
                    if failures.isEmpty {
                        self.showStatusToast(.indexReset)
                    } else {
                        self.model.lastError = Self.summarizeClearFailures(action: "Reset all accounts", failures)
                    }
                }
            },
            clearJournal: { [weak self] in
                guard let self else { return }
                // Per-key: bump the current key's `activatedAt` to
                // now in the keychain map. Existing journal entries
                // are filtered out of this key's runs/journal-tail
                // UI on next refresh; the on-disk journal file and
                // other keys' activation timestamps are preserved.
                let key = await MainActor.run { self.model.apiKey }
                let fp = AppDependencies.apiKeyFingerprint(key)
                var map = (try? secrets.keyActivationMap()) ?? [:]
                let now = Date()
                map[fp] = now
                try? secrets.setKeyActivationMap(map)
                await MainActor.run { self.currentKeyActivatedAt = now }
                await self.refreshRunsList()
                await self.refreshJournalTail()
                await MainActor.run { self.showStatusToast(.journalCleared) }
            },
            clearJournalAllKeys: { [weak self] in
                guard let self else { return }
                let journal = await MainActor.run { self.journal }
                var deleteError: Swift.Error?
                if let journal {
                    let path = await journal.path
                    do {
                        try FileManager.default.removeItem(at: path)
                    } catch {
                        // ENOENT is fine — file simply wasn't there
                        // (cairn never wrote a journal). Anything else
                        // is real and the user should see it.
                        let nsError = error as NSError
                        if !(nsError.domain == NSCocoaErrorDomain
                             && nsError.code == NSFileNoSuchFileError) {
                            deleteError = error
                            syncLog.error("[cairn.journal.all] clear failed: \(Self.describeSyncError(error), privacy: .public)")
                        }
                    }
                }
                // Reset the activation map: the journal file is gone,
                // so there are no per-key views worth preserving.
                // Seed the current key with `now` so the next entries
                // fall under this key's view.
                let key = await MainActor.run { self.model.apiKey }
                let fp = AppDependencies.apiKeyFingerprint(key)
                let now = Date()
                try? secrets.setKeyActivationMap([fp: now])
                await MainActor.run { self.currentKeyActivatedAt = now }

                await MainActor.run {
                    if let deleteError {
                        self.model.lastError = "Couldn't delete the local journal file. (\(Self.describeSyncError(deleteError)))"
                    } else {
                        self.model.journalTail = []
                        self.model.runs = []
                        self.model.runAssets = [:]
                        self.showStatusToast(.journalCleared)
                    }
                }
            },
            signOut: { [weak self] in
                var keychainError: Swift.Error?
                do {
                    try secrets.clear()
                } catch {
                    keychainError = error
                    syncLog.error("[cairn.signout] keychain clear failed: \(Self.describeSyncError(error), privacy: .public)")
                }
                await self?.thumbnailLoader?.clearCache()
                await MainActor.run {
                    guard let self else { return }
                    self.unregisterPhotoLibraryObserver()
                    self.immichClient = nil
                    self.thumbnailLoader = nil
                    self.currentPartitionKey = nil
                    self.serverContainer = nil
                    self.everSeenStore = nil
                    self.exclusionStore = nil
                    self.confirmedDeletedStore = nil
                    self.deletionSourceStore = nil
                    self.tokenStore = nil
                    self.editRetirementStore = nil
                    self.statusSnapshotStore = nil
                    self.thumbnailStore = nil
                    self.journal = nil
                    self.serverChecksumSet = nil
                    self.model.needsOnboarding = true
                    self.model.apiKey = ""
                    self.model.apiKeyMasked = ""
                    self.model.serverHost = ""
                    self.model.serverURL = nil
                    self.model.hasDismissedInitialScan = false
                    self.model.journalTail = []
                    self.model.runs = []
                    self.model.runAssets = [:]
                    self.model.reconciliation = nil
                    self.model.library = .empty
                    self.model.lastScanBurstCount = 0
                    self.model.inferredOrphanCount = 0
                    self.model.lastScanWasTokenExpiryFullEnum = false
                    self.model.restoredAfterCairnTrash = [:]
                    self.model.hasCompletedInitialScan = false
                    self.model.excludedChecksums = []
                    self.model.lastCheckedAt = nil
                    if let keychainError {
                        // Sign-out cleared in-memory state successfully,
                        // but the credential delete from Keychain failed.
                        // Surface so the user knows their key may still
                        // be on this device.
                        self.model.lastError = "Sign-out couldn't fully clear the saved credentials. (\(Self.describeSyncError(keychainError)))"
                    }
                }
            },
            rescanLibrary: { [weak self] in
                guard let self else { return }
                let (dh, tk) = await MainActor.run { (self.deferredHashStore, self.tokenStore) }
                var ops: [(label: String, body: @Sendable () async throws -> Void)] = [
                    ("deferred queue", { @Sendable in try await dh.clear() }),
                ]
                if let tk {
                    ops.append(("change-token store", { @Sendable in try await tk.clear() }))
                }
                let failures = await Self.aggregateClears(ops)
                if !failures.isEmpty {
                    let detail = failures.map { "\($0.label): \(Self.describeSyncError($0.error))" }.joined(separator: "; ")
                    syncLog.error("[cairn.rescan] partial failure: \(detail, privacy: .public)")
                }
                await MainActor.run {
                    self.model.hasCompletedInitialScan = false
                    self.model.reconciliation = nil
                    self.model.syncProgress = nil
                    self.model.deferredQueue = .empty
                    if failures.isEmpty {
                        self.showStatusToast(.rescanQueued)
                    } else {
                        self.model.lastError = Self.summarizeClearFailures(action: "Rescan setup", failures)
                    }
                }
            },
            persistSettings: { [weak self] settings in
                guard let self else { return }
                do {
                    try await self.settingsStore.save(settings)
                } catch {
                    syncLog.error("[cairn.settings] save failed: \(Self.describeSyncError(error), privacy: .public)")
                    await MainActor.run {
                        self.model.lastError = "Couldn't save your settings — they'll revert on next launch. (\(Self.describeSyncError(error)))"
                    }
                }
                await self.refreshDeferredQueueSummary()
            },
            dismissInitialScan: { [weak self] in
                guard let self else { return }
                await MainActor.run {
                    self.model.hasDismissedInitialScan = true
                }
            },
            startOverInitialScan: { [weak self] in
                guard let self else { return }
                let (lh, dh, tk, eh, cd, er, ds, mdStore, ss) = await MainActor.run {
                    (self.localHashStore, self.deferredHashStore, self.tokenStore, self.everSeenStore, self.confirmedDeletedStore, self.editRetirementStore, self.deletionSourceStore, self.localAssetMetadataStore, self.statusSnapshotStore)
                }
                var ops: [(label: String, body: @Sendable () async throws -> Void)] = [
                    ("local hash cache", { try await lh.clear() }),
                    ("deferred queue", { try await dh.clear() }),
                    ("metadata store", { try await mdStore.clear() }),
                ]
                if let tk { ops.append(("change-token store", { try await tk.clear() })) }
                if let eh { ops.append(("ever-seen store", { try await eh.clear() })) }
                if let cd { ops.append(("confirmed-deleted store", { try await cd.clear() })) }
                if let er { ops.append(("edit-retirement store", { try await er.clear() })) }
                if let ds { ops.append(("deletion-source store", { try await ds.clear() })) }
                if let ss { ops.append(("status snapshot store", { try await ss.clear() })) }
                let failures = await Self.aggregateClears(ops)
                if !failures.isEmpty {
                    let detail = failures.map { "\($0.label): \(Self.describeSyncError($0.error))" }.joined(separator: "; ")
                    syncLog.error("[cairn.startover] partial failure: \(detail, privacy: .public)")
                }
                await MainActor.run {
                    self.model.reconciliation = nil
                    self.model.library = .empty
                    self.model.lastScanBurstCount = 0
                    self.model.inferredOrphanCount = 0
                    self.model.lastScanWasTokenExpiryFullEnum = false
                    self.model.restoredAfterCairnTrash = [:]
                    self.model.syncProgress = nil
                    self.model.pausedSyncElapsedSeconds = nil
                    self.model.syncStartedAt = nil
                    self.model.hasCompletedInitialScan = false
                    self.model.lastCheckedAt = nil
                    if !failures.isEmpty {
                        self.model.lastError = Self.summarizeClearFailures(action: "Start-over reset", failures)
                    }
                }
                await self.refreshDeferredQueueSummary()
            },
            forceDrainDeferred: { [weak self] in
                guard let self else { return }
                let photoStatus = await MainActor.run { PHPhotoLibrary.authorizationStatus(for: .readWrite) }
                guard Self.isUsablePhotoAuth(photoStatus) else {
                    let message = AppDependencies.photosAuthMessage(for: photoStatus)
                    await MainActor.run {
                        self.model.lastError = message
                    }
                    return
                }
                await MainActor.run {
                    self.model.isSyncing = true
                    self.model.syncPhase = .hashing
                    self.model.lastError = nil
                    self.model.syncProgress = nil
                    self.model.syncStartedAt = Date()
                    self.model.pausedSyncElapsedSeconds = nil
                }
                await self.refreshLibrarySizeStats()
                guard let reconciler = await MainActor.run(body: { self.persistentChangeReconciler }) else {
                    await MainActor.run {
                        self.model.lastError = "No server activated."
                        self.model.isSyncing = false
                        self.model.syncPhase = .idle
                        self.model.syncStartedAt = nil
                    }
                    return
                }
                do {
                    _ = try await reconciler.drainDeferred()
                    await MainActor.run {
                        self.model.isSyncing = false
                        self.model.syncPhase = .idle
                        self.model.syncProgress = nil
                        self.model.syncStartedAt = nil
                    }
                    await self.refreshDeferredQueueSummary()
                } catch is CancellationError {
                    await MainActor.run {
                        let elapsed = self.model.syncStartedAt.map {
                            Date().timeIntervalSince($0)
                        } ?? 0
                        self.model.pausedSyncElapsedSeconds = max(0, elapsed)
                        self.model.syncStartedAt = nil
                        self.model.isSyncing = false
                        self.model.syncPhase = .idle
                    }
                    await self.refreshDeferredQueueSummary()
                } catch {
                    await MainActor.run {
                        self.model.lastError = Self.describeSyncError(error)
                        self.model.isSyncing = false
                        self.model.syncPhase = .idle
                        self.model.syncProgress = nil
                        self.model.syncStartedAt = nil
                    }
                    await self.refreshDeferredQueueSummary()
                }
            },
            replayOnboarding: { [weak self] in
                guard let self else { return }
                let url = try? self.secretStore.serverURL()
                let apiKey = try? self.secretStore.apiKey()
                await MainActor.run {
                    if let url {
                        self.model.serverHost = url.absoluteString
                    }
                    if let apiKey {
                        self.model.apiKey = apiKey
                    }
                    self.model.needsOnboarding = true
                }
            },
            recomputeScopeTags: { [weak self] in
                guard let self else { return }
                await self.recomputeScopeTagsImpl()
            }
        )

        self.model.actions = actions
    }

    // MARK: - Helpers

    nonisolated private static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private static func serverContainerURL(for key: ServerPartitionKey) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appending(path: "servers")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "\(key.directoryName).store")
    }

    private static func serverJournalURL(for key: ServerPartitionKey) -> URL {
        let docs = documentsDirectory().appending(path: "servers").appending(path: key.directoryName)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        return docs.appending(path: "deletion-journal.jsonl")
    }

    /// One-time rename: pre-userId-partitioning installs have a per-
    /// server directory at `<sanitizedURL>` (no user suffix). After
    /// per-user partitioning lands, the same data should live at
    /// `<sanitizedURL>__<userId>`. This helper detects that situation
    /// at activation time and renames in place — so the user's existing
    /// EverSeen, journal, runs, etc. carry forward without reset.
    ///
    /// Best-effort. If the rename fails (rare: file open by another
    /// process, permissions), we log but continue — `activateServer`
    /// will then create a fresh empty partition at the new path. State
    /// loss in that pathological case but no hard failure.
    private static func migrateLegacyServerPartitionIfNeeded(url: URL, userId: String?) {
        guard let userId, !userId.isEmpty else { return }
        let legacyKey = ServerPartitionKey(from: url, userId: nil)
        let newKey = ServerPartitionKey(from: url, userId: userId)
        guard legacyKey.directoryName != newKey.directoryName else { return }

        let fm = FileManager.default
        let legacyContainer = serverContainerURL(for: legacyKey)
        let newContainer = serverContainerURL(for: newKey)
        // SwiftData stores spawn `-shm` / `-wal` sibling files alongside
        // the main `.store`. Move all three for a clean migration.
        for suffix in ["", "-shm", "-wal"] {
            let src = URL(fileURLWithPath: legacyContainer.path + suffix)
            let dst = URL(fileURLWithPath: newContainer.path + suffix)
            if fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) {
                do {
                    try fm.moveItem(at: src, to: dst)
                } catch {
                    syncLog.error("[cairn.migrate] couldn't move \(src.lastPathComponent, privacy: .public) → \(dst.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }

        // Journal directory rename. The legacy layout puts every per-
        // server file under `documents/servers/<dirName>/`; we move the
        // whole directory to the new dirName and the journal file
        // (deletion-journal.jsonl) inside it carries forward intact.
        let docs = documentsDirectory().appending(path: "servers")
        let legacyJournalDir = docs.appending(path: legacyKey.directoryName)
        let newJournalDir = docs.appending(path: newKey.directoryName)
        if fm.fileExists(atPath: legacyJournalDir.path), !fm.fileExists(atPath: newJournalDir.path) {
            do {
                try fm.moveItem(at: legacyJournalDir, to: newJournalDir)
            } catch {
                syncLog.error("[cairn.migrate] couldn't move journal dir \(legacyJournalDir.lastPathComponent, privacy: .public) → \(newJournalDir.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        syncLog.notice("[cairn.migrate] partition rename: \(legacyKey.directoryName, privacy: .public) → \(newKey.directoryName, privacy: .public)")
    }

    private static func migrateFromLegacyIfNeeded(serverURL: URL) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "app.cairn.partitioned-v1") else { return }
        let key = ServerPartitionKey(from: serverURL)
        let fm = FileManager.default

        let docs = documentsDirectory()
        let legacyJournal = docs.appending(path: "deletion-journal.jsonl")
        if fm.fileExists(atPath: legacyJournal.path) {
            let dest = serverJournalURL(for: key)
            try? fm.moveItem(at: legacyJournal, to: dest)
        }

        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let legacyStore = appSupport.appending(path: "default.store")
        let serverStore = serverContainerURL(for: key)
        if fm.fileExists(atPath: legacyStore.path) && !fm.fileExists(atPath: serverStore.path) {
            for suffix in ["", "-shm", "-wal"] {
                let src = URL(fileURLWithPath: legacyStore.path + suffix)
                let dst = URL(fileURLWithPath: serverStore.path + suffix)
                if fm.fileExists(atPath: src.path) {
                    try? fm.copyItem(at: src, to: dst)
                }
            }
        }

        defaults.set(true, forKey: "app.cairn.partitioned-v1")
    }

    private static func buildServerPayload(
        key: ServerPartitionKey,
        everSeen: SwiftDataEverSeenStore,
        exclusions: SwiftDataExclusionStore,
        journal: DeletionJournal
    ) async throws -> CairnExportPayload.ServerPayload {
        let everSeenSet = try await everSeen.snapshot()
        let sortedEverSeen = everSeenSet.map(\.base64).sorted()

        let exclusionMap = try await exclusions.snapshot()
        let exclusionRecords = exclusionMap
            .sorted { $0.key.base64 < $1.key.base64 }
            .map { ck, meta in
                CairnExportPayload.ServerPayload.ExclusionRecord(
                    checksum: ck.base64,
                    addedAt: meta.addedAt,
                    fromRunId: meta.fromRunId,
                    reason: meta.reason
                )
            }

        let journalLines = (try? await journal.readRawLines()) ?? []

        return CairnExportPayload.ServerPayload(
            partitionKey: key.directoryName,
            normalizedURL: key.normalizedURL,
            everSeen: sortedEverSeen,
            exclusions: exclusionRecords,
            journal: journalLines
        )
    }

    private static func mask(_ key: String) -> String {
        let tail = key.suffix(4)
        return String(repeating: "•", count: 10) + tail
    }

    private static func makePreviewActions() -> CairnAppActions {
        CairnAppActions()
    }

    #if DEBUG
    @MainActor
    static func seedFromFixtures(into model: CairnAppModel) {
        let args = ProcessInfo.processInfo.arguments
        let wantsOnboarding = args.contains("-CAIRN_SCREENSHOT_ONBOARDING")
        let wantsDark = args.contains("-CAIRN_SCREENSHOT_DARK")
        // Demo-stage selector: 0..5 produce stages of the trash/restore
        // walkthrough on a 25-photo limited-scope album. Used to record
        // a workflow screencast/screenshots without touching a real
        // Immich. Falls through to the App-Store-marketing fixtures
        // when the arg is absent.
        let demoStage: Int? = {
            guard let idx = args.firstIndex(of: "-CAIRN_DEMO_STAGE"),
                  idx + 1 < args.count,
                  let n = Int(args[idx + 1]) else { return nil }
            return n
        }()

        model.actions = CairnAppActions()
        model.didAutoSyncThisSession = true

        model.serverHost = "photos.home.arpa"
        model.apiKey = "sk_cairn_screenshot_fixture"
        model.apiKeyMasked = "••••••••••xture"
        model.connectionStatus = .healthy(latencyMs: 42)

        model.settings.appearance = wantsDark ? .dark : .light

        if wantsOnboarding {
            model.needsOnboarding = true
            return
        }

        model.needsOnboarding = false
        model.hasCompletedInitialScan = true

        if let stage = demoStage {
            seedDemoStage(stage, into: model)
            return
        }

        model.library = CairnFixtures.medium
        model.runs = CairnFixtures.runs
        model.journalTail = CairnFixtures.journalTail

        let heldFixtures = Array(CairnFixtures.candidates.prefix(3))
        let pendingFixtures = Array(CairnFixtures.candidates.prefix(5))
        let confirmedAt: [Checksum: Date] = Dictionary(
            uniqueKeysWithValues: heldFixtures.enumerated().compactMap { idx, c in
                c.checksum.map {
                    (Checksum(base64: $0), Date(timeIntervalSinceNow: -TimeInterval(idx) * 86_400))
                }
            }
        )
        model.reconciliation = .init(
            deleteCandidates: pendingFixtures.map { $0.asServerAsset },
            pendingReviewCandidates: pendingFixtures.map { $0.asServerAsset },
            heldByQuarantineCandidates: heldFixtures.map { $0.asServerAsset },
            confirmedDeletedAt: confirmedAt,
            quarantineDays: 14
        )
    }

    /// Pose model state for one of the six trash/restore walkthrough
    /// stages used to record the demo. Each stage is a snapshot — the
    /// UI test that captures it lands on the right tab and snapshots.
    /// No real backend; no real PhotoKit.
    ///
    /// Reference numbers throughout: 25-photo album, 5 deleted from
    /// device, 2 of those restored on Immich. Library counts trace:
    ///
    ///   Stage 0 (initial)            — 25 / 25 / 25 / 25
    ///   Stage 1 (post-device-delete) — 20 / 20 / 25 / 25  · 5 quarantined
    ///   Stage 2 (PendingReview)      — same model, navigated
    ///   Stage 3 (post-approve trash) — 20 / 20 / 20 / 20
    ///   Stage 4 (Runs)               — same model, navigated
    ///   Stage 5 (post-restore 2)     — 20 / 20 / 22 / 22
    private static func seedDemoStage(_ stage: Int, into model: CairnAppModel) {
        let demoCandidates = Array(CairnFixtures.candidates.prefix(5))
        let trashRunId = "2026-04-29T10:00:00Z-DEMO0429"
        let restoreRunStartedAt = ISO8601DateFormatter().date(from: "2026-04-29T10:00:00Z") ?? Date()

        switch stage {
        case 0:
            // Fresh post-onboarding sync. 25 photos in the album,
            // 25 on Immich, all match. Nothing pending.
            model.library = CairnFixtures.LibrarySize(
                local: 25, indexed: 25, server: 25, matched: 25, candidates: 0
            )
            model.runs = []
            model.journalTail = []
            model.reconciliation = nil

        case 1, 2:
            // After deleting 5 from the iPhone. cairn detected via
            // PhotoKit, stamped ConfirmedDeleted, sync surfaced them
            // as held-by-quarantine. With quarantineDays: 0 (or via
            // approve-from-pending-review) they'd promote; we pose
            // them in the held bucket so the demo can also show the
            // bypass-via-approve flow on the next stage.
            model.library = CairnFixtures.LibrarySize(
                local: 20, indexed: 20, server: 25, matched: 25, candidates: 5
            )
            let confirmedAt: [Checksum: Date] = Dictionary(
                uniqueKeysWithValues: demoCandidates.enumerated().compactMap { idx, c in
                    c.checksum.map {
                        (Checksum(base64: $0), Date(timeIntervalSinceNow: -TimeInterval(idx) * 60))
                    }
                }
            )
            model.reconciliation = .init(
                deleteCandidates: [],
                pendingReviewCandidates: [],
                heldByQuarantineCandidates: demoCandidates.map(\.asServerAsset),
                confirmedDeletedAt: confirmedAt,
                quarantineDays: 14
            )
            model.quarantineCount = demoCandidates.count
            model.runs = []
            model.journalTail = []

        case 3, 4:
            // Right after the user tapped "Move to Trash" on the 5
            // quarantined items. Server count dropped, candidates
            // cleared, the trash run is now in `model.runs`.
            model.library = CairnFixtures.LibrarySize(
                local: 20, indexed: 20, server: 20, matched: 20, candidates: 0
            )
            model.reconciliation = nil
            let trashRun = CairnFixtures.RunFixture(
                id: trashRunId,
                startedAt: restoreRunStartedAt,
                durationMs: 4_120,
                trashed: 5,
                restored: 0,
                dryRun: false,
                status: .complete,
                tag: "cairn/v1/run/\(trashRunId)",
                notes: "5 trashed"
            )
            model.runs = [trashRun]
            model.runAssets = [trashRunId: demoCandidates]

        case 5:
            // After restoring 2 of the 5 via Runs → tap-run → restore.
            // Immich un-trashed those 2 → server bumped 20→22. The
            // approvePending / restore commits keep matched in
            // lockstep with server. Run shows `2 restored`.
            model.library = CairnFixtures.LibrarySize(
                local: 20, indexed: 20, server: 22, matched: 22, candidates: 0
            )
            model.reconciliation = nil
            let trashRun = CairnFixtures.RunFixture(
                id: trashRunId,
                startedAt: restoreRunStartedAt,
                durationMs: 4_120,
                trashed: 5,
                restored: 2,
                dryRun: false,
                status: .complete,
                tag: "cairn/v1/run/\(trashRunId)",
                notes: "5 trashed · 2 restored from this run"
            )
            model.runs = [trashRun]
            model.runAssets = [trashRunId: demoCandidates]

        default:
            // Out-of-range stage — fall through to the App-Store
            // fixture set so the test still produces a screenshot.
            model.library = CairnFixtures.medium
            model.runs = CairnFixtures.runs
            model.journalTail = CairnFixtures.journalTail
        }
    }
    #endif
}

#if DEBUG
private extension CairnFixtures.CandidateFixture {
    var asServerAsset: ServerAsset {
        ServerAsset(
            id: assetId ?? "fixture-\(name)",
            checksum: Checksum(base64: checksum ?? "fixture-\(name)"),
            livePhotoVideoId: isLivePair ? "livepair-\(name)" : nil,
            isTrashed: false,
            originalFileName: name,
            fileCreatedAt: nil
        )
    }
}
#endif

import UIKit
