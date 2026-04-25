import Foundation
import SwiftData
import Photos
import CairnCore
import CairnIOSCore

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

    // MARK: - Per-server stores (nil until activateServer runs)

    private(set) var currentPartitionKey: ServerPartitionKey?
    private(set) var serverContainer: ModelContainer?
    private(set) var everSeenStore: SwiftDataEverSeenStore?
    private(set) var exclusionStore: SwiftDataExclusionStore?
    private(set) var confirmedDeletedStore: SwiftDataConfirmedDeletedStore?
    private(set) var tokenStore: SwiftDataPersistentChangeTokenStore?
    private(set) var thumbnailStore: SwiftDataThumbnailStore?
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

        return PhotoKitPersistentChangeReconciler(
            hashStore: localHash,
            confirmedDeleted: confirmed,
            everSeen: everSeen,
            tokens: tokens,
            deferredStore: deferredHashStore,
            maxAssets: Self.resolveTestingAssetCap(),
            maxICloudBytesPerAsset: bytesLimit,
            hardCeilingBytes: ceilingBytes,
            onHashProgress: { [weak self] done, total, newChecksums in
                let (hashStore, serverSet) = await MainActor.run {
                    (self?.localHashStore, self?.serverChecksumSet)
                }
                guard let hashStore else {
                    await MainActor.run { self?.model.syncProgress = .init(hashed: done, total: total) }
                    return
                }
                let indexed = (try? await hashStore.indexedCount()) ?? 0
                let batchMatched: Int = {
                    guard let serverSet else { return 0 }
                    return newChecksums.filter { serverSet.contains($0) }.count
                }()
                await MainActor.run {
                    guard let self else { return }
                    self.model.syncProgress = .init(hashed: done, total: total)
                    let prevMatched = self.model.library.matched
                    self.model.library = self.model.library
                        .with(indexed: indexed, matched: prevMatched + batchMatched)
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

        let actions = AppDependencies.makePreviewActions()
        self.model = CairnAppModel(
            needsOnboarding: true,
            actions: actions
        )

        rewireActions()
    }

    // MARK: - Server activation

    func activateServer(url: URL, apiKey: String) throws {
        let key = ServerPartitionKey(from: url)
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
        self.tokenStore = SwiftDataPersistentChangeTokenStore(container: container)
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
            return
        }
        #endif

        #if DEBUG
        if (try? secretStore.serverURL()) == nil || (try? secretStore.apiKey()) == nil,
           let seedURL = ProcessInfo.processInfo.environment["CAIRN_DEV_SEED_URL"].flatMap(URL.init(string:)),
           let seedKey = ProcessInfo.processInfo.environment["CAIRN_DEV_SEED_KEY"],
           !seedKey.isEmpty {
            try? secretStore.setServerURL(seedURL)
            try? secretStore.setAPIKey(seedKey)
        }
        #endif

        let url = try? secretStore.serverURL()
        let apiKey = try? secretStore.apiKey()
        guard let url, let apiKey else {
            model.needsOnboarding = true
            return
        }

        Self.migrateFromLegacyIfNeeded(serverURL: url)
        try? activateServer(url: url, apiKey: apiKey)

        #if DEBUG
        if ProcessInfo.processInfo.environment["CAIRN_RESET"] == "1" {
            try? await localHashStore.clear()
            try? await tokenStore?.clear()
            try? await everSeenStore?.clear()
            try? await confirmedDeletedStore?.clear()
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
                print("[cairn.boot] server healthy: ping=\(pong), \(latencyMs)ms")
                model.connectionStatus = .healthy(latencyMs: latencyMs)
                model.degraded = .none
            } catch {
                print("[cairn.boot] ping failed: \(error)")
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
                    print("[cairn.boot] missing permissions: \(missing.joined(separator: ", "))")
                }
            }
        }

        await refreshExcludedChecksums()
        await refreshQuarantineCount()

        let tokenExists = (try? await tokenStore?.load()) != nil
        model.hasCompletedInitialScan = tokenExists

        await refreshLibrarySizeStats()

        if let cap = Self.resolveTestingAssetCap() {
            print("[cairn.boot] testing asset cap in effect: \(cap)")
        } else {
            print("[cairn.boot] no asset cap — full library will be hashed")
        }

        if let journal, let recent = try? await journal.lastEntries(limit: 40) {
            model.journalTail = recent.reversed().map(CairnFixtures.JournalTailEntry.from)
        }

        await refreshDeferredQueueSummary()
        await refreshRunsList()

        rewireActions()
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
            let cached = (try? await hashStoreRef.snapshot()) ?? [:]
            var localChecksums = Set<Checksum>()
            localChecksums.reserveCapacity(cached.count)
            for (_, cs) in cached { localChecksums.formUnion(cs) }
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
        let scan = try await reconciler.runDeletionScan(skipDrain: true)
        let burst = scan.newlyConfirmedDeleted.count

        try Task.checkCancellation()
        model.syncPhase = .fetchingServer
        let hashMap = try await self.localHashStore.snapshot()
        var local: Set<Checksum> = []
        local.reserveCapacity(hashMap.count)
        for (_, checksums) in hashMap {
            local.formUnion(checksums)
        }

        let visibleFetchOptions = PHFetchOptions()
        visibleFetchOptions.includeHiddenAssets = false
        visibleFetchOptions.includeAssetSourceTypes = [.typeUserLibrary]
        let visibleFetch = PHAsset.fetchAssets(with: visibleFetchOptions)
        var totalVisibleAssets = visibleFetch.count
        if let cap = Self.resolveTestingAssetCap(), totalVisibleAssets > cap {
            totalVisibleAssets = cap
        }

        let everSeenSet = try await everSeen.snapshot()
        let exclusionSet = Set(try await exclusions.snapshot().keys)
        let confirmedMap = try await confirmed.snapshot()
        let serverAssets = try await serverAssetsTask.value

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
        let result = ReconciliationEngine.compute(.init(
            serverAssets: serverAssets,
            currentLocalChecksums: local,
            everSeenChecksums: everSeenSet,
            excludedChecksums: exclusionSet,
            confirmedDeletedAt: confirmedMap,
            now: Date(),
            quarantineDays: settings.quarantineDays,
            strictness: settings.deletionStrictness
        ))

        let serverNonTrashed = serverAssets.filter { !$0.isTrashed }.count
        let liveLibrary = CairnFixtures.LibrarySize(
            local: totalVisibleAssets,
            indexed: hashMap.count,
            server: serverNonTrashed,
            matched: result.assetsInEverSeen,
            candidates: result.deleteCandidates.count
        )
        model.reconciliation = .init(
            deleteCandidates: result.deleteCandidates,
            pendingReviewCandidates: result.pendingReviewCandidates,
            heldByQuarantineCandidates: result.heldByQuarantineCandidates,
            confirmedDeletedAt: confirmedMap,
            quarantineDays: settings.quarantineDays
        )
        model.library = liveLibrary
        model.lastScanBurstCount = burst
        model.hasCompletedInitialScan = true

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
                        indexed: hashMap.count,
                        candidates: result.deleteCandidates.count,
                        pendingReview: result.pendingReviewCandidates.count,
                        deferredLarge: scan.deferredLarge,
                        deferredLargeBytes: scan.deferredLargeBytes,
                        deferredTimeout: scan.deferredTimeout,
                        elapsedMs: elapsedMs
                    )
                ))
            } catch {
                model.lastError = "Couldn't write the sync event to the journal — \(Self.describeSyncError(error)). Your sync completed, but the forensic log didn't."
            }
        }

        if let journal, let recent = try? await journal.lastEntries(limit: 40) {
            model.journalTail = recent.reversed().map(CairnFixtures.JournalTailEntry.from)
        }

        await refreshDeferredQueueSummary()
        await refreshRunsList()
        await refreshQuarantineCount()

        if result.deleteCandidates.isEmpty && result.pendingReviewCandidates.isEmpty {
            showStatusToast(.upToDate(indexed: hashMap.count, total: totalVisibleAssets))
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

    @MainActor
    fileprivate func refreshRunsList() async {
        guard let journal else {
            model.runs = []
            model.runAssets = [:]
            return
        }
        let entries = (try? await journal.readAll()) ?? []
        let summaries = JournalReader.summarize(entries)
        model.runs = summaries.compactMap(CairnFixtures.RunFixture.from)

        var perRun: [String: [CairnFixtures.CandidateFixture]] = [:]
        for entry in entries {
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
        let opts = PHFetchOptions()
        opts.includeHiddenAssets = false
        opts.includeAssetSourceTypes = [.typeUserLibrary]
        let fetch = PHAsset.fetchAssets(with: opts)
        var totalVisible = fetch.count
        if let cap = Self.resolveTestingAssetCap(), totalVisible > cap {
            totalVisible = cap
        }
        let indexed = (try? await self.localHashStore.indexedCount()) ?? 0
        model.library = model.library.with(local: totalVisible, indexed: indexed)
    }

    @MainActor
    fileprivate func showStatusToast(_ toast: CairnAppModel.SyncToast) {
        model.syncToast = toast
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(CairnAppModel.SyncToast.autoDismissSeconds * 1_000_000_000))
            guard self?.model.syncToast == toast else { return }
            self?.model.syncToast = nil
        }
    }

    @MainActor
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
                guard effectiveStatus == .authorized else {
                    await MainActor.run {
                        self.model.lastError = "cairn needs Full Photos access to find deleted photos. Open Settings \u{2192} cairn \u{2192} Photos and pick All Photos."
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
                    }
                } catch {
                    let degraded = Self.degradedState(for: error)
                    let desc = Self.describeSyncError(error)
                    print("[cairn.sync] requestSync failed: \(desc)")
                    await MainActor.run {
                        self.model.lastError = desc
                        self.model.isSyncing = false
                        self.model.syncPhase = .idle
                        self.model.syncProgress = nil
                        self.model.syncStartedAt = nil
                        self.model.pausedSyncElapsedSeconds = nil
                        if let degraded { self.model.degraded = degraded }
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
                            self.model.library = current.with(server: max(0, current.server - trashedCount))
                        }
                    }
                    await self.refreshRunsList()
                } catch {
                    await MainActor.run {
                        self.model.lastError = Self.describeSyncError(error)
                    }
                    await self.refreshRunsList()
                    throw error
                }
            },
            restore: { [weak self] assetIds, runId in
                guard let self,
                      let client = await self.immichClient,
                      let journal = await self.journal else { return }
                let orch = RestoreOrchestrator(writer: client, journal: journal)
                let scope: Set<String>? = assetIds.isEmpty ? nil : Set(assetIds)
                do {
                    _ = try await orch.restore(fromRunId: runId, assetIds: scope)
                    await self.refreshRunsList()
                } catch {
                    await MainActor.run {
                        self.model.lastError = Self.describeSyncError(error)
                    }
                    await self.refreshRunsList()
                    throw error
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
                } catch {
                    await MainActor.run {
                        self.model.lastError = Self.describeSyncError(error)
                    }
                    throw error
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
                    throw error
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
                    await MainActor.run {
                        guard let existing = self.model.reconciliation else { return }
                        self.model.reconciliation = .init(
                            deleteCandidates: existing.deleteCandidates,
                            pendingReviewCandidates: existing.pendingReviewCandidates.filter { !wanted.contains($0.checksum.base64) },
                            heldByQuarantineCandidates: existing.heldByQuarantineCandidates.filter { !wanted.contains($0.checksum.base64) },
                            confirmedDeletedAt: existing.confirmedDeletedAt,
                            quarantineDays: existing.quarantineDays,
                            computedAt: existing.computedAt
                        )
                        if trashedCount > 0 {
                            let current = self.model.library
                            self.model.library = current.with(server: max(0, current.server - trashedCount))
                        }
                    }
                    await self.refreshRunsList()
                } catch {
                    await MainActor.run {
                        self.model.lastError = Self.describeSyncError(error)
                    }
                    await self.refreshRunsList()
                    throw error
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
                    await MainActor.run {
                        guard let existing = self.model.reconciliation else { return }
                        self.model.reconciliation = .init(
                            deleteCandidates: existing.deleteCandidates,
                            pendingReviewCandidates: existing.pendingReviewCandidates.filter { !cks.contains($0.checksum) },
                            heldByQuarantineCandidates: existing.heldByQuarantineCandidates.filter { !cks.contains($0.checksum) },
                            confirmedDeletedAt: existing.confirmedDeletedAt.filter { !cks.contains($0.key) },
                            quarantineDays: existing.quarantineDays,
                            computedAt: existing.computedAt
                        )
                    }
                } catch {
                    await MainActor.run {
                        self.model.lastError = Self.describeSyncError(error)
                    }
                    throw error
                }
            },
            dismissPending: { [weak self] checksums in
                guard let self,
                      let confirmed = await self.confirmedDeletedStore,
                      let everSeen = await self.everSeenStore else { return }
                let cks = Set(checksums.map { Checksum(base64: $0) })
                do {
                    try await confirmed.remove(cks)
                    try await everSeen.remove(cks)
                    await MainActor.run {
                        guard let existing = self.model.reconciliation else { return }
                        self.model.reconciliation = .init(
                            deleteCandidates: existing.deleteCandidates,
                            pendingReviewCandidates: existing.pendingReviewCandidates.filter { !cks.contains($0.checksum) },
                            heldByQuarantineCandidates: existing.heldByQuarantineCandidates.filter { !cks.contains($0.checksum) },
                            confirmedDeletedAt: existing.confirmedDeletedAt.filter { !cks.contains($0.key) },
                            quarantineDays: existing.quarantineDays,
                            computedAt: existing.computedAt
                        )
                    }
                    await self.refreshQuarantineCount()
                } catch {
                    await MainActor.run {
                        self.model.lastError = Self.describeSyncError(error)
                    }
                    throw error
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
                    let existingCount = try await everSeen.snapshot().count
                    try await everSeen.union(newChecksums)
                    let afterCount = try await everSeen.snapshot().count
                    totalEverSeenAdded += afterCount - existingCount

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
                    await MainActor.run {
                        guard let existing = self.model.reconciliation else { return }
                        self.model.reconciliation = .init(
                            deleteCandidates: existing.deleteCandidates,
                            pendingReviewCandidates: existing.pendingReviewCandidates.filter { !cks.contains($0.checksum) },
                            heldByQuarantineCandidates: existing.heldByQuarantineCandidates.filter { !cks.contains($0.checksum) },
                            confirmedDeletedAt: existing.confirmedDeletedAt.filter { !cks.contains($0.key) },
                            quarantineDays: existing.quarantineDays,
                            computedAt: existing.computedAt
                        )
                        self.model.lastScanBurstCount = 0
                    }
                } catch {
                    await MainActor.run {
                        self.model.lastError = Self.describeSyncError(error)
                    }
                    throw error
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
                    if let self {
                        try? secrets.setServerURL(url)
                        try? secrets.setAPIKey(key)
                        try? await MainActor.run {
                            try self.activateServer(url: url, apiKey: key)
                        }
                        let serverCount = assets.filter { !$0.isTrashed }.count
                        await MainActor.run {
                            self.model.serverHost = url.host() ?? url.absoluteString
                            self.model.serverURL = url
                            self.model.apiKey = key
                            self.model.apiKeyMasked = AppDependencies.mask(key)
                            self.model.library = self.model.library.with(server: serverCount)
                        }

                        if let tokenStore = await self.tokenStore {
                            let tokenExists = (try? await tokenStore.load()) != nil
                            await MainActor.run { self.model.hasCompletedInitialScan = tokenExists }
                        }
                        await self.refreshExcludedChecksums()

                        await MainActor.run { self.rewireActions() }
                    }
                    return SetupScreen.ServerVerifyResult(success: true, assetCount: assets.count, errorMessage: nil)
                } catch {
                    return SetupScreen.ServerVerifyResult(success: false, assetCount: nil, errorMessage: String(describing: error))
                }
            },
            requestPhotosAccess: {
                let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                return status == .authorized
            },
            requestBackgroundRefresh: {
                await MainActor.run { UIApplication.shared.backgroundRefreshStatus == .available }
            },
            resetIndex: { [weak self] in
                guard let self else { return }
                let (lh, dh, eh, cd, tk) = await MainActor.run {
                    (self.localHashStore, self.deferredHashStore, self.everSeenStore, self.confirmedDeletedStore, self.tokenStore)
                }
                try? await lh.clear()
                try? await dh.clear()
                if let eh { try? await eh.clear() }
                if let cd { try? await cd.clear() }
                if let tk { try? await tk.clear() }
                await MainActor.run {
                    self.model.reconciliation = nil
                    self.model.library = .empty
                    self.model.lastScanBurstCount = 0
                    self.model.syncProgress = nil
                    self.model.hasCompletedInitialScan = false
                    self.model.didAutoSyncThisSession = false
                    self.model.deferredQueue = .empty
                    self.model.journalTail = []
                    self.model.runs = []
                    self.model.runAssets = [:]
                    self.showStatusToast(.indexReset)
                }
            },
            clearJournal: { [weak self] in
                guard let self else { return }
                let journal = await MainActor.run { self.journal }
                if let journal {
                    let path = await journal.path
                    try? FileManager.default.removeItem(at: path)
                }
                await MainActor.run {
                    self.model.journalTail = []
                    self.model.runs = []
                    self.model.runAssets = [:]
                    self.showStatusToast(.journalCleared)
                }
            },
            signOut: { [weak self] in
                try? secrets.clear()
                await self?.thumbnailLoader?.clearCache()
                await MainActor.run {
                    guard let self else { return }
                    self.immichClient = nil
                    self.thumbnailLoader = nil
                    self.currentPartitionKey = nil
                    self.serverContainer = nil
                    self.everSeenStore = nil
                    self.exclusionStore = nil
                    self.confirmedDeletedStore = nil
                    self.tokenStore = nil
                    self.thumbnailStore = nil
                    self.journal = nil
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
                    self.model.hasCompletedInitialScan = false
                    self.model.excludedChecksums = []
                }
            },
            rescanLibrary: { [weak self] in
                guard let self else { return }
                let (dh, tk) = await MainActor.run { (self.deferredHashStore, self.tokenStore) }
                try? await dh.clear()
                if let tk { try? await tk.clear() }
                await MainActor.run {
                    self.model.hasCompletedInitialScan = false
                    self.model.reconciliation = nil
                    self.model.syncProgress = nil
                    self.model.deferredQueue = .empty
                    self.showStatusToast(.rescanQueued)
                }
            },
            persistSettings: { [weak self] settings in
                guard let self else { return }
                try? await self.settingsStore.save(settings)
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
                let (lh, dh, tk, eh, cd) = await MainActor.run {
                    (self.localHashStore, self.deferredHashStore, self.tokenStore, self.everSeenStore, self.confirmedDeletedStore)
                }
                try? await lh.clear()
                try? await dh.clear()
                if let tk { try? await tk.clear() }
                if let eh { try? await eh.clear() }
                if let cd { try? await cd.clear() }
                await MainActor.run {
                    self.model.reconciliation = nil
                    self.model.library = .empty
                    self.model.lastScanBurstCount = 0
                    self.model.syncProgress = nil
                    self.model.pausedSyncElapsedSeconds = nil
                    self.model.syncStartedAt = nil
                    self.model.hasCompletedInitialScan = false
                }
                await self.refreshDeferredQueueSummary()
            },
            forceDrainDeferred: { [weak self] in
                guard let self else { return }
                let photoStatus = await MainActor.run { PHPhotoLibrary.authorizationStatus(for: .readWrite) }
                guard photoStatus == .authorized else {
                    await MainActor.run {
                        self.model.lastError = "cairn needs Full Photos access to hash deferred assets."
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
            }
        )

        self.model.actions = actions
    }

    // MARK: - Helpers

    private static func documentsDirectory() -> URL {
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
