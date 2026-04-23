import Foundation
import SwiftData
import Photos
import CairnCore
import CairnIOSCore

/// The wiring layer between concrete iOS-side store implementations and the
/// `CairnAppRoot` UI. Held by the `@main App`; exposes state through the
/// `CairnAppModel` it produces and commands through `CairnAppActions`.
///
/// In scope:
///   - Construction of every iOS-side protocol impl (`KeychainSecretStore`,
///     `SwiftDataEverSeenStore` / `…ExclusionStore` / `…ConfirmedDeletedStore` /
///     `…LocalHashStore` / `…DeferredHashStore` / `…PersistentChangeTokenStore`,
///     `UserDefaultsSettingsStore`, `PhotoKitPhotoEnumerator`, `ImmichClient`,
///     `ImmichThumbnailLoader`).
///   - The closures in `rewireActions()` that bridge `CairnAppActions` to
///     those impls.
///   - `runScheduledScan` / `runBackgroundDrain` — the entry points the
///     `BGTaskScheduler` handlers in `CairnApp.swift` call.
///
/// Out of scope:
///   - UI views (ship in `CairnIOSCore`).
///   - Reconciliation and safety-rail logic (ship in `CairnCore`).
///   - Any PhotoKit / SwiftData detail beyond what's needed to build the
///     dependency graph — keep leaks minimal.
///
/// You can read the rest of the iOS app without opening this file; you'll
/// need to edit it when adding a new `CairnAppActions` action.
@MainActor
@Observable
final class AppDependencies {

    // MARK: - Concrete impls (reference iOS-side concrete types)

    let secretStore: KeychainSecretStore
    let settingsStore: UserDefaultsSettingsStore
    let photos: PhotoKitPhotoEnumerator
    let modelContainer: ModelContainer
    let everSeenStore: SwiftDataEverSeenStore
    let exclusionStore: SwiftDataExclusionStore
    let confirmedDeletedStore: SwiftDataConfirmedDeletedStore
    let localHashStore: SwiftDataLocalHashStore
    let deferredHashStore: SwiftDataDeferredHashStore
    let tokenStore: SwiftDataPersistentChangeTokenStore
    /// Reconciler built fresh per scan. Construction is cheap (stores pass by
    /// reference); rebuilding each call picks up the latest Settings-driven
    /// size thresholds without a mutable shared-state dance. Computed
    /// property rather than stored, on purpose.
    var persistentChangeReconciler: PhotoKitPersistentChangeReconciler {
        // Size thresholds: the Settings UI edits MB for human-friendly
        // units; convert here to the bytes-per-asset the reconciler
        // wants. Settings value of `0` would be absurd (nothing would
        // hash); the slider's range clamps that out, but belt-and-
        // suspenders we guard here too.
        let limitMB = model.settings.iCloudDownloadLimitMB
        let bytesLimit: Int64? = limitMB > 0 ? Int64(limitMB) * 1024 * 1024 : nil
        // Hard ceiling — nil when the user has it disabled (default).
        let ceilingMB = model.settings.iCloudMaxEverBytesMB
        let ceilingBytes: Int64? = (ceilingMB.map { $0 > 0 } ?? false)
            ? Int64(ceilingMB!) * 1024 * 1024
            : nil

        return PhotoKitPersistentChangeReconciler(
            hashStore: localHashStore,
            confirmedDeleted: confirmedDeletedStore,
            everSeen: everSeenStore,
            tokens: tokenStore,
            deferredStore: deferredHashStore,
            maxAssets: Self.resolveTestingAssetCap(),
            maxICloudBytesPerAsset: bytesLimit,
            hardCeilingBytes: ceilingBytes,
            onHashProgress: { [weak self] done, total in
                // Hop to MainActor — model mutations must happen there,
                // and SwiftUI's @Observable triggers re-eval when the
                // published property changes.
                await MainActor.run {
                    self?.model.syncProgress = .init(hashed: done, total: total)
                }
                // Also tick the Status "Indexed" stat. LocalHashStore
                // persists inline on every successful hash, so a
                // `indexedCount()` read reflects real progress — the
                // user watches the number climb in near-real-time
                // rather than only seeing it jump at sync completion.
                if let hashStore = await self?.localHashStore {
                    let count = (try? await hashStore.indexedCount()) ?? 0
                    await MainActor.run {
                        guard let self else { return }
                        self.model.library = self.model.library.with(indexed: count)
                    }
                }
            }
        )
    }

    /// Window for the "recent mass offload" bulk-exclude bucket.
    /// When the user taps "Bulk exclude N" on the Pending Review
    /// screen, we exclude every checksum confirmed-deleted within
    /// this many seconds before now. 24 hours matches the mental
    /// model "photos I just offloaded"; bumping it risks grabbing
    /// unrelated deletions from earlier sessions.
    ///
    /// Not user-configurable. `nonisolated` so the non-MainActor
    /// closure in `rewireActions` can read it without a hop.
    nonisolated static let massOffloadRecentWindow: TimeInterval = 24 * 60 * 60

    /// Optional cap on the number of assets scanned during full enumeration.
    /// `nil` (no cap) in normal runs. Lets device testers time reconciliation
    /// against a controlled sample rather than their full camera roll.
    ///
    /// **Persistence semantics** (fixes the "cap disappears on relaunch"
    /// footgun). `CAIRN_ASSET_CAP` is only present during the launch
    /// `devicectl` initiates — any later iOS re-launch (user tap after
    /// backgrounding, OS restart, reconciler resume after the tunnel
    /// disconnected) drops the env and the cap would silently revert to
    /// uncapped. To prevent that:
    ///   - Env present with positive int → write to UserDefaults, return it.
    ///   - Env absent → fall back to the persisted UserDefaults value.
    ///   - `CAIRN_ASSET_CAP=0` (or any non-positive) → clear the persisted
    ///     value and return `nil`, i.e. explicit opt-out.
    static func resolveTestingAssetCap() -> Int? {
        let key = "CAIRN_ASSET_CAP"
        let ud = UserDefaults.standard
        if let raw = ProcessInfo.processInfo.environment[key], !raw.isEmpty {
            if let n = Int(raw), n > 0 {
                ud.set(n, forKey: key)
                return n
            }
            // "0" / "none" / non-numeric → explicit clear.
            ud.removeObject(forKey: key)
            return nil
        }
        let stored = ud.integer(forKey: key)
        return stored > 0 ? stored : nil
    }

