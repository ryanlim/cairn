import Foundation
import SwiftUI
import CairnCore

/// The runtime state container for the assembled cairn iOS app. Holds all
/// of the state the screens read, plus the navigation/sheet state, plus
/// a bundle of async action closures the host (the Xcode-project app
/// target) implements to do real work.
///
/// The screens themselves never touch this type directly — they receive
/// data via their init params and forward user intent via their existing
/// closures. `CairnAppRoot` is the bridge that maps from screen closures
/// to model methods to host actions.
///
/// **Why an @Observable class instead of a struct/protocol?** SwiftUI's
/// `@Observable` macro gives us automatic dependency tracking — screens
/// re-render only when the specific properties they read change. This
/// avoids the prop-drilling explosion you'd get with `@State` + Bindings
/// across 7 screens, and the mock implementation for previews stays
/// trivial (just instantiate with fixture data).
///
/// The model is `@MainActor` because every property mutation triggers a
/// SwiftUI re-render, which must happen on the main thread.
@Observable
@MainActor
public final class CairnAppModel {

    // MARK: - Auth / onboarding

    /// True if the host has no stored API key — drives setup-vs-main routing.
    public var needsOnboarding: Bool

    /// The Immich server URL (without scheme — display-friendly, e.g. "photos.example.com").
    public var serverHost: String

    /// Raw API key, only readable from Settings → Reveal. Otherwise the
    /// `apiKeyMasked` form is shown. Set this *only* immediately before
    /// the user reveals; otherwise leave empty so it's not sitting in
    /// memory longer than necessary.
    public var apiKey: String

    /// Masked form for default display (e.g. "••••••••••nH3k").
    public var apiKeyMasked: String

    public var connectionStatus: SettingsScreen.ConnectionStatus

    // MARK: - State the screens read

    public var library: CairnFixtures.LibrarySize
    public var runs: [CairnFixtures.RunFixture]
    public var journalTail: [CairnFixtures.JournalTailEntry]
    public var settings: CairnSettings
    public var excludedEntries: [ExcludedScreenEntry]
    public var appState: StatusScreen.AppState
    public var degraded: StatusScreen.Degraded

    // MARK: - Navigation / sheet state

    public var activeTab: CairnTab = .status
    public var presentedSheet: PresentedSheet? = nil
    public var settingsRoute: SettingsRoute = .root

    public enum PresentedSheet: Identifiable, Sendable {
        case dryRun(forceTripped: Bool)
        case runDetail(CairnFixtures.RunFixture, assets: [CairnFixtures.CandidateFixture])

        public var id: String {
            switch self {
            case .dryRun: "dry-run"
            case .runDetail(let r, _): "run-detail-\(r.id)"
            }
        }
    }

    public enum SettingsRoute: Sendable, Equatable {
        case root
        case excluded
    }

    // MARK: - Host-supplied actions

    public let actions: CairnAppActions

    // MARK: - Init

    public init(
        needsOnboarding: Bool = false,
        serverHost: String = "immich.example.com",
        apiKey: String = "",
        apiKeyMasked: String = "••••••••••",
        connectionStatus: SettingsScreen.ConnectionStatus = .healthy(latencyMs: 42),
        library: CairnFixtures.LibrarySize = CairnFixtures.medium,
        runs: [CairnFixtures.RunFixture] = CairnFixtures.runs,
        journalTail: [CairnFixtures.JournalTailEntry] = CairnFixtures.journalTail,
        settings: CairnSettings = .defaults,
        excludedEntries: [ExcludedScreenEntry] = [],
        appState: StatusScreen.AppState = .steady,
        degraded: StatusScreen.Degraded = .none,
        actions: CairnAppActions = .preview
    ) {
        self.needsOnboarding = needsOnboarding
        self.serverHost = serverHost
        self.apiKey = apiKey
        self.apiKeyMasked = apiKeyMasked
        self.connectionStatus = connectionStatus
        self.library = library
        self.runs = runs
        self.journalTail = journalTail
        self.settings = settings
        self.excludedEntries = excludedEntries
        self.appState = appState
        self.degraded = degraded
        self.actions = actions
    }

    // MARK: - Convenience preview factory

