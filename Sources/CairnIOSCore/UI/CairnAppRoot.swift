import SwiftUI
import CairnCore

/// The assembled cairn iOS app — top-level navigation, sheet presentation,
/// theme application, setup-vs-main routing.
///
/// Designed so the Xcode project's `@main App` is essentially a 20-line
/// shim that:
///   1. Instantiates concrete iOS-side store impls (Keychain, SwiftData,
///      PhotoKit, ImmichClient).
///   2. Bridges them into a `CairnAppModel` + `CairnAppActions` bundle.
///   3. Returns `CairnAppRoot(model:)` from its scene body.
///
/// Everything that can be tested or previewed without an iOS app target
/// lives here. Code-signing, Info.plist entitlements, BGTaskScheduler
/// registration, and PhotoKit permission prompts stay in the app target —
/// they fundamentally need the app context.
public struct CairnAppRoot: View {

    @Bindable public var model: CairnAppModel
    public let palette: CairnPalette

    /// Tracks the in-flight sync `Task` so the UI can cancel it. The
    /// reconciler's hashing loop checks `Task.isCancelled` between
    /// assets; hashes already computed are persisted to `LocalHashStore`
    /// inline, so the next sync resumes rather than restarts. `nil` when
    /// no sync is running.
    @State private var activeSyncTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: CairnAppModel, palette: CairnPalette = .defaults) {
        self.model = model
        self.palette = palette
    }

    public var body: some View {
        Group {
            if model.needsOnboarding {
                onboarding
            } else if !model.hasCompletedInitialScan && !model.hasDismissedInitialScan {
                // First-run path: hashing the whole library is substantial
                // work and the main tabs would show misleading zeroes
                // until it finishes. A dedicated screen makes the state
                // visible, explains the foreground-only constraint, and
                // gives the user cancel/resume controls. The screen is
                // dismissible ("Skip for now") — users who dismiss land
                // on the main tabs and get a persistent Status banner
                // pointing back here until the scan actually runs.
                initialScanRoute
            } else if model.settingsRoute == .excluded {
                excludedSubRoute
            } else {
                mainTabs
            }
        }
        // Apply the user's appearance override first so `cairnTheme`
        // below resolves tokens against the overridden scheme (not the
        // system one). `nil` passes through to SwiftUI's default
        // (follow system).
        .preferredColorScheme(appearanceOverrideScheme(model.settings.appearance))
        .cairnTheme(palette)
        .animation(reduceMotion ? .none : .snappy(duration: 0.18), value: model.needsOnboarding)
        .animation(reduceMotion ? .none : .snappy(duration: 0.18), value: model.hasCompletedInitialScan)
        .animation(reduceMotion ? .none : .snappy(duration: 0.18), value: model.settingsRoute)
        .sheet(item: Binding(
            get: { model.presentedSheet },
            set: { model.presentedSheet = $0 }
        )) { sheet in
            sheetContent(for: sheet)
        }
        // Error surface: anything written to `model.lastError` pops here.
        // Without this, failed syncs would silently eat themselves (Photos
        // permission denied, API key rejected, network down) and the user
        // would see a "tap does nothing" interaction with no feedback.
        .alert(
            "Couldn't finish",
            isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.lastError = nil } }
            ),
            presenting: model.lastError
        ) { _ in
            Button("OK", role: .cancel) { model.lastError = nil }
        } message: { message in
            Text(message)
        }
        // Persist every settings mutation. No explicit save UI — each
        // slider / toggle commit flows straight to disk. Debouncing
        // happens naturally because the store is atomic-write-per-save
        // and SwiftUI coalesces binding updates to one per frame.
        .onChange(of: model.settings) { _, newValue in
            Task { await model.actions.persistSettings(newValue) }
        }
    }

    // MARK: - Appearance override

    /// Translate `AppearanceOverride` into the `ColorScheme?` SwiftUI's
    /// `.preferredColorScheme` wants. `.system` → `nil` (follow OS).
    private func appearanceOverrideScheme(_ override: AppearanceOverride) -> ColorScheme? {
        switch override {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// Total "user action required" count: eligible-to-trash plus
    /// pending-review. `heldByQuarantineCandidates` is already a
    /// subset of `pendingReviewCandidates`, so adding it again
    /// would double-count held items. Used to gate the Status
    /// backlog-alert banner.
    private var backlogCount: Int {
        guard let r = model.reconciliation else { return 0 }
        return r.deleteCandidates.count + r.pendingReviewCandidates.count
    }

    // MARK: - Onboarding

    private var onboarding: some View {
        SetupScreen(
            serverUrl: $model.serverHost,
            apiKey: $model.apiKey,
            settings: $model.settings,
            onVerifyServer: { url, key in
                await model.actions.verifyServer(url, key)
            },
            onRequestPhotosAccess: {
                await model.actions.requestPhotosAccess()
            },
            onRequestBackgroundRefresh: {
                await model.actions.requestBackgroundRefresh()
            },
            onComplete: {
                // Host is responsible for actually persisting the URL/key/settings.
                // We just flip the route — the next render shows the initial
                // scan screen (or main tabs if the scan has already happened).
                model.needsOnboarding = false
            }
        )
    }

    // MARK: - Settings sub-route

    private var excludedSubRoute: some View {
        ExcludedScreen(
            entries: model.excludedEntries,
            onBack: { model.settingsRoute = .root },
            onUnexclude: { filenames in
                Task { @MainActor in
                    try? await model.actions.unexclude(filenames)
                    // Optimistically remove from the local list — the host
                    // will reconcile on next refresh.
                    model.excludedEntries.removeAll { filenames.contains($0.filename) }
                }
            }
        )
    }

    // MARK: - Initial scan route

    private var initialScanRoute: some View {
        InitialScanScreen(
            total: model.syncProgress?.total ?? model.library.local,
            hashed: model.syncProgress?.hashed ?? 0,
            isActive: model.isSyncing,
            startedAt: model.syncStartedAt,
            pausedElapsed: model.pausedSyncElapsedSeconds,
            settings: $model.settings,
            onStart: { startTrackedSync() },
            onCancel: { cancelActiveSync() },
            onStartOver: {
                Task {
                    await model.actions.startOverInitialScan()
                }
            },
            onDismiss: {
                Task {
                    await model.actions.dismissInitialScan()
                }
            }
        )
        // No auto-start. The scan is user-initiated so first-launch
        // users can review Settings — especially the iCloud download
        // limits — before committing to a full hash pass.
    }

    // MARK: - Main tabs

    private var mainTabs: some View {
        VStack(spacing: 0) {
            currentTab
            CairnTabBar(active: $model.activeTab)
                // Keep the tab bar pinned to the bottom of the
                // screen when the decimal pad pops up for an
                // editable numeric field in Settings. Without
                // this, iOS's keyboard safe-area pushes the tab
                // bar up and the keyboard-toolbar Done button
                // lands right on top of the Settings tab icon —
                // visible in the report screenshot. Matches the
                // standard iOS idiom where keyboards cover UI
                // chrome while editing.
                .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .task {
            // Auto-kick the first sync when main tabs first appear so
            // library/run data replaces the empty defaults. Only fires
            // when the initial scan has already completed — for a
            // user who hit "Skip for now" on the first-run screen,
            // landing on main tabs should NOT silently start the very
            // scan they just declined. The Status banner guides them
            // back to the scan screen when they're ready.
            guard model.hasCompletedInitialScan,
                  !model.didAutoSyncThisSession
            else { return }
            model.didAutoSyncThisSession = true
            startTrackedSync()
        }
    }

    /// Spawn `requestSync` as a tracked Task so the UI can cancel it.
    /// Any prior in-flight sync is cancelled first — the Review & sync
    /// button is disabled while syncing, so in practice this just
    /// guards the auto-sync vs manual-sync race. `onComplete` fires
    /// after the sync finishes (success, error, or cancel) on MainActor.
    private func startTrackedSync(onComplete: @escaping @MainActor () -> Void = {}) {
        activeSyncTask?.cancel()
        let task = Task { @MainActor in
            try? await model.actions.requestSync()
            onComplete()
        }
        activeSyncTask = task
    }

    private func cancelActiveSync() {
        activeSyncTask?.cancel()
    }

    @ViewBuilder
    private var currentTab: some View {
        switch model.activeTab.id {
        case "status":
            StatusScreen(
                appState: model.appState,
                degraded: model.degraded,
                library: model.library,
                runs: model.runs,
                journalTail: model.journalTail,
                serverHost: model.serverHost,
                maxDeletePercent: model.settings.maxDeletePercent,
                // `pendingReviewCandidates` already *includes*
                // `heldByQuarantineCandidates` — the engine
                // populates the held array as a subset (see the
                // doc comment on `ReconciliationOutput`). Summing
                // them here double-counts every held item, which
                // surfaced as "Pending review: 2" on Status while
                // the screen itself shows 1. Use the superset
                // alone.
                pendingReviewCount: model.reconciliation?.pendingReviewCandidates.count ?? 0,
                deletionBacklog: backlogCount,
                backlogAlertThreshold: model.settings.deletionBacklogAlertThreshold,
                syncToast: model.syncToast,
                initialScanPending: !model.hasCompletedInitialScan,
                isSyncing: model.isSyncing,
                syncProgress: model.syncProgress.map { (hashed: $0.hashed, total: $0.total) },
                onStartSync: {
                    presentDryRunSheet(forceTripped: model.appState == .thresholdTripped)
                },
                onCancelSync: {
                    cancelActiveSync()
                },
                onOpenRun: { run in
                    presentRunDetail(for: run)
                },
                onSeeAllRuns: {
                    model.activeTab = .runs
                },
                onOpenPendingReview: {
                    model.presentedSheet = .pendingReview
                },
                onResumeInitialScan: {
                    // Route back to the initial-scan screen. The
                    // screen's CTA will be "Start indexing" or
                    // "Resume indexing" depending on whether any
                    // progress is already cached.
                    model.hasDismissedInitialScan = false
                },
                deferredQueue: model.deferredQueue,
                onForceDrainDeferred: {
                    Task { await model.actions.forceDrainDeferred() }
                }
            )
        case "runs":
            RunsScreen(
                runs: model.runs,
                onOpenRun: { run in
                    presentRunDetail(for: run)
                }
            )
        case "settings":
            SettingsScreen(
                settings: $model.settings,
                serverUrl: model.serverHost,
                apiKey: model.apiKey,
                apiKeyMasked: model.apiKeyMasked,
                excludedCount: model.excludedEntries.count,
                connectionStatus: model.connectionStatus,
                onOpenExcluded: { model.settingsRoute = .excluded },
                onResetIndex: { Task { await model.actions.resetIndex() } },
                onClearJournal: { Task { await model.actions.clearJournal() } },
                onSignOut: { Task { await model.actions.signOut() } },
                onRescanLibrary: { Task { await model.actions.rescanLibrary() } },
                deferredQueue: model.deferredQueue,
                onForceDrainDeferred: { Task { await model.actions.forceDrainDeferred() } },
                isSyncing: model.isSyncing,
                syncProgress: model.syncProgress.map { (hashed: $0.hashed, total: $0.total) },
                onReplayOnboarding: { Task { await model.actions.replayOnboarding() } }
            )
        default:
            EmptyView()
        }
    }

    // MARK: - Sheet content

    @ViewBuilder
    private func sheetContent(for sheet: CairnAppModel.PresentedSheet) -> some View {
        switch sheet {
        case .dryRun(let forceTripped):
            // Bind against live reconciliation when present. Previews get a
            // fixture fallback only when running under Xcode's preview
            // runtime (checked via the canonical env var); production runs
            // show whatever the host actually computed — even if that's an
            // empty list. This kills the "15 fake candidates on first sync"
            // bug where a nil fallback leaked fixture data into a real
            // install.
            let candidates: [CairnFixtures.CandidateFixture] = {
                if let live = model.reconciliation {
                    return live.deleteCandidates.map(CairnFixtures.CandidateFixture.from)
                }
                if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
                    return CairnFixtures.candidates
                }
                return []
            }()
            DryRunSheet(
                candidates: candidates,
                library: model.library,
                maxDeletePercent: model.settings.maxDeletePercent,
                minDeleteFloor: model.settings.minDeleteFloor,
                forceTripped: forceTripped,
                onClose: { model.presentedSheet = nil },
                onConfirm: {
                    Task { @MainActor in
                        try? await model.actions.confirmTrash()
                    }
                }
            )
            .cairnTheme(palette)
        case .runDetail(let run, let assets):
            RunDetailSheet(
                run: run,
                assets: assets,
                excludedChecksums: model.excludedChecksums,
                onClose: { model.presentedSheet = nil },
                onExclude: { picks in
                    // Split the selection into the parallel arrays the
                    // action expects: checksums for the store, filenames
                    // for the journal event. Candidates without a
                    // checksum (synthetic preview fixtures, or journal
                    // rows that predate checksum capture) are dropped
                    // from the store write — silently skipping is
                    // preferable to inserting a garbage key that never
                    // matches on future reconciles.
                    let checksums = picks.compactMap(\.checksum)
                    let names = picks.map(\.name)
                    Task { @MainActor in
                        try? await model.actions.exclude(checksums, names, run.id)
                    }
                },
                onUnexclude: { picks in
                    let checksums = picks.compactMap(\.checksum)
                    Task { @MainActor in
                        try? await model.actions.unexclude(checksums)
                    }
                },
                onRestore: { picks in
                    let assetIds = picks.compactMap(\.assetId)
                    Task { @MainActor in
                        try? await model.actions.restore(assetIds, run.id)
                    }
                }
            )
            .cairnTheme(palette)
        case .pendingReview:
            let heldFixtures = (model.reconciliation?.heldByQuarantineCandidates ?? [])
                .map(CairnFixtures.CandidateFixture.from)
            let heldAll = Set(model.reconciliation?.heldByQuarantineCandidates.map(\.checksum.base64) ?? [])
            let unconfirmedFixtures = (model.reconciliation?.pendingReviewCandidates ?? [])
                .filter { !heldAll.contains($0.checksum.base64) }
                .map(CairnFixtures.CandidateFixture.from)
            // Countdown lookup: candidate.id (== filename) → confirmedAt.
            // We don't have a direct filename→checksum map, so we look up by
            // walking the held set once.
            let confirmedAtByFilename: [String: Date] = {
                var out: [String: Date] = [:]
                guard let live = model.reconciliation else { return out }
                for asset in live.heldByQuarantineCandidates {
                    let fixture = CairnFixtures.CandidateFixture.from(asset)
                    if let stamp = live.confirmedDeletedAt[asset.checksum] {
                        out[fixture.id] = stamp
                    }
                }
                return out
            }()
            PendingReviewScreen(
                heldCandidates: heldFixtures,
                unconfirmedCandidates: unconfirmedFixtures,
                confirmedDeletedAt: confirmedAtByFilename,
                quarantineDays: model.reconciliation?.quarantineDays ?? model.settings.quarantineDays,
                massOffloadCount: model.lastScanBurstCount,
                showsMassOffloadBanner: model.lastScanLooksLikeMassOffload,
                onBack: { model.presentedSheet = nil },
                onApprove: { filenames in
                    Task { @MainActor in
                        let checksums = checksumsForFilenames(filenames, in: model.reconciliation?.pendingReviewCandidates ?? [])
                        try? await model.actions.approvePending(checksums)
                    }
                },
                onExclude: { filenames in
                    Task { @MainActor in
                        let checksums = checksumsForFilenames(filenames, in: model.reconciliation?.pendingReviewCandidates ?? [])
                        try? await model.actions.excludePending(checksums)
                    }
                },
                onBulkExcludeOffload: {
                    Task { @MainActor in
                        try? await model.actions.bulkExcludeRecentOffload()
                    }
                }
            )
            .cairnTheme(palette)
        }
    }

    /// Look up the base64 checksums corresponding to a list of candidate
    /// filenames, walking the candidate pool produced by reconciliation.
    /// The UI operates in filenames (that's what `CandidateFixture.id`
    /// exposes); the host-facing actions take checksums since that's the
    /// durable identity across runs.
    private func checksumsForFilenames(_ filenames: [String], in candidates: [ServerAsset]) -> [String] {
        let wanted = Set(filenames)
        return candidates.compactMap { asset in
            let fixture = CairnFixtures.CandidateFixture.from(asset)
            return wanted.contains(fixture.id) ? asset.checksum.base64 : nil
        }
    }

    // MARK: - Sheet helpers

    private func presentDryRunSheet(forceTripped: Bool) {
        // Run reconciliation first, then route based on what
        // came back. Three post-sync outcomes:
        //
        //   1. `deleteCandidates` non-empty → present DryRunSheet
        //      (the normal "confirm these trashes" flow).
        //   2. `deleteCandidates` empty but `pendingReviewCandidates`
        //      non-empty → route to PendingReview. Previously this
        //      landed on a useless "Trash 0" dry-run page; instead
        //      go straight to the screen that can act on the items
        //      (approve / exclude / wait-out-quarantine).
        //   3. Both empty → no-op. Status' "Library in sync" toast
        //      handles the feedback.
        //
        // Preview environment always presents the sheet so fixture
        // data renders without a real reconciliation round-trip.
        startTrackedSync {
            let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
            if isPreview {
                model.presentedSheet = .dryRun(forceTripped: forceTripped)
                return
            }
            guard let live = model.reconciliation else { return }
            if !live.deleteCandidates.isEmpty {
                model.presentedSheet = .dryRun(forceTripped: forceTripped)
            } else if !live.pendingReviewCandidates.isEmpty {
                model.presentedSheet = .pendingReview
            }
            // Both empty → toast-only feedback, no sheet.
        }
    }

    private func presentRunDetail(for run: CairnFixtures.RunFixture) {
        // Real per-run asset list sourced from the journal's
        // `planningTrash` events, keyed by runId on `model.runAssets`
        // (populated at sync/trash time). Each fixture carries the
        // server-side asset UUID so `ImmichAssetThumb` fetches real
        // thumbnails rather than rendering placeholders.
        //
        // Fallback to `CairnFixtures.candidates` only for the
        // preview environment (no real journal) or for runs whose
        // journal entries predate this plumbing — e.g. aborted
        // runs never emit `planningTrash`, so they have no real
        // asset list to show.
        let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        let assets: [CairnFixtures.CandidateFixture] = {
            if let real = model.runAssets[run.id], !real.isEmpty {
                return real
            }
            guard isPreview else { return [] }
            if run.status == .aborted {
                return Array(CairnFixtures.candidates.prefix(14))
            }
            return Array(CairnFixtures.candidates.prefix(max(1, run.trashed)))
        }()
        model.presentedSheet = .runDetail(run, assets: assets)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("App — main (steady)") {
    CairnAppRoot(model: .preview())
}

#Preview("App — onboarding") {
    CairnAppRoot(model: .preview(needsOnboarding: true))
}

#Preview("App — threshold tripped") {
    CairnAppRoot(model: .preview(appState: .thresholdTripped))
}

#Preview("App — server down") {
    CairnAppRoot(model: .preview(degraded: .serverDown))
}

#Preview("App — dark") {
    CairnAppRoot(model: .preview())
        .preferredColorScheme(.dark)
}
#endif