    /// Built lazily — only after the user has supplied a server URL + API key.
    /// `nil` while we're still in onboarding.
    private(set) var immichClient: ImmichClient?

    /// Tracks the in-flight "fast server count" Task kicked off at
    /// the start of each sync. Cancelled when a new sync starts so
    /// a stale response from the previous sync can't overwrite
    /// `model.library.server` after the new sync has already
    /// populated it. Stored on the actor-isolated instance rather
    /// than as a local in `performLiveReconciliation` so
    /// back-to-back syncs share visibility.
    private var inFlightServerStatsTask: Task<Void, Never>?

    /// Companion to `immichClient` for the thumbnail request path. Kept
    /// separate so the (caching, concurrency-dedup'd) actor is not
    /// reconstructed on every request — the cache would be wiped. Rebuilt
    /// only when credentials change.
    private(set) var thumbnailLoader: ImmichThumbnailLoader?

    /// The append-only deletion journal. Lives on disk in the app's Documents
    /// directory as `deletion-journal.jsonl`; the CLI's `cairn journal show`
    /// reads the same format. JSONL is platform-portable and easy to inspect
    /// via the Files app.
    let journal: DeletionJournal

    // MARK: - Model wired into the UI

    /// The observable state object `CairnAppRoot` renders from. Mutations
    /// happen only on the MainActor; SwiftUI's `@Observable` takes care of
    /// re-rendering.
    let model: CairnAppModel

    // MARK: - Init

    /// Synchronous wiring.
    ///
    /// Constructs every store, builds the SwiftData container (disk first,
    /// in-memory fallback, fatalError if both fail), and wires the initial
    /// `CairnAppActions` so onboarding's `verifyServer` can call real
    /// closures before `bootstrap()` runs. `bootstrap()` fills in credential-
    /// dependent state (`immichClient`, `thumbnailLoader`, persisted
    /// settings) asynchronously after the window is on screen.
    init() {
        let secretStore = KeychainSecretStore()
        let settingsStore = UserDefaultsSettingsStore()
        let photos = PhotoKitPhotoEnumerator()
        // Two-tier container setup: try the on-disk path first, fall
        // back to in-memory if that fails (device out of space,
        // permissions regression, corrupt store). If BOTH fail
        // there's nothing we can functionally do — the app has no
        // persistent state at all — so crash with a diagnostic
        // `fatalError` rather than `try!` so the crash log pins the
        // root cause instead of looking like a generic unwrap crash.
        let container: ModelContainer = {
            if let disk = try? CairnSwiftDataContainer.make() {
                return disk
            }
            do {
                return try CairnSwiftDataContainer.make(inMemory: true)
            } catch {
                fatalError("cairn can't initialize a SwiftData container on disk OR in memory — \(error). The app requires at least one of these to function. If this keeps happening, check Settings → Storage for free space and reinstall cairn.")
            }
        }()

        self.secretStore = secretStore
        self.settingsStore = settingsStore
        self.photos = photos
        self.modelContainer = container
        self.everSeenStore = SwiftDataEverSeenStore(container: container)
        self.exclusionStore = SwiftDataExclusionStore(container: container)
        self.confirmedDeletedStore = SwiftDataConfirmedDeletedStore(container: container)
        self.localHashStore = SwiftDataLocalHashStore(container: container)
        self.deferredHashStore = SwiftDataDeferredHashStore(container: container)
        self.tokenStore = SwiftDataPersistentChangeTokenStore(container: container)

        let journalURL = AppDependencies.documentsDirectory()
            .appending(path: "deletion-journal.jsonl")
        self.journal = DeletionJournal(path: journalURL)

        // Build the model with placeholder defaults; bootstrap() fills in the
        // real values asynchronously after the app launches.
        let actions = AppDependencies.makePreviewActions()
        self.model = CairnAppModel(
            needsOnboarding: true,   // pessimistic until bootstrap proves otherwise
            actions: actions
        )

        // Wire the real action closures immediately, synchronously, so
        // onboarding's `verifyServer` actually hits Immich rather than
        // running the no-op preview default. Previously the first wire
        // happened inside `bootstrap()`, which is async and only fires
        // after credentials are already present — chicken-and-egg for
        // onboarding.
        rewireActions()
    }

    // MARK: - Bootstrap

