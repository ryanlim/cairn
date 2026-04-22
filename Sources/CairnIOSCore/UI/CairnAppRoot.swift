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

    public init(model: CairnAppModel, palette: CairnPalette = .defaults) {
        self.model = model
        self.palette = palette
    }

    public var body: some View {
        Group {
            if model.needsOnboarding {
                onboarding
            } else if model.settingsRoute == .excluded {
                excludedSubRoute
            } else {
                mainTabs
            }
        }
        .cairnTheme(palette)
        .animation(.snappy(duration: 0.18), value: model.needsOnboarding)
        .animation(.snappy(duration: 0.18), value: model.settingsRoute)
        .sheet(item: Binding(
            get: { model.presentedSheet },
            set: { model.presentedSheet = $0 }
        )) { sheet in
            sheetContent(for: sheet)
        }
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
            onRunFirstDryRun: {
                await model.actions.runFirstDryRun()
            },
            onComplete: {
                // Host is responsible for actually persisting the URL/key/settings.
                // We just flip the route — the next render shows the main tabs.
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

    // MARK: - Main tabs

    private var mainTabs: some View {
        VStack(spacing: 0) {
            currentTab
            CairnTabBar(active: $model.activeTab)
        }
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
                onStartSync: {
                    presentDryRunSheet(forceTripped: model.appState == .thresholdTripped)
                },
                onOpenRun: { run in
                    presentRunDetail(for: run)
                },
                onSeeAllRuns: {
                    model.activeTab = .runs
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
                onOpenPalette: { /* Palette editor deferred — see HANDOFF */ },
                onResetIndex: { Task { await model.actions.resetIndex() } },
                onClearJournal: { Task { await model.actions.clearJournal() } },
                onSignOut: { Task { await model.actions.signOut() } }
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
            DryRunSheet(
                library: model.library,
                maxDeletePercent: model.settings.maxDeletePercent,
                minDeleteFloor: model.settings.minDeleteFloor,
                dryRunByDefault: model.settings.dryRunByDefault,
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
                onClose: { model.presentedSheet = nil },
                onExclude: { filenames in
                    Task { @MainActor in
                        try? await model.actions.exclude(filenames, run.id)
                    }
                },
                onRestore: { filenames in
                    Task { @MainActor in
                        try? await model.actions.restore(filenames, run.id)
                    }
                }
            )
            .cairnTheme(palette)
        }
    }

    // MARK: - Sheet helpers

    private func presentDryRunSheet(forceTripped: Bool) {
        // Real flow: host kicks off reconciliation via actions.requestSync,
        // populates model.* with results, then sets presentedSheet. For the
        // current package-only state, presenting the sheet directly lets the
        // SwiftUI previews exercise the full sheet flow against fixtures.
        Task { @MainActor in
            try? await model.actions.requestSync()
            model.presentedSheet = .dryRun(forceTripped: forceTripped)
        }
    }

    private func presentRunDetail(for run: CairnFixtures.RunFixture) {
        // Until the host has a real per-run asset enumeration path, we use
        // the fixture candidates so the sheet renders. Real impl: host
        // queries the journal + server for this run's tagged assets,
        // populates the assets array, then presents.
        let assets: [CairnFixtures.CandidateFixture] = {
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
