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

    /// True while bootstrap() is running. The UI shows a blank/loading
    /// state until this flips to false, preventing the onboarding screen
    /// from rendering before credentials are checked.
    public var isBootstrapping: Bool = false

    /// True if the host has no stored API key — drives setup-vs-main routing.
    public var needsOnboarding: Bool

    /// The Immich server URL (without scheme — display-friendly, e.g. "photos.example.com").
    public var serverHost: String
    /// Full server URL for deep-linking (e.g. opening assets in Safari).
    public var serverURL: URL?

    /// Raw API key — populated at bootstrap (from Keychain) and after
    /// a successful onboarding verify. Drives the Settings → Reveal
    /// and Copy actions. An empty string means "not signed in yet";
    /// Sign-out clears it back to empty alongside the Keychain wipe.
    /// The raw key also lives inside `ImmichClient` for the life of
    /// the session, so keeping it on the model doesn't materially
    /// widen the in-memory exposure.
    public var apiKey: String

    /// Masked form for default display (e.g. "••••••••••nH3k").
    public var apiKeyMasked: String

    public var connectionStatus: SettingsScreen.ConnectionStatus

    // MARK: - State the screens read

    public var library: CairnFixtures.LibrarySize
    public var runs: [CairnFixtures.RunFixture]
    /// Per-run asset breakdown, keyed on `runId`. Populated alongside
    /// `runs` from the journal's `planningTrash` events so
    /// `RunDetailSheet` renders real thumbnails (via asset UUIDs)
    /// rather than placeholder fixtures.
    public var runAssets: [String: [CairnFixtures.CandidateFixture]] = [:]
    public var journalTail: [CairnFixtures.JournalTailEntry]
    public var settings: CairnSettings
    public var excludedEntries: [ExcludedScreenEntry]
    /// Base64 SHA1 checksums currently in the `ExclusionStore`.
    /// Populated at bootstrap and after every exclude / unexclude
    /// action, so UI surfaces (RunDetailSheet's per-tile shield badge
    /// and "Exclude ↔ Unexclude" toggle) can reflect live state
    /// without each view doing its own store round-trip.
    public var excludedChecksums: Set<String> = []
    public var appState: StatusScreen.AppState
    public var degraded: StatusScreen.Degraded

    /// Required API permissions the current key is missing. Empty when
    /// all scopes are present or when the key hasn't been checked yet.
    /// Populated at bootstrap and on verify; surfaces a banner on Status.
    public var missingPermissions: [String] = []

    // MARK: - Live reconciliation result

    /// Most recent result from `actions.requestSync`. `nil` until the first
    /// sync has completed. Screens that render fixtures in preview should
    /// fall back when this is `nil` and `actions == .preview` so the #Preview
    /// blocks keep working without real data.
    public var reconciliation: LiveReconciliation?

    /// Snapshot of what `requestSync` produced. Intentionally mirrors the
    /// `ReconciliationOutput` shape but holds only what the UI needs — the
    /// three candidate buckets in display order, plus the timestamps and
    /// quarantine context needed to render countdowns on the pending-review
    /// surface.
    public struct LiveReconciliation: Sendable, Equatable {
        public let deleteCandidates: [ServerAsset]
        public let pendingReviewCandidates: [ServerAsset]
        public let heldByQuarantineCandidates: [ServerAsset]
        /// `confirmedAt` timestamp per held candidate checksum. Lets the
        /// pending-review screen render per-item "eligible in N days"
        /// without a second round trip.
        public let confirmedDeletedAt: [Checksum: Date]
        /// Quarantine window that was in effect when this reconciliation
        /// ran. Locked in at the time of compute so UI countdowns don't
        /// drift if the user changes settings mid-review.
        public let quarantineDays: Int
        public let computedAt: Date
        /// Map from inferred-orphan checksum → the metadata-store
        /// `localIdentifier` whose filename + creationDate matched the
        /// server asset. Lets the approve-pending flow sweep the
        /// metadata store after a successful trash so the row doesn't
        /// keep matching on subsequent syncs.
        public let inferredOrphanLocalIdentifiers: [Checksum: String]
        /// Checksums anchored as a `firstObserved` value for some
        /// currently-alive `localIdentifier` in the photo library.
        /// Sourced from `EditRetirementStore` at scan time. Used by
        /// the Pending Review screen to label one version of a grouped
        /// (filename + creationDate) candidate as the "Original" — the
        /// untouched bytes that the user's edits trace back to. Empty
        /// when no edit-retirement anchors are live, which is the
        /// common case before the user starts editing photos.
        public let firstObservedAnchors: Set<Checksum>
        /// Source `localIdentifier` per candidate checksum. Populated for
        /// both regular candidates (via the reconciler's delete-path
        /// tracking) and inferred orphans (via OrphanReconciler matched-
        /// metadata). Used by the Pending Review grouping helper as the
        /// primary group key — two candidates sharing the same source
        /// localIdentifier represent versions of the same logical photo
        /// and render as one stacked card. Falls back to
        /// `(originalFileName, fileCreatedAt)` when source-id isn't
        /// known. Distinct from `inferredOrphanLocalIdentifiers` because
        /// that one is a narrower orphan-only map used by
        /// `approvePending` for metadata cleanup.
        public let sourceLocalIdentifiersByChecksum: [Checksum: String]

        public init(
            deleteCandidates: [ServerAsset],
            pendingReviewCandidates: [ServerAsset],
            heldByQuarantineCandidates: [ServerAsset],
            confirmedDeletedAt: [Checksum: Date] = [:],
            quarantineDays: Int = 14,
            computedAt: Date = Date(),
            inferredOrphanLocalIdentifiers: [Checksum: String] = [:],
            firstObservedAnchors: Set<Checksum> = [],
            sourceLocalIdentifiersByChecksum: [Checksum: String] = [:]
        ) {
            self.deleteCandidates = deleteCandidates
            self.pendingReviewCandidates = pendingReviewCandidates
            self.heldByQuarantineCandidates = heldByQuarantineCandidates
            self.confirmedDeletedAt = confirmedDeletedAt
            self.quarantineDays = quarantineDays
            self.computedAt = computedAt
            self.inferredOrphanLocalIdentifiers = inferredOrphanLocalIdentifiers
            self.firstObservedAnchors = firstObservedAnchors
            self.sourceLocalIdentifiersByChecksum = sourceLocalIdentifiersByChecksum
        }
    }

    /// Count of newly-confirmed-deleted checksums from the most recent
    /// scan. Used by the mass-offload banner: when a single scan returns
    /// an unusually large burst (e.g. ≥ `Self.massOffloadThreshold`), the
    /// banner surfaces so the user can decide between "review these" and
    /// "bulk-exclude — I intended to offload."
    public var lastScanBurstCount: Int = 0

    /// Count of inferred orphans from the most recent scan — server
    /// assets cairn observed locally (filename + creationDate) but
    /// never finished hashing before they were deleted from the photo
    /// library. The standard ever-seen reconciler can't surface these
    /// because the SHA1 was never recorded; `OrphanReconciler` matches
    /// them by metadata. Drives a warn-tone banner on Status.
    public var inferredOrphanCount: Int = 0

    /// Timestamp of the most recent reconciliation, used by the
    /// "Last checked" line on Status. Restored at bootstrap from the
    /// persisted `StatusSnapshotStore` so the line shows a real time
    /// before the next sync runs; refreshed on each successful sync.
    /// Falls back to `reconciliation?.computedAt` when present.
    public var lastCheckedAt: Date?

    /// Threshold above which `lastScanBurstCount` triggers the mass-offload
    /// banner. Hard-coded for now; a settings-driven tuning knob could
    /// replace this if field data suggests 50 is wrong.
    public static let massOffloadThreshold: Int = 50

    /// True when the last scan's burst was big enough to suggest a mass
    /// offload rather than piecemeal deletion.
    public var lastScanLooksLikeMassOffload: Bool {
        lastScanBurstCount >= Self.massOffloadThreshold
    }

    /// True when the most recent scan re-enumerated the whole library
    /// because the persistent-change token expired (or the saved token
    /// archive failed to unarchive). Any deletion candidates surfaced
    /// this pass are negative-signal-only with no quarantine clock —
    /// `AppDependencies.performLiveReconciliation` promotes them all
    /// into `pendingReviewCandidates` regardless of strictness, and the
    /// Pending Review screen surfaces a banner explaining why.
    public var lastScanWasTokenExpiryFullEnum: Bool = false

    /// Human-readable error from the most recent failed action. When set,
    /// `CairnAppRoot` presents an alert. Cleared to `nil` when the user
    /// dismisses it. Use for transient, user-fixable failures (Photos
    /// permission, network, auth expired) — not for programmatic error
    /// handling.
    public var lastError: String?

    /// Transient banner surfaced on Status after a sync completes. Only
    /// set when the outcome is worth surfacing — typically "nothing to
    /// sync, library is up-to-date." `CairnAppRoot` auto-clears after a
    /// few seconds (see `SyncToast.autoDismissSeconds`). Kept separate
    /// from `lastError` because success and failure need distinct tones.
    public var syncToast: SyncToast?

    public enum SyncToast: Sendable, Equatable {
        /// Review & Sync ran and found no work. Renders as a verified-tone
        /// Callout on Status with the hashed/total stats inline.
        case upToDate(indexed: Int, total: Int)
        /// Deletion journal file deleted from disk. Confirmation toast
        /// after the "Clear journal" action.
        case journalCleared
        /// Index-wiping completed (`Reset index` action).
        case indexReset
        /// Rescan queued — token + defer queue cleared, user is
        /// routed back to the initial-scan screen.
        case rescanQueued

        public static let autoDismissSeconds: TimeInterval = 4
    }

    /// `true` while a sync is mid-flight. Drives spinner state on the
    /// Status screen's "Review & sync" button so taps don't feel dead.
    public var isSyncing: Bool = false

    /// Current phase of the sync pipeline. Drives the CTA label so the
    /// user sees what's happening after hashing finishes.
    public var syncPhase: SyncPhase = .idle

    public enum SyncPhase: Sendable, Equatable {
        case idle
        case hashing
        case fetchingServer
        case reconciling
    }

    /// Hashing progress during a sync. `nil` outside sync. The
    /// full-enumeration path (first-run, token expired) populates this;
    /// incremental syncs skip it since they're already fast.
    public var syncProgress: SyncProgress?

    /// Latched `true` once the auto-sync on first landing has been
    /// triggered for this app session. Kept on the model (not as a
    /// `@State` on CairnAppRoot) so a navigation that temporarily swaps
    /// the view identity — e.g. visiting the Excluded sub-route and
    /// returning — doesn't re-fire the sync. Reset only by an explicit
    /// sign-out flow.
    public var didAutoSyncThisSession: Bool = false

    /// `true` once a full-library enumeration has completed at least
    /// once on this install — equivalent to "a `PHPersistentChangeToken`
    /// is stashed on disk." Gates the `InitialScanScreen` takeover: when
    /// `false`, we show a dedicated full-screen progress UI instead of
    /// the main tabs, because the main tabs' counts are meaningless
    /// until we've indexed the library. Seeded from `tokenStore` at
    /// bootstrap; flipped `true` by the first successful
    /// `performLiveReconciliation`.
    public var hasCompletedInitialScan: Bool = false

    /// User dismissed the InitialScanScreen to browse the main tabs
    /// before kicking off the indexing. Status shows a persistent
    /// "Initial scan pending" banner in this state; tapping it routes
    /// back to the scan screen and (optionally) starts the scan.
    /// Resets to `false` on sign-out so the fresh-install flow picks
    /// up from the start for new credentials.
    public var hasDismissedInitialScan: Bool = false

    /// Non-nil when a scan is paused: the elapsed work time captured
    /// at cancel, frozen so the UI shows "244 of 500 · 12s" rather
    /// than a ticking timer against a frozen `syncStartedAt` (which
    /// would drift with wall-clock time). Resume clears this and
    /// shifts `syncStartedAt` forward so the timer picks up
    /// continuously from where it was interrupted.
    public var pausedSyncElapsedSeconds: Double?

    /// Summary of the deferred-hash queue (items skipped by the soft
    /// limit, awaiting a background drain or a manual "Hash now"
    /// tap). Populated after each sync. `nil` means not yet queried;
    /// `.empty` means queried and nothing queued.
    public var deferredQueue: DeferredQueueSummary = .empty

    /// Snapshot of the deferred queue entries for the sheet view.
    /// Populated when the deferred queue sheet is about to present.
    public var deferredQueueEntries: [DeferredHashEntry] = []

    /// Count of items in `ConfirmedDeletedStore` still within the
    /// quarantine window. Populated from the store directly at
    /// bootstrap and after each sync/trash, so the Status pending
    /// review banner has data even before the first reconciliation.
    public var quarantineCount: Int = 0

    /// Checksums observed locally during the most recent scan that match a
    /// previously-successful cairn trash within Immich's 30-day hard-delete
    /// window. The user pulled the photo back (Recently Deleted → Recover,
    /// re-import) but the Immich mobile app silently no-ops the upload while
    /// the asset is still in Immich trash with the same SHA1. After 30 days
    /// the server purges and the photo is gone server-side — until then,
    /// the user has a window to restore it on Immich too.
    ///
    /// Drives the warn-tone banner on Status. Each entry's `TrashedRecord`
    /// carries the source runId so v2 can deep-link to run detail; v1 just
    /// surfaces the count.
    public var restoredAfterCairnTrash: [Checksum: JournalReader.TrashedRecord] = [:]

    public struct DeferredQueueSummary: Sendable, Equatable {
        /// Items that will actually be attempted on next drain.
        public var count: Int
        /// Items in the queue but above the current hard ceiling.
        public var aboveCeiling: Int
        public var totalKnownBytes: Int64

        public static let empty = DeferredQueueSummary(count: 0, aboveCeiling: 0, totalKnownBytes: 0)

        public init(count: Int, aboveCeiling: Int = 0, totalKnownBytes: Int64) {
            self.count = count
            self.aboveCeiling = aboveCeiling
            self.totalKnownBytes = totalKnownBytes
        }
    }

    /// Wall-clock time the current sync started. `nil` when idle. Drives
    /// the "Elapsed" display on `InitialScanScreen` and is the basis for
    /// ETA computation (remaining ≈ elapsed * (total - done) / done).
    public var syncStartedAt: Date?

    public struct SyncProgress: Sendable, Equatable {
        public let hashed: Int
        public let total: Int

        public init(hashed: Int, total: Int) {
            self.hashed = hashed
            self.total = total
        }
    }

    // MARK: - Navigation / sheet state

    public var activeTab: CairnTab = .status
    public var presentedSheet: PresentedSheet? = nil
    public var settingsRoute: SettingsRoute = .root

    public enum PresentedSheet: Identifiable, Sendable {
        case dryRun(forceTripped: Bool)
        case runDetail(CairnFixtures.RunFixture, assets: [CairnFixtures.CandidateFixture])
        case pendingReview
        case deferredQueue

        public var id: String {
            switch self {
            case .dryRun: "dry-run"
            case .runDetail(let r, _): "run-detail-\(r.id)"
            case .pendingReview: "pending-review"
            case .deferredQueue: "deferred-queue"
            }
        }
    }

    public enum SettingsRoute: Sendable, Equatable {
        case root
        case excluded
    }

    // MARK: - Host-supplied actions

    /// `var` rather than `let` so the host can swap the bundle once
    /// credentials are available. Initial value is the no-op preview
    /// default; `AppDependencies.rewireActions()` replaces it with real
    /// closures that talk to `ImmichClient`, `TrashOrchestrator`, etc.
    /// A stale `let` version of this was the source of a subtle bug
    /// where onboarding's `verifyServer` vacuously returned success
    /// without ever contacting Immich.
    public var actions: CairnAppActions

    // MARK: - Init

    public init(
        needsOnboarding: Bool = false,
        serverHost: String = "immich.example.com",
        apiKey: String = "",
        apiKeyMasked: String = "••••••••••",
        connectionStatus: SettingsScreen.ConnectionStatus = .healthy(latencyMs: 42),
        library: CairnFixtures.LibrarySize = .empty,
        runs: [CairnFixtures.RunFixture] = [],
        journalTail: [CairnFixtures.JournalTailEntry] = [],
        settings: CairnSettings = .defaults,
        excludedEntries: [ExcludedScreenEntry] = [],
        appState: StatusScreen.AppState = .steady,
        degraded: StatusScreen.Degraded = .none,
        reconciliation: LiveReconciliation? = nil,
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
        self.reconciliation = reconciliation
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
        // Previews get the full fixture data — runs, journal tail, library
        // — so every screen renders something meaningful without needing a
        // live host. Production `CairnAppModel`s start empty; fixtures only
        // flow in through this factory.
        CairnAppModel(
            needsOnboarding: needsOnboarding,
            library: library,
            runs: CairnFixtures.runs,
            journalTail: CairnFixtures.journalTail,
            appState: appState,
            degraded: degraded
        )
    }
}