    /// Async setup that runs once when `CairnApp`'s WindowGroup first
    /// appears.
    ///
    /// Reads Keychain credentials; on miss, leaves `model.needsOnboarding =
    /// true` and returns (Setup's `verifyServer` finishes the wiring by
    /// persisting credentials, rebuilding `immichClient` + `thumbnailLoader`,
    /// and calling `rewireActions()`). On hit, builds those clients, loads
    /// persisted `CairnSettings`, seeds the Status journal tail + Runs list
    /// + deferred-queue summary, and decides whether the initial-scan screen
    /// still applies.
    ///
    /// DEBUG builds honor three launch-arg / env-var hooks:
    ///   - `-CAIRN_SCREENSHOT_MODE` → fixture-only path for Fastlane
    ///     snapshot UITests, bypasses every real dependency.
    ///   - `CAIRN_DEV_SEED_URL` + `CAIRN_DEV_SEED_KEY` → auto-populate
    ///     Keychain on first launch after a reinstall (provisioning
    ///     rotations wipe Keychain). Skipped if credentials are already
    ///     present.
    ///   - `CAIRN_RESET=1` → wipe every scan-derived store so the next
    ///     sync behaves like first-install. Keychain + exclusions
    ///     untouched.
    func bootstrap() async {
        #if DEBUG
        // Screenshot mode — set by the Fastlane snapshot UITest via
        // the `-CAIRN_SCREENSHOT_MODE 1` launch arg. Skips every real
        // dependency (Keychain, PhotoKit, SwiftData, ImmichClient) and
        // populates the model with `CairnFixtures` data so screenshots
        // are deterministic and require no Immich server. Returns
        // before any of the normal credential / state logic runs.
        if ProcessInfo.processInfo.arguments.contains("-CAIRN_SCREENSHOT_MODE") {
            AppDependencies.seedFromFixtures(into: model)
            return
        }
        #endif

        // Dev-only seed from env. iOS wipes Keychain items on reinstall
        // when the provisioning profile regenerates, so each `make device`
        // kicks the user back to onboarding. The seed mechanism skips it:
        // if `CAIRN_DEV_SEED_URL` + `CAIRN_DEV_SEED_KEY` are both in the
        // environment and the Keychain is currently empty, we write them
        // in on launch. The env vars come from `iOS/.dev-secrets` via
        // `make device`'s DEVICECTL_CHILD_ forwarding. Production builds
        // leave these env vars unset, so the seed is a true no-op outside
        // the dev loop.
        #if DEBUG
        if (try? secretStore.serverURL()) == nil || (try? secretStore.apiKey()) == nil,
           let seedURL = ProcessInfo.processInfo.environment["CAIRN_DEV_SEED_URL"].flatMap(URL.init(string:)),
           let seedKey = ProcessInfo.processInfo.environment["CAIRN_DEV_SEED_KEY"],
           !seedKey.isEmpty {
            try? secretStore.setServerURL(seedURL)
            try? secretStore.setAPIKey(seedKey)
        }

        // Dev-only full reset. `CAIRN_RESET=1` at launch wipes every
        // piece of indexed state (hash cache, token, ever-seen,
        // confirmed-deleted) so the next sync runs as if on a fresh
        // install. Targeted at timing experiments — without it, each
        // `make device-run` just resumes from cached hashes and the
        // wall-clock numbers aren't comparable. Keychain + exclusions
        // are untouched.
        if ProcessInfo.processInfo.environment["CAIRN_RESET"] == "1" {
            try? await localHashStore.clear()
            try? await tokenStore.clear()
            try? await everSeenStore.clear()
            try? await confirmedDeletedStore.clear()
        }
        #endif

        // Try to read credentials from Keychain. If absent → onboarding flow.
        let url = try? secretStore.serverURL()
        let apiKey = try? secretStore.apiKey()
        guard let url, let apiKey else {
            model.needsOnboarding = true
            return
        }

        immichClient = ImmichClient(baseURL: url, apiKey: apiKey)
        thumbnailLoader = ImmichThumbnailLoader(baseURL: url, apiKey: apiKey)
        model.needsOnboarding = false
        model.serverHost = url.host() ?? url.absoluteString
        model.apiKey = apiKey
        model.apiKeyMasked = AppDependencies.mask(apiKey)
        model.settings = (try? await settingsStore.load()) ?? .defaults
        await refreshExcludedChecksums()

        // The reconciler saves a `PHPersistentChangeToken` at the end of
        // every successful full enumeration. Its presence is our durable
        // signal that "initial scan has completed at least once" — drives
        // whether `CairnAppRoot` shows the `InitialScanScreen` takeover
        // or jumps straight to the main tabs.
        let tokenExists = (try? await tokenStore.load()) != nil
        model.hasCompletedInitialScan = tokenExists

        // Log the resolved testing cap once per launch so when a
        // devicectl-disconnect causes iOS to re-launch the app later,
        // it's visible from the first line of terminal output whether
        // the persisted cap carried over (or was never set). Avoids
        // silent "wait why did it hash the full library" surprises.
        if let cap = Self.resolveTestingAssetCap() {
            print("[cairn.boot] testing asset cap in effect: \(cap)")
        } else {
            print("[cairn.boot] no asset cap — full library will be hashed")
        }

        // Seed the Status-screen journal tail from the on-disk journal
        // so a fresh app-open shows historical events rather than the
        // empty default. Sync will refresh it again after each run.
        // Fetch a larger tail than we display by default (Status
        // collapses to 8 rows; the full tail is surfaced on expand)
        // so "Show more" has meaningful content. `lastEntries(...)`
        // returns oldest-first; reverse so the UI shows newest at
        // the top — matches every other feed users interact with.
        if let recent = try? await journal.lastEntries(limit: 40) {
            model.journalTail = recent.reversed().map(CairnFixtures.JournalTailEntry.from)
        }

        // Seed the deferred-queue summary too — Status + Settings show
        // the count on arrival, without waiting for the first sync.
        await refreshDeferredQueueSummary()

        // Seed the Runs list so Status's "Recent runs" card and the
        // Runs tab have data without waiting for another trash run.
        await refreshRunsList()

        rewireActions()
    }

    // MARK: - Scheduled scan (called by BGAppRefreshTask)

    /// `BGAppRefreshTask` entry point.
    ///
    /// Replays `PHPhotoLibrary.fetchPersistentChanges` since the last saved
    /// token, translates deleted `localIdentifier`s into checksums via
    /// `LocalHashStore`, and unions them into `ConfirmedDeletedStore` with
    /// the current timestamp (starts the quarantine clock). First-run /
    /// token-expired flows fall back to a full library enumeration that
    /// rebuilds the hash cache without emitting deletions — a resync, not a
    /// positive signal.
    @discardableResult
    func runScheduledScan() async throws -> PhotoKitPersistentChangeReconciler.Result {
        try await persistentChangeReconciler.runDeletionScan()
    }

    /// `BGProcessingTask` entry point.
    ///
    /// Runs the standard scan, then drains the deferred-hash queue with the
    /// foreground soft limit disabled — this is the slot where multi-hundred-
    /// MB / multi-GB videos can safely hash (device is plugged in + on Wi-Fi
    /// per the request's `requiresNetworkConnectivity`). The hard ceiling
    /// (if the user enabled it in Settings) still applies inside the
    /// reconciler.
    @discardableResult
    func runBackgroundDrain() async throws -> (
        scan: PhotoKitPersistentChangeReconciler.Result,
        drain: PhotoKitPersistentChangeReconciler.Result
    ) {
        let reconciler = persistentChangeReconciler
        let scan = try await reconciler.runDeletionScan()
        let drain = try await reconciler.drainDeferred()
        return (scan, drain)
    }

    // MARK: - Live reconciliation (extracted so the actions closure reads
    //         linearly and errors propagate cleanly to `lastError`)