    /// Mock model wired with fixture data and no-op closures. Used by
    /// `#Preview` blocks for `CairnAppRoot` so you can render the whole
    /// assembled app without instantiating Keychain / SwiftData / PhotoKit.
    public static func preview(
        needsOnboarding: Bool = false,
        appState: StatusScreen.AppState = .steady,
        degraded: StatusScreen.Degraded = .none,
        library: CairnFixtures.LibrarySize = CairnFixtures.medium
    ) -> CairnAppModel {
        CairnAppModel(
            needsOnboarding: needsOnboarding,
            library: library,
            appState: appState,
            degraded: degraded
        )
    }
}

/// Bundle of async action closures the host implements to do real work.
/// `CairnAppRoot` calls into this type when the screens trigger user
/// intent; the host (the Xcode-project app target) supplies real
/// implementations that talk to `CairnCore` orchestrators, the
/// `ImmichClient`, the SwiftData stores, and so on.
///
/// All closures are `@Sendable` `async` so the host can run them off the
/// main actor (e.g. in a Task) without blocking the UI; the model is
/// `@MainActor` so it'll hop back automatically when state is updated.
public struct CairnAppActions: Sendable {
    /// User tapped "Review & sync" on Status. Host runs the dry-run
    /// reconciliation pipeline and returns the result. The model then
    /// presents the DryRunSheet with the candidates.
    public var requestSync: @Sendable () async throws -> Void

    /// User confirmed trashing in DryRunSheet. Host runs TrashOrchestrator.
    public var confirmTrash: @Sendable () async throws -> Void

    /// User selected a subset of assets from a Run detail view to restore.
    public var restore: @Sendable (_ filenames: [String], _ fromRunId: String) async throws -> Void

    /// User selected a subset of assets to add to the exclusion allowlist.
    public var exclude: @Sendable (_ filenames: [String], _ fromRunId: String) async throws -> Void

    /// User removed a filename from the allowlist via Excluded screen.
    public var unexclude: @Sendable (_ filenames: [String]) async throws -> Void

    /// Setup wizard step: verify URL + API key against the server. Returns
    /// the asset count for the "1,204 assets visible to this key" success state.
    public var verifyServer: @Sendable (_ url: String, _ apiKey: String) async -> SetupScreen.ServerVerifyResult

    /// Setup wizard step: request iOS Photos `.authorized` access.
    public var requestPhotosAccess: @Sendable () async -> Bool

    /// Setup wizard step: request Background App Refresh.
    public var requestBackgroundRefresh: @Sendable () async -> Bool

    /// Setup wizard final step: kick off the first dry-run.
    public var runFirstDryRun: @Sendable () async -> Void

    /// Settings → Danger zone. Each is a destructive op the host wires
    /// to its real teardown logic (rebuild ever-seen, delete journal,
    /// clear keychain).
    public var resetIndex:    @Sendable () async -> Void
    public var clearJournal:  @Sendable () async -> Void
    public var signOut:       @Sendable () async -> Void

    public init(
        requestSync: @escaping @Sendable () async throws -> Void = {},
        confirmTrash: @escaping @Sendable () async throws -> Void = {},
        restore: @escaping @Sendable ([String], String) async throws -> Void = { _, _ in },
        exclude: @escaping @Sendable ([String], String) async throws -> Void = { _, _ in },
        unexclude: @escaping @Sendable ([String]) async throws -> Void = { _ in },
        verifyServer: @escaping @Sendable (String, String) async -> SetupScreen.ServerVerifyResult = { _, _ in
            SetupScreen.ServerVerifyResult(success: true, assetCount: 0, errorMessage: nil)
        },
        requestPhotosAccess: @escaping @Sendable () async -> Bool = { true },
        requestBackgroundRefresh: @escaping @Sendable () async -> Bool = { true },
        runFirstDryRun: @escaping @Sendable () async -> Void = {},
        resetIndex: @escaping @Sendable () async -> Void = {},
        clearJournal: @escaping @Sendable () async -> Void = {},
        signOut: @escaping @Sendable () async -> Void = {}
    ) {
        self.requestSync = requestSync
        self.confirmTrash = confirmTrash
        self.restore = restore
        self.exclude = exclude
        self.unexclude = unexclude
        self.verifyServer = verifyServer
        self.requestPhotosAccess = requestPhotosAccess
        self.requestBackgroundRefresh = requestBackgroundRefresh
        self.runFirstDryRun = runFirstDryRun
        self.resetIndex = resetIndex
        self.clearJournal = clearJournal
        self.signOut = signOut
    }

    /// All-no-op closures with successful default returns. Use in previews
    /// to render `CairnAppRoot` without a host.
    public static let preview: CairnAppActions = CairnAppActions()
}