public enum CairnExportScope: Sendable {
    case currentServer
    case allServers
}

public struct CairnImportResult: Sendable {
    public let everSeenAdded: Int
    public let exclusionsAdded: Int
    public let journalLinesAppended: Int
    public let settingsApplied: Bool
    public let serverCount: Int

    public init(everSeenAdded: Int, exclusionsAdded: Int, journalLinesAppended: Int, settingsApplied: Bool, serverCount: Int) {
        self.everSeenAdded = everSeenAdded
        self.exclusionsAdded = exclusionsAdded
        self.journalLinesAppended = journalLinesAppended
        self.settingsApplied = settingsApplied
        self.serverCount = serverCount
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

    /// User selected a subset of assets from a Run detail view to
    /// restore. `assetIds` are Immich's server-side UUIDs (from
    /// `CandidateFixture.assetId`), passed straight to
    /// `RestoreOrchestrator.restore(fromRunId:assetIds:)`. An empty
    /// array restores every asset in the run.
    public var restore: @Sendable (_ assetIds: [String], _ fromRunId: String) async throws -> Void

    /// User selected a subset of assets to add to the exclusion
    /// allowlist. `checksums` are base64 SHA1s (from
    /// `CandidateFixture.checksum`) — matches what the
    /// `ExclusionStore` is keyed on. `filenames` are the
    /// originalFileName values at exclusion time, used for display
    /// and for the journal event.
    public var exclude: @Sendable (_ checksums: [String], _ filenames: [String], _ fromRunId: String) async throws -> Void

    /// User removed a checksum from the allowlist via Excluded screen.
    public var unexclude: @Sendable (_ checksums: [String]) async throws -> Void

    /// User approved a specific set of held/unconfirmed pending-review
    /// candidates for immediate trashing — bypasses the rest of the
    /// quarantine wait. Host translates checksums → asset IDs and
    /// invokes `TrashOrchestrator.run` on just this subset.
    public var approvePending: @Sendable (_ checksums: [String]) async throws -> Void

    /// User marked a pending-review subset as "don't trash these"
    /// — routes them into `ExclusionStore` so every future run skips them.
    /// Also removes them from `ConfirmedDeletedStore` (un-confirms) so
    /// they stop showing up in pending-review regardless.
    public var excludePending: @Sendable (_ checksums: [String]) async throws -> Void

    /// Remove checksums from `ConfirmedDeletedStore` without adding to
    /// `ExclusionStore`. The items leave the pending list but are not
    /// permanently protected — a future deletion of the same photo
    /// re-enters the quarantine pipeline.
    public var dismissPending: @Sendable (_ checksums: [String]) async throws -> Void

    /// Export cairn state for the given scope. Returns a temporary file URL
    /// the caller can hand to the system share sheet.
    public var exportData: @Sendable (_ scope: CairnExportScope) async throws -> URL

    /// Import cairn state from the given file URL. `applySettings` controls
    /// whether the payload's settings overwrite the current ones.
    public var importData: @Sendable (_ fileURL: URL, _ applySettings: Bool) async throws -> CairnImportResult

    /// User tapped the mass-offload banner's "bulk exclude"
    /// affordance — every checksum confirmed-deleted in the recent burst
    /// is moved to the exclusion list. Host computes the set by filtering
    /// `confirmedDeleted.snapshot()` for entries confirmed within the last
    /// scan window. Same semantics as `excludePending` but operates on a
    /// larger set.
    public var bulkExcludeRecentOffload: @Sendable () async throws -> Void

    /// Snapshot the deferred queue entries for the detail sheet.
    public var loadDeferredEntries: @Sendable () async throws -> [DeferredHashEntry]

    /// Setup wizard step: verify URL + API key against the server. Returns
    /// the asset count for the "1,204 assets visible to this key" success state.
    public var verifyServer: @Sendable (_ url: String, _ apiKey: String) async -> SetupScreen.ServerVerifyResult

    /// Re-ping the configured Immich server and refresh
    /// `connectionStatus` + `degraded` based on the result. Wired to
    /// the "Retry" button on the server-unreachable banner so users
    /// don't have to tap Sync (a heavier operation) just to recover
    /// from a transient network blip.
    public var retryConnection: @Sendable () async -> Void

    /// Setup wizard step: request iOS Photos `.authorized` access.
    public var requestPhotosAccess: @Sendable () async -> Bool

    /// Setup wizard step: request Background App Refresh.
    public var requestBackgroundRefresh: @Sendable () async -> Bool

    /// Settings → Danger zone. Each is a destructive op the host wires
    /// to its real teardown logic (rebuild ever-seen, delete journal,
    /// clear keychain).
    public var resetIndex:    @Sendable () async -> Void
    public var clearJournal:  @Sendable () async -> Void
    public var signOut:       @Sendable () async -> Void

    /// Settings → Library. Clears the persistent-change token + the
    /// deferred-hash queue so the next sync re-enumerates the library
    /// from scratch. Lighter than `resetIndex` — ever-seen and
    /// confirmed-deleted survive, so reconciliation history is
    /// preserved. Used when the user changes a size-limit setting and
    /// wants the new value to take effect immediately.
    public var rescanLibrary: @Sendable () async -> Void

    /// Persist the current `CairnSettings` to the on-device store.
    /// Called automatically when the settings binding mutates; there's
    /// no user-visible "save" button, so this runs in the background
    /// whenever any slider/toggle changes.
    public var persistSettings: @Sendable (CairnSettings) async -> Void

    /// User tapped "Skip for now" on the initial-scan screen. Host
    /// flips `hasDismissedInitialScan` so the UI lands on the main
    /// tabs; a persistent banner keeps the scan one tap away.
    public var dismissInitialScan: @Sendable () async -> Void

    /// User tapped "Start over" while indexing was paused. Wipe hash
    /// cache + token + defer queue + ever-seen + confirmed-deleted so
    /// the next scan begins from scratch. Distinct from `resumeSync`
    /// (which picks up from where the cache left off).
    public var startOverInitialScan: @Sendable () async -> Void

    /// User explicitly asked to hash the deferred queue right now,
    /// rather than waiting for iOS to grant a background slot. Runs
    /// the unlimited-drain path in foreground — same code BGProcessingTask
    /// uses, but the user pays the time cost here. Hard ceiling still
    /// applies. Progress surfaces via the normal `syncProgress`.
    public var forceDrainDeferred: @Sendable () async -> Void

    /// Dev-only: replay the onboarding flow without clearing stored
    /// credentials. Host reads URL + API key from Keychain, pre-fills
    /// the model so the SetupScreen fields come up populated, and
    /// flips `needsOnboarding = true`. Completing the flow (or
    /// backgrounding and returning) drops the user back into the
    /// main app with credentials still intact. Exposed via a
    /// DEBUG-gated row in Settings → Advanced.
    public var replayOnboarding: @Sendable () async -> Void

    public init(
        requestSync: @escaping @Sendable () async throws -> Void = {},
        confirmTrash: @escaping @Sendable () async throws -> Void = {},
        restore: @escaping @Sendable ([String], String) async throws -> Void = { _, _ in },
        exclude: @escaping @Sendable ([String], [String], String) async throws -> Void = { _, _, _ in },
        unexclude: @escaping @Sendable ([String]) async throws -> Void = { _ in },
        approvePending: @escaping @Sendable ([String]) async throws -> Void = { _ in },
        excludePending: @escaping @Sendable ([String]) async throws -> Void = { _ in },
        dismissPending: @escaping @Sendable ([String]) async throws -> Void = { _ in },
        loadDeferredEntries: @escaping @Sendable () async throws -> [DeferredHashEntry] = { [] },
        exportData: @escaping @Sendable (CairnExportScope) async throws -> URL = { _ in URL(fileURLWithPath: "/dev/null") },
        importData: @escaping @Sendable (URL, Bool) async throws -> CairnImportResult = { _, _ in CairnImportResult(everSeenAdded: 0, exclusionsAdded: 0, journalLinesAppended: 0, settingsApplied: false, serverCount: 0) },
        bulkExcludeRecentOffload: @escaping @Sendable () async throws -> Void = {},
        verifyServer: @escaping @Sendable (String, String) async -> SetupScreen.ServerVerifyResult = { _, _ in
            SetupScreen.ServerVerifyResult(success: true, assetCount: 0, errorMessage: nil)
        },
        retryConnection: @escaping @Sendable () async -> Void = {},
        requestPhotosAccess: @escaping @Sendable () async -> Bool = { true },
        requestBackgroundRefresh: @escaping @Sendable () async -> Bool = { true },
        resetIndex: @escaping @Sendable () async -> Void = {},
        clearJournal: @escaping @Sendable () async -> Void = {},
        signOut: @escaping @Sendable () async -> Void = {},
        rescanLibrary: @escaping @Sendable () async -> Void = {},
        persistSettings: @escaping @Sendable (CairnSettings) async -> Void = { _ in },
        dismissInitialScan: @escaping @Sendable () async -> Void = {},
        startOverInitialScan: @escaping @Sendable () async -> Void = {},
        forceDrainDeferred: @escaping @Sendable () async -> Void = {},
        replayOnboarding: @escaping @Sendable () async -> Void = {}
    ) {
        self.requestSync = requestSync
        self.confirmTrash = confirmTrash
        self.restore = restore
        self.exclude = exclude
        self.unexclude = unexclude
        self.approvePending = approvePending
        self.excludePending = excludePending
        self.dismissPending = dismissPending
        self.loadDeferredEntries = loadDeferredEntries
        self.exportData = exportData
        self.importData = importData
        self.bulkExcludeRecentOffload = bulkExcludeRecentOffload
        self.verifyServer = verifyServer
        self.retryConnection = retryConnection
        self.requestPhotosAccess = requestPhotosAccess
        self.requestBackgroundRefresh = requestBackgroundRefresh
        self.resetIndex = resetIndex
        self.clearJournal = clearJournal
        self.signOut = signOut
        self.rescanLibrary = rescanLibrary
        self.persistSettings = persistSettings
        self.dismissInitialScan = dismissInitialScan
        self.startOverInitialScan = startOverInitialScan
        self.forceDrainDeferred = forceDrainDeferred
        self.replayOnboarding = replayOnboarding
    }

    /// All-no-op closures with successful default returns. Use in previews
    /// to render `CairnAppRoot` without a host.
    public static let preview: CairnAppActions = CairnAppActions()
}