    /// Full sync pipeline: fast server-count fetch (parallel) → full
    /// server-asset list fetch (parallel) → persistent-change scan (hashes
    /// on first run / token-expired) → `ReconciliationEngine.compute` →
    /// project the result onto `model.reconciliation` / `model.library` /
    /// `model.lastScanBurstCount` → journal a `syncCompleted` event if the
    /// sync was eventful → refresh Status's journal tail and Runs list.
    ///
    /// Throws on any store/network failure; callers catch and surface to
    /// `model.lastError`.
    @MainActor
    fileprivate func performLiveReconciliation(
        client: ImmichClient,
        everSeen: SwiftDataEverSeenStore,
        exclusions: SwiftDataExclusionStore,
        confirmed: SwiftDataConfirmedDeletedStore
    ) async throws {
        let syncStart = Date()

        // Step 0: refresh the "On iPhone" + "Indexed" stats upfront so
        // the user doesn't stare at stale values while hashing ticks
        // the Indexed number. See `refreshLibrarySizeStats()`.
        await refreshLibrarySizeStats()

        // Fast server count first. `GET /api/assets/statistics` is
        // a single tiny request that returns `{images, videos,
        // total}` — orders of magnitude faster than paginating
        // every asset. Populates "On server" stat immediately so
        // the user isn't staring at 0 during the whole scan. Best-
        // effort: on failure we just skip the early populate; the
        // full fetch below still lands eventually.
        //
        // Tracked via `inFlightServerStatsTask` so a second sync
        // kicked off before the first's stats response returns
        // cancels the stale one — without this, the older Task
        // could write its response *after* the newer sync already
        // populated `model.library.server`, producing a value
        // briefly flashing backwards.
        inFlightServerStatsTask?.cancel()
        inFlightServerStatsTask = Task { [weak self] in
            guard let stats = try? await client.assetStatistics() else { return }
            // Check for cancellation after the await before we
            // commit to the model — a new sync may have started
            // while we were waiting on the network.
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                self.model.library = self.model.library.with(server: stats.total)
            }
        }

        // The FULL asset list is still needed for reconciliation
        // (checksum matching, trashed filtering). Kick it off in
        // parallel with the local scan. Unlike the statistics call
        // above, this streams every asset's metadata — can be
        // slow on libraries of thousands.
        let serverAssetsTask = Task {
            try await client.listAllAssets()
        }

        // Step 1: positive-deletion signal via persistent changes. This
        // path also hashes on first run / token-expired, populating
        // `localHashStore` as a side effect.
        let scan = try await persistentChangeReconciler.runDeletionScan()
        let burst = scan.newlyConfirmedDeleted.count

        // Step 2: reconciliation inputs + compute. `local` (the checksum
        // set) comes from `localHashStore` rather than a fresh
        // `currentChecksums()` call — the reconciler just populated it,
        // and re-hashing would double the cost of the first-sync and
        // make perf measurements misleading.
        let hashMap = try await self.localHashStore.snapshot()
        var local: Set<Checksum> = []
        local.reserveCapacity(hashMap.count)
        for (_, checksums) in hashMap {
            local.formUnion(checksums)
        }

        // Separately, the *total visible asset count* — photos in scope
        // before any hashing filtering / deferral. This is what drives
        // the "On iPhone" stat on Status, and it differs from the
        // hashed count whenever we cap (testing) or defer (iCloud
        // size-limit / timeout). Without this split, the cap-test
        // output "486 on iPhone / 486 indexed" after CAP=500 was
        // confusing — it conflated "scope" with "work done."
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
        // Await the server fetch we kicked off alongside the scan. If
        // it's already finished, this returns immediately; if still
        // in flight, we block here until it lands.
        let serverAssets = try await serverAssetsTask.value
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

        // Step 3: project into UI state.
        let serverNonTrashed = serverAssets.filter { !$0.isTrashed }.count
        let liveLibrary = CairnFixtures.LibrarySize(
            // "On iPhone" — count of photos in scope, post-cap. Reflects
            // what the user has decided to treat as their library,
            // regardless of what we've managed to hash.
            local: totalVisibleAssets,
            // "Indexed" — count of assets with a committed SHA1. Will
            // equal `local` once every in-scope asset has hashed;
            // lower when some are deferred by the iCloud size limit,
            // the per-asset timeout, or the `noHashableResources` case.
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
        // A completed reconciliation implies the reconciler either
        // (a) did a full enumeration and saved a fresh token, or
        // (b) took the incremental path, which can only run if a token
        //     was already there from a prior full enumeration.
        // Either way, the gating condition for "initial scan done" is
        // satisfied. Flip the flag so `InitialScanScreen` steps out of
        // the way and the main tabs take over.
        model.hasCompletedInitialScan = true

        // Write a `.syncCompleted` journal entry *only when the sync
        // had a meaningful result*. Without the gate, tapping "Review
        // & sync" on a caught-up library spams the journal tail with
        // identical zero-state entries that carry no diagnostic
        // value. The three signals below cover every non-trivial
        // outcome:
        //   - `didFullEnumeration` → significant hashing work ran
        //   - `changeEventsProcessed > 0` → PhotoKit reported
        //      something (an insert, update, or delete we processed)
        //   - `drainedFromQueue > 0` → a deferred item finally hashed
        // Everything else downstream (deferred counts, reconciliation
        // totals) is derived from those three — an incremental scan
        // with zero change events has nothing to hash and nothing
        // to defer, so all outcome counts are zero.
        let isEventfulSync = scan.didFullEnumeration
            || scan.changeEventsProcessed > 0
            || scan.drainedFromQueue > 0
        if isEventfulSync {
            let runId = "\(ISO8601DateFormatter().string(from: Date()))-\(UUID().uuidString.prefix(8))"
            let elapsedMs = Int(Date().timeIntervalSince(syncStart) * 1000)
            // Journal failure here is never ship-stopping for the
            // sync itself — the real sync work (hashing, confirmed-
            // deleted, reconciliation) already committed to the
            // stores above. But silently dropping the event hides
            // disk-full / permission issues the user should know
            // about, because every subsequent trash/restore will
            // hit the same failure. Surface via `lastError` on
            // catch, don't throw — sync did succeed.
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

        // Refresh the tail so Status picks up the new entry without
        // waiting for the next bootstrap. We over-fetch (40) relative
        // to the default collapsed display (8) so the "Show more"
        // toggle has history to reveal.
        if let recent = try? await journal.lastEntries(limit: 40) {
            model.journalTail = recent.reversed().map(CairnFixtures.JournalTailEntry.from)
        }

        // Refresh deferred-queue summary so Settings + Status can
        // surface "N items / X GB queued" without stale data.
        await refreshDeferredQueueSummary()

        // Pick up any run entries that landed in the journal since
        // the last refresh (aborted runs from the safety rail,
        // restores, etc). Cheap — a readAll + summarize.
        await refreshRunsList()

        // Post-sync feedback: when the reconciler came back with no
        // actionable work (no delete candidates, nothing pending), show
        // an "up to date" banner on Status. Tapping Review & Sync with
        // nothing queued would otherwise just flash the button and
        // leave the user wondering whether it worked.
        if result.deleteCandidates.isEmpty && result.pendingReviewCandidates.isEmpty {
            showStatusToast(.upToDate(indexed: hashMap.count, total: totalVisibleAssets))
        } else {
            // Any actionable sync clears a lingering stale toast.
            model.syncToast = nil
        }
    }

    /// Reload the Runs list on the model from the on-disk journal.
    /// Called at bootstrap + after every trash / restore / sync so
    /// the Status "Recent runs" card and the Runs tab reflect
    /// journal state without waiting for a full app relaunch.
    /// Sync-only pseudo-runs (no runStarted event) are filtered out
    /// by `RunFixture.from(_:)`.
    ///
    /// Also populates `model.runAssets`, a per-run asset breakdown
    /// keyed on runId. Built from the journal's `planningTrash`
    /// events — each target carries its real assetId, so the
    /// `RunDetailSheet` can fetch thumbnails via
    /// `ImmichAssetThumb` without a round-trip to Immich for the
    /// per-run list.
    @MainActor
    fileprivate func refreshRunsList() async {
        let entries = (try? await journal.readAll()) ?? []
        let summaries = JournalReader.summarize(entries)
        model.runs = summaries.compactMap(CairnFixtures.RunFixture.from)

        // Build runId → [CandidateFixture] from `planningTrash`
        // events. One run normally has exactly one planning event,
        // but if somehow there are multiple we concatenate; dedup
        // by assetId so a repeat appearance doesn't double-render.
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

    /// Refresh `library.local` (total visible PHAssets, post-cap) and
    /// `library.indexed` (assets with committed SHA1s) without
    /// requiring a full sync. Called at sync start — before hashing
    /// runs — so the "On iPhone" stat shows the right value while
    /// "Indexed" ticks up toward it. Also called at drain start for
    /// the same reason.
    ///
    /// Both reads are cheap: `PHAsset.fetchAssets` is an index query
    /// (no I/O), and `localHashStore.indexedCount()` is a SQL COUNT
    /// via the SwiftData override.
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

    /// Show a transient toast on Status for `SyncToast.autoDismissSeconds`
    /// seconds, then auto-clear. Idempotent against overlapping toasts:
    /// a later toast overwrites the current one cleanly, and a timer
    /// from an older toast won't blank out a newer one (the timer
    /// checks the current value before clearing).
    @MainActor
    fileprivate func showStatusToast(_ toast: CairnAppModel.SyncToast) {
        model.syncToast = toast
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(CairnAppModel.SyncToast.autoDismissSeconds * 1_000_000_000))
            // Only clear if the toast we set is still visible. A
            // later action may have already swapped in a different
            // toast; its own timer owns the dismissal.
            guard self?.model.syncToast == toast else { return }
            self?.model.syncToast = nil
        }
    }

    /// Read the deferred-hash store and stash a count+bytes summary
    /// on the model. Callers: bootstrap (so the first render of Status
    /// has accurate numbers without waiting for a sync) and
    /// `performLiveReconciliation` (so the count reflects the just-
    /// completed pass).
    @MainActor
    fileprivate func refreshDeferredQueueSummary() async {
        let entries = (try? await deferredHashStore.snapshot()) ?? []
        var bytes: Int64 = 0
        for entry in entries {
            if let size = entry.sizeBytes {
                bytes += size
            }
        }
        model.deferredQueue = .init(count: entries.count, totalKnownBytes: bytes)
    }

    /// Snapshot the `ExclusionStore` and push the checksum keys into
    /// `model.excludedChecksums`. Called from bootstrap and after every
    /// mutating exclude / unexclude action so RunDetailSheet's per-tile
    /// shield badge + exclude↔unexclude toggle see live state without their
    /// own round-trip.
    fileprivate func refreshExcludedChecksums() async {
        let snapshot = (try? await exclusionStore.snapshot()) ?? [:]
        let keys = Set(snapshot.keys.map(\.base64))
        await MainActor.run { self.model.excludedChecksums = keys }
    }

    /// Produce a user-readable error string for `model.lastError`.
    ///
    /// Avoids `error.localizedDescription`, which yields inscrutable
    /// Foundation messages ("The operation couldn't be completed."), by
    /// formatting known types directly. Falls back to
    /// `String(describing:)` for anything unrecognized.
    fileprivate static func describeSyncError(_ error: Swift.Error) -> String {
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

    /// Build a fresh `CairnAppActions` bundle that captures the current
    /// `immichClient` / `thumbnailLoader` / stores, and install it on
    /// `model.actions`.
    ///
    /// Called from `init` (so onboarding hits real closures rather than
    /// preview-default no-ops), from `bootstrap` (after credentials load),
    /// and from `verifyServer` (after a mid-onboarding sign-in rotates
    /// credentials). Each action closure is described inline where it
    /// lives; collectively they implement every command the UI can issue.
    private func rewireActions() {
        let secrets = self.secretStore
        let settings = self.settingsStore
        let exclusions = self.exclusionStore
        let confirmed = self.confirmedDeletedStore
        let everSeen = self.everSeenStore
        let photos = self.photos
        let journal = self.journal
        let client = self.immichClient

        let actions = CairnAppActions(
            requestSync: { [weak self] in
                guard let self else { return }
                // Kick off a sync. Resume semantics:
                //   - If `pausedSyncElapsedSeconds` is non-nil (we were
                //     paused), shift the new `syncStartedAt` backwards
                //     by that many seconds so the elapsed timer picks
                //     up continuously from where it froze.
                //   - Otherwise treat this as a fresh sync: reset
                //     progress to nil, stamp `syncStartedAt = now`.
                await MainActor.run {
                    self.model.isSyncing = true
                    self.model.lastError = nil
                    if let paused = self.model.pausedSyncElapsedSeconds {
                        self.model.syncStartedAt = Date().addingTimeInterval(-paused)
                        self.model.pausedSyncElapsedSeconds = nil
                        // Keep syncProgress as-is for resume — the
                        // onHashProgress callbacks will overwrite it
                        // as the pipeline advances.
                    } else {
                        self.model.syncProgress = nil
                        self.model.syncStartedAt = Date()
                    }
                }

                guard let client = await self.immichClient else {
                    await MainActor.run {
                        self.model.lastError = "Not signed in yet. Complete onboarding first."
                        self.model.isSyncing = false
                    }
                    return
                }

                // Ensure Photos is fully authorized before we hash anything.
                // iOS device permissions are per-install; a permission
                // granted during onboarding on this device persists, but
                // on fresh installs / revoked-perm scenarios we may need
                // to (re-)ask. If the user denies, we surface a clear
                // error and bail without touching the server.
                let photoStatus = await MainActor.run { PHPhotoLibrary.authorizationStatus(for: .readWrite) }
                let effectiveStatus: PHAuthorizationStatus
                if photoStatus == .notDetermined {
                    effectiveStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                } else {
                    effectiveStatus = photoStatus
                }
                guard effectiveStatus == .authorized else {
                    await MainActor.run {
                        self.model.lastError = "cairn needs Full Photos access to find deleted photos. Open Settings → cairn → Photos and pick “All Photos.”"
                        self.model.isSyncing = false
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
                    // Success: clear all in-flight markers.
                    await MainActor.run {
                        self.model.isSyncing = false
                        self.model.syncProgress = nil
                        self.model.syncStartedAt = nil
                        self.model.pausedSyncElapsedSeconds = nil
                    }
                } catch is CancellationError {
                    // User tapped Stop, or the parent task was dropped.
                    // Preserve `syncProgress` + freeze elapsed as
                    // `pausedSyncElapsedSeconds` so the UI shows the
                    // frozen "244 of 500 · 12s" state. Resume picks
                    // up from the cache; "Start over" wipes and
                    // restarts. No error alert — cancel is deliberate.
                    await MainActor.run {
                        let elapsed = self.model.syncStartedAt.map {
                            Date().timeIntervalSince($0)
                        } ?? 0
                        self.model.pausedSyncElapsedSeconds = max(0, elapsed)
                        self.model.syncStartedAt = nil
                        self.model.isSyncing = false
                        // NB: leave `syncProgress` untouched so the
                        // progress card stays populated.
                    }
                } catch {
                    await MainActor.run {
                        self.model.lastError = Self.describeSyncError(error)
                        self.model.isSyncing = false
                        self.model.syncProgress = nil
                        self.model.syncStartedAt = nil
                        self.model.pausedSyncElapsedSeconds = nil
                    }
                }
            },
            confirmTrash: { [weak self] in
                guard let self else { return }
                // Read from the cached reconciliation result. The sheet
                // shouldn't be invocable without a prior requestSync, but
                // tolerate that case with a silent no-op rather than a crash.
                guard let client = await self.immichClient,
                      let live = await self.model.reconciliation,
                      !live.deleteCandidates.isEmpty else { return }
                let runId = "\(ISO8601DateFormatter().string(from: Date()))-\(UUID().uuidString.prefix(8))"
                let orchestrator = TrashOrchestrator(writer: client, journal: journal)
                do {
                    _ = try await orchestrator.run(
                        runId: runId,
                        candidates: live.deleteCandidates,
                        assetsInPurview: live.deleteCandidates.count + live.pendingReviewCandidates.count,
                        dryRun: false
                    )
                    // Clear the cached candidates so a stale re-entry can't
                    // replay the run. The next requestSync produces a fresh set.
                    await MainActor.run {
                        self.model.reconciliation = nil
                    }
                    await self.refreshRunsList()
                } catch {
                    // Surface the failure to the user rather than
                    // letting the sheet close silently. Caller's
                    // `try?` would otherwise drop the error and the
                    // cached candidates get wiped regardless — next
                    // sync reconciles against unchanged server state
                    // and shows the same candidates again. Keep
                    // `reconciliation` intact so a retry is
                    // one-tap-away instead of a full rescan.
                    await MainActor.run {
                        self.model.lastError = Self.describeSyncError(error)
                    }
                    await self.refreshRunsList()   // journal may have partial events
                    throw error
                }
            },
            restore: { [weak self] assetIds, runId in
                // Reach into `self.immichClient` each invocation so
                // credential rotation (sign-out + sign-back-in)
                // doesn't leave us calling the previous server. The
                // old capture pattern snapshotted `client` at wiring
                // time, which could target a stale instance after
                // rotation. `[weak self]` prevents a retain cycle
                // while the guard surfaces the "signed out" case
                // cleanly.
                guard let self, let client = await self.immichClient else { return }
                let orch = RestoreOrchestrator(writer: client, journal: journal)
                // Empty input = restore the whole run; non-empty =
                // restore only the selected subset. The orchestrator
                // handles Live Photo pair expansion internally so a
                // still + motion-video pair is never half-restored.
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
                // Checksums are the store's primary key — base64 SHA1
                // strings pulled from `CandidateFixture.checksum`.
                // Filenames ride along for the journal event so the
                // on-disk log is human-readable.
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
                    await self?.refreshExcludedChecksums()
                } catch {
                    if let self {
                        await MainActor.run {
                            self.model.lastError = Self.describeSyncError(error)
                        }
                    }
                    throw error
                }
                _ = filenames  // reserved for future UI echo / richer journal event
            },
            unexclude: { [weak self] checksums in
                let cks = Set(checksums.map { Checksum(base64: $0) })
                do {
                    try await exclusions.remove(cks)
                    await self?.refreshExcludedChecksums()
                } catch {
                    if let self {
                        await MainActor.run {
                            self.model.lastError = Self.describeSyncError(error)
                        }
                    }
                    throw error
                }
            },
            approvePending: { [weak self] checksums in
                // Promote a specific set of held/unconfirmed candidates to
                // trash by running the TrashOrchestrator on just those
                // server assets. Quarantine is bypassed — the user is
                // explicitly saying "trash these now."
                guard let self,
                      let client = await self.immichClient,
                      let live = await self.model.reconciliation else { return }
                let wanted = Set(checksums)
                let candidates = (live.pendingReviewCandidates + live.heldByQuarantineCandidates)
                    .filter { wanted.contains($0.checksum.base64) }
                guard !candidates.isEmpty else { return }
                let runId = "\(ISO8601DateFormatter().string(from: Date()))-\(UUID().uuidString.prefix(8))"
                let orchestrator = TrashOrchestrator(writer: client, journal: journal)
                do {
                    // `assetsInPurview` is the full set of candidates
                    // that were eligible to review in this reconciliation
                    // pass — *not* just the subset the user approved.
                    // Passed through the safety rail so the percent-check
                    // math denominators match the user-visible "X% of
                    // matched" display. Approving a subset doesn't
                    // change what was in scope; it just changes what
                    // actually got trashed.
                    _ = try await orchestrator.run(
                        runId: runId,
                        candidates: candidates,
                        assetsInPurview: live.deleteCandidates.count + live.pendingReviewCandidates.count,
                        dryRun: false
                    )
                    // Drop the approved ones from the cached reconciliation so
                    // the UI updates without a full resync round trip.
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
                    }
                    await self.refreshRunsList()
                } catch {
                    // Surface the failure so the user sees a real
                    // error state instead of the sheet dismissing
                    // silently and the candidates still present on
                    // Pending Review after a "Trash" tap did nothing.
                    await MainActor.run {
                        self.model.lastError = Self.describeSyncError(error)
                    }
                    await self.refreshRunsList()
                    throw error
                }
            },
            excludePending: { [weak self] checksums in
                guard let self else { return }
                let now = Date()
                var entries: [Checksum: ExclusionMetadata] = [:]
                let cks = Set(checksums.map { Checksum(base64: $0) })
                for checksum in cks {
                    entries[checksum] = ExclusionMetadata(addedAt: now, fromRunId: nil, reason: "pending-review")
                }
                do {
                    try await exclusions.insert(entries)
                    // Un-confirm so these stop showing up as pending.
                    // The exclusion list will also protect them from
                    // future runs.
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
            bulkExcludeRecentOffload: { [weak self] in
                guard let self else { return }
                // "Recent" = everything confirmed within the window
                // defined by `massOffloadRecentWindow` (currently 24h).
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
                // Sanitize — accepts missing scheme ("immich.home.arpa"),
                // trailing slashes, whitespace; rejects non-http(s)
                // schemes and un-hostable strings. Returns a clean URL
                // that ImmichClient's `normalize` will append `/api` to.
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
                    // Successful verify ⇒ persist credentials so the
                    // next launch can bootstrap directly into the main
                    // app. A mid-onboarding crash or force-quit shouldn't
                    // make the user retype. Also rebuild the real
                    // ImmichClient + thumbnail loader on the dependencies
                    // so every action downstream of this point has working
                    // credentials.
                    if let self {
                        try? secrets.setServerURL(url)
                        try? secrets.setAPIKey(key)
                        await MainActor.run {
                            self.immichClient = ImmichClient(baseURL: url, apiKey: key)
                            self.thumbnailLoader = ImmichThumbnailLoader(baseURL: url, apiKey: key)
                            self.model.serverHost = url.host() ?? url.absoluteString
                            self.model.apiKey = key
                            self.model.apiKeyMasked = AppDependencies.mask(key)
                        }
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
                // Background refresh permission is a system-level setting; we
                // can't request it programmatically, just check whether it's
                // available. Return true if it is (lets onboarding proceed).
                await MainActor.run { UIApplication.shared.backgroundRefreshStatus == .available }
            },
            resetIndex: { [weak self] in
                guard let self else { return }
                // Wipe every piece of derived state so the next sync
                // behaves as a first-ever install:
                //   - LocalHashStore (so re-hashing happens, not skip-if-cached)
                //   - PersistentChangeTokenStore (so the incremental path
                //     doesn't kick in — forces runFullEnumeration)
                //   - EverSeenStore (so reconciliation doesn't treat
                //     assets as "previously indexed")
                //   - ConfirmedDeletedStore (quarantine clocks reset)
                // Exclusions are NOT touched — those are user-intent
                // protections, not cached state.
                //
                // Also cancel any in-flight sync so it doesn't race
                // with our deletes (a mid-sync hashStore.set on the same
                // asset we're wiping would be wasted work at best,
                // corruption at worst).
                let eh = self.everSeenStore
                let cd = self.confirmedDeletedStore
                let lh = self.localHashStore
                let dh = self.deferredHashStore
                let tk = self.tokenStore
                try? await lh.clear()
                try? await tk.clear()
                try? await eh.clear()
                try? await cd.clear()
                try? await dh.clear()
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
                let path = await self.journal.path
                try? FileManager.default.removeItem(at: path)
                await MainActor.run {
                    // Blank the Status tail + Runs list so neither
                    // keeps showing rows from the now-deleted file
                    // until the next sync repopulates the journal.
                    self.model.journalTail = []
                    self.model.runs = []
                    self.model.runAssets = [:]
                    self.showStatusToast(.journalCleared)
                }
            },
            signOut: { [weak self] in
                try? secrets.clear()
                // Drop thumbnail cache first — its bytes were fetched
                // with the now-stale key and must not leak to the next
                // user of this install.
                await self?.thumbnailLoader?.clearCache()
                await MainActor.run {
                    guard let self else { return }
                    self.immichClient = nil
                    self.thumbnailLoader = nil
                    self.model.needsOnboarding = true
                    self.model.apiKey = ""
                    self.model.apiKeyMasked = ""
                    self.model.serverHost = ""
                    // Reset the skip-flag so a fresh sign-in starts
                    // with the initial-scan screen again.
                    self.model.hasDismissedInitialScan = false
                }
            },
            rescanLibrary: { [weak self] in
                guard let self else { return }
                // Clear token + defer queue → next runDeletionScan()
                // takes the full-enumeration path and reconsiders every
                // asset against the current size settings. Ever-seen +
                // confirmed-deleted survive so reconciliation history
                // (and the quarantine clock) stay intact.
                let tk = self.tokenStore
                let dh = self.deferredHashStore
                try? await tk.clear()
                try? await dh.clear()
                await MainActor.run {
                    // Also flip `hasCompletedInitialScan` to false so
                    // the UI reverts to `InitialScanScreen` during the
                    // full-enum re-run — matches the user's mental
                    // model of "I asked for a rescan, show me progress."
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
            },
            dismissInitialScan: { [weak self] in
                guard let self else { return }
                await MainActor.run {
                    self.model.hasDismissedInitialScan = true
                }
            },
            startOverInitialScan: { [weak self] in
                guard let self else { return }
                // Wipe every piece of scan-derived state so the next
                // Start behaves as a true fresh run. Keeps exclusions
                // + credentials intact.
                try? await self.localHashStore.clear()
                try? await self.tokenStore.clear()
                try? await self.deferredHashStore.clear()
                try? await self.everSeenStore.clear()
                try? await self.confirmedDeletedStore.clear()
                await MainActor.run {
                    self.model.reconciliation = nil
                    self.model.library = .empty
                    self.model.lastScanBurstCount = 0
                    self.model.syncProgress = nil
                    self.model.pausedSyncElapsedSeconds = nil
                    self.model.syncStartedAt = nil
                    self.model.hasCompletedInitialScan = false
                    // `hasDismissedInitialScan` intentionally left as
                    // the user set it — starting over doesn't mean
                    // they want to be force-routed back to the scan
                    // screen if they'd hit Skip for now.
                }
                await self.refreshDeferredQueueSummary()
            },
            forceDrainDeferred: { [weak self] in
                guard let self else { return }
                // Treat this as a normal sync from a UI perspective —
                // same `isSyncing` + `syncProgress` plumbing, same
                // cancellation path. The difference is the reconciler
                // call: `drainDeferred()` hits the unlimited-drain
                // path (ignores soft limit, honors hard ceiling) so
                // previously-queued items actually hash.
                let photoStatus = await MainActor.run { PHPhotoLibrary.authorizationStatus(for: .readWrite) }
                guard photoStatus == .authorized else {
                    await MainActor.run {
                        self.model.lastError = "cairn needs Full Photos access to hash deferred assets."
                    }
                    return
                }
                await MainActor.run {
                    self.model.isSyncing = true
                    self.model.lastError = nil
                    self.model.syncProgress = nil
                    self.model.syncStartedAt = Date()
                    self.model.pausedSyncElapsedSeconds = nil
                }
                // Refresh stats upfront so "On iPhone" is accurate
                // while the drain ticks "Indexed" toward it.
                await self.refreshLibrarySizeStats()
                do {
                    _ = try await self.persistentChangeReconciler.drainDeferred()
                    await MainActor.run {
                        self.model.isSyncing = false
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
                    }
                    await self.refreshDeferredQueueSummary()
                } catch {
                    await MainActor.run {
                        self.model.lastError = Self.describeSyncError(error)
                        self.model.isSyncing = false
                        self.model.syncProgress = nil
                        self.model.syncStartedAt = nil
                    }
                    await self.refreshDeferredQueueSummary()
                }
            },
            replayOnboarding: { [weak self] in
                // Dev-only convenience: re-enter the SetupScreen flow
                // without losing credentials. Pull URL + API key out
                // of Keychain, pre-fill the bindings so the server
                // and key fields show the existing values (SetupScreen
                // uses `$model.serverHost` / `$model.apiKey` as the
                // TextField bindings), then flip the onboarding route.
                // Verify at the end of the wizard re-persists the
                // same values harmlessly.
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

        // Swap the new bundle in. Earlier revisions tried to reconstruct
        // the model and dance around `actions` being `let`, which silently
        // no-op'd — onboarding's verifyServer ran the preview-default
        // no-op, every "successful" verify was vacuous. `actions` is now
        // a `var` on the model so we just assign.
        self.model.actions = actions
    }

    // MARK: - Helpers

    /// Absolute URL of the app's Documents directory. Force-unwrap is safe:
    /// every sandboxed iOS app is guaranteed a Documents dir at launch.
    private static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    /// Mask an API key for display, showing the last 4 characters. Used for
    /// the Settings "API key" row so a user can verify which key is
    /// installed without exposing the full secret.
    private static func mask(_ key: String) -> String {
        let tail = key.suffix(4)
        return String(repeating: "•", count: 10) + tail
    }

    /// All-no-op closures for the initial `CairnAppActions`, used before
    /// `rewireActions()` runs the first time. Immediately replaced in
    /// `init`; kept as a named helper so the intent of the first `model`
    /// assignment is obvious.
    private static func makePreviewActions() -> CairnAppActions {
        CairnAppActions()   // all defaults
    }

    #if DEBUG
    /// Populate the model with `CairnFixtures` data so screenshot UITests
    /// render every tab without any real dependencies. Invoked only when
    /// the `-CAIRN_SCREENSHOT_MODE` launch arg is present.
    ///
    /// Paired with `-CAIRN_SCREENSHOT_ONBOARDING` to land on the Setup
    /// wizard instead of the main tabs — used by the onboarding
    /// screenshot test.
    @MainActor
    static func seedFromFixtures(into model: CairnAppModel) {
        let args = ProcessInfo.processInfo.arguments
        let wantsOnboarding = args.contains("-CAIRN_SCREENSHOT_ONBOARDING")
        let wantsDark = args.contains("-CAIRN_SCREENSHOT_DARK")

        // Swap every action for a no-op. Without this, the `.task`
        // auto-sync on main tabs fires `requestSync`, which tries to
        // use an ImmichClient we never built, writes lastError, and
        // pops a "Not signed in" alert over the screenshot. All-no-op
        // actions also mean accidental taps on a "Sign out" /
        // "Reset index" / "Review & sync" button during the capture
        // pass can't break the fixture state.
        model.actions = CairnAppActions()

        // And suppress the auto-sync task explicitly. Belt + suspenders
        // — even if a future action accidentally becomes non-noop,
        // this flag ensures the initial task-block exits early.
        model.didAutoSyncThisSession = true

        // Shared state regardless of landing screen.
        model.serverHost = "photos.home.arpa"
        model.apiKey = "sk_cairn_screenshot_fixture"
        model.apiKeyMasked = "••••••••••xture"
        model.connectionStatus = .healthy(latencyMs: 42)

        // Appearance override is already a first-class setting on
        // `CairnSettings`, so dark-mode screenshot capture just means
        // seeding it here; `CairnAppRoot` reads `settings.appearance`
        // and applies `.preferredColorScheme` at the root.
        model.settings.appearance = wantsDark ? .dark : .light

        if wantsOnboarding {
            // Onboarding path — leave needsOnboarding true and skip
            // populating the main-app surface. The Setup wizard
            // reads only `serverHost` / `apiKey` bindings; everything
            // else is onboarding-internal state.
            model.needsOnboarding = true
            return
        }

        // Main-app path.
        model.needsOnboarding = false
        model.hasCompletedInitialScan = true
        model.library = CairnFixtures.medium
        model.runs = CairnFixtures.runs
        model.journalTail = CairnFixtures.journalTail

        // Surface enough pending-review items for the Pending Review
        // screen to render with countdowns + the mass-offload
        // banner's threshold check.
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
    /// Minimal `ServerAsset` projection for screenshot fixtures.
    /// `checksum` falls back to a stable derived value when the
    /// fixture row was hand-authored without one; the screenshot
    /// pipeline never reconciles against a real server so the
    /// value just has to be deterministic.
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

import UIKit   // imported only for `UIApplication.shared.backgroundRefreshStatus`
