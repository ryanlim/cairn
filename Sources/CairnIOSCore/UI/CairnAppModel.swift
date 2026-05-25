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

    /// `true` when a session-auth access token is persisted in
    /// Keychain (acquired via `signInForSession`). Drives the
    /// Settings → Advanced "Session sign-in for incremental sync"
    /// UI between signed-out and signed-in states. Updated by the
    /// host on bootstrap (read from Keychain), sign-in success, and
    /// sign-out.
    public var hasSessionToken: Bool = false

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

    /// Live PhotoKit authorization outcome. `.full` is the canonical
    /// healthy state; `.limited` triggers the safety guards described
    /// in `AppDependencies.performLiveReconciliation` (forced `.strict`
    /// strictness + `requireExplicitDeletionEvent` on the reconciler).
    /// Settings surfaces this verbatim and the Status screen shows a
    /// one-shot toast on the first sync after the app detects
    /// `.limited` so the user understands the trust downgrade. `nil`
    /// pre-bootstrap or when the auth check hasn't completed.
    public var photoAuthStatus: SetupScreen.PhotoAuthOutcome? = nil

    // MARK: - Live reconciliation result

    /// Most recent result from `actions.requestSync`. `nil` until the first
    /// sync has completed. Screens that render fixtures in preview should
    /// fall back when this is `nil` and `actions == .preview` so the #Preview
    /// blocks keep working without real data.
    public var reconciliation: LiveReconciliation?

    /// What initiated the most recent sync. Set by the host's
    /// `requestSync` action wrapper before reconciliation begins; nil
    /// until the first sync. Surfaced in the Status journal tail (via
    /// the `.syncStarted` journal event) so the user can see at a
    /// glance whether a recent sync came from a tap, a Shortcut, or
    /// an iOS background slot.
    public var lastSyncTrigger: JournalEntry.SyncTrigger?

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
        /// Server assets the user excluded (typically via "restore via
        /// cairn" auto-exclusion) that have a fresh confirmed-delete
        /// stamp post-dating the exclusion. Surfaced for explicit
        /// review — approving here clears the exclusion and trashes;
        /// dismissing keeps the exclusion. Empty when there are no
        /// recycled exclusions to review.
        public let recycledExclusionCandidates: [ServerAsset]

        public init(
            deleteCandidates: [ServerAsset],
            pendingReviewCandidates: [ServerAsset],
            heldByQuarantineCandidates: [ServerAsset],
            confirmedDeletedAt: [Checksum: Date] = [:],
            quarantineDays: Int = 14,
            computedAt: Date = Date(),
            inferredOrphanLocalIdentifiers: [Checksum: String] = [:],
            firstObservedAnchors: Set<Checksum> = [],
            sourceLocalIdentifiersByChecksum: [Checksum: String] = [:],
            recycledExclusionCandidates: [ServerAsset] = []
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
            self.recycledExclusionCandidates = recycledExclusionCandidates
        }

        /// Return a new reconciliation with `checksums` filtered out of
        /// every bucket and lookup map. Centralizes what every host
        /// action (`approvePending`, `excludePending`, `dismissPending`,
        /// `restore`, `bulkExcludeRecentOffload`) needs to do after
        /// acting on a subset: prune the in-memory snapshot so the UI
        /// reflects the user's intent immediately, without waiting for
        /// the next reconciliation pass.
        ///
        /// Also crucial as a future-proofing point: any new bucket
        /// added to `LiveReconciliation` only has to be filtered here,
        /// not in five separate call sites that each need to remember
        /// to wire it in.
        public func removing(checksums: Set<Checksum>) -> LiveReconciliation {
            guard !checksums.isEmpty else { return self }
            return LiveReconciliation(
                deleteCandidates: deleteCandidates.filter { !checksums.contains($0.checksum) },
                pendingReviewCandidates: pendingReviewCandidates.filter { !checksums.contains($0.checksum) },
                heldByQuarantineCandidates: heldByQuarantineCandidates.filter { !checksums.contains($0.checksum) },
                confirmedDeletedAt: confirmedDeletedAt.filter { !checksums.contains($0.key) },
                quarantineDays: quarantineDays,
                computedAt: computedAt,
                inferredOrphanLocalIdentifiers: inferredOrphanLocalIdentifiers.filter { !checksums.contains($0.key) },
                firstObservedAnchors: firstObservedAnchors,
                sourceLocalIdentifiersByChecksum: sourceLocalIdentifiersByChecksum.filter { !checksums.contains($0.key) },
                recycledExclusionCandidates: recycledExclusionCandidates.filter { !checksums.contains($0.checksum) }
            )
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
    /// library. The standard observed reconciler can't surface these
    /// because the SHA1 was never recorded; `OrphanReconciler` matches
    /// them by metadata. Drives a warn-tone banner on Status.
    public var inferredOrphanCount: Int = 0

    /// Timestamp of the most recent reconciliation, used by the
    /// "Last checked" line on Status. Restored at bootstrap from the
    /// persisted `StatusSnapshotStore` so the line shows a real time
    /// before the next sync runs; refreshed on each successful sync.
    /// Falls back to `reconciliation?.computedAt` when present.
    public var lastCheckedAt: Date?

    /// Set of candidate checksums (delete + pending-review buckets
    /// merged) the user has been auto-presented with via the post-
    /// sync routing — i.e., whatever `presentDryRunSheet` last
    /// auto-popped on the user's behalf. The auto-present skips when
    /// the current candidate set is a subset of this acknowledged
    /// set, so tapping Sync after dismissing a sheet doesn't
    /// re-pop the same items. New items (not in the set) re-trigger
    /// the auto-present.
    ///
    /// Cleared by sign-out and by Reset Index. Otherwise persists
    /// for the app session — survives backgrounding and re-foregrounding.
    public var acknowledgedCandidateChecksums: Set<String> = []

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

    /// Sticky flag tracking whether the modal alert for the current
    /// disconnected session has already been shown. While `true`,
    /// `recordSyncError(_:isNetworkLike:)` skips the alert pop —
    /// `degraded = .serverDown` already paints the persistent
    /// banner on Status, so re-popping the modal on every retry
    /// during a known-offline session is redundant noise. Reset by
    /// `recordSyncSuccess()` once we've talked to Immich again.
    public var connectionErrorAcknowledged: Bool = false

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
        /// One-shot heads-up that the app is operating under `.limited`
        /// PhotoKit auth. Fires once per `.limited` session (gated by
        /// UserDefaults so a user who's chosen Limited intentionally
        /// doesn't get nagged every sync). Explains the resulting
        /// trust downgrade so the user knows what to expect — full
        /// detail lives in Settings → Permissions.
        case limitedPhotosNotice
        /// Local PhotoKit deletion detection ran but the
        /// server-touching part of the sync couldn't complete (e.g.,
        /// airplane mode). The deletions are persisted to
        /// `ConfirmedDeletedStore` and will surface as trash
        /// candidates on the next successful sync. Surfaced from
        /// `requestSync`'s catch path so the user sees their
        /// offline-time deletions are recorded, not lost.
        case offlineDetections(count: Int)

        public static let autoDismissSeconds: TimeInterval = 4
    }

    /// `true` while a sync is mid-flight. Drives spinner state on the
    /// Status screen's "Review & sync" button so taps don't feel dead.
    public var isSyncing: Bool = false

    /// Current phase of the sync pipeline. Drives the CTA label so the
    /// user sees what's happening after hashing finishes. Also written
    /// into `syncTimeline` on each transition so the drill-down
    /// `SyncDetailSheet` can show "Preparing 820ms · Fetching 3.2s · …"
    /// as the sync progresses.
    public var syncPhase: SyncPhase = .idle

    /// Six phases mirror the `tick(...)` boundaries inside
    /// `PhotoKitPersistentChangeReconciler` and `performLiveReconciliation`,
    /// so the in-app narration matches the Console timing logs. Order:
    /// `idle` → `preparing` → (`fetchingServer` runs concurrently) →
    /// `hashing` → `reconciling` → `finalizing` → `idle`.
    public enum SyncPhase: Sendable, Equatable {
        /// No sync in flight.
        case idle
        /// Pre-hash setup: `fetchPersistentChanges`, cached-id read,
        /// untracked sweep, deferred-queue snapshot, scope membership.
        /// This is the phase the user used to see as "Indexing…" while
        /// no counter advanced; that opacity was the original motivator
        /// for this expansion.
        case preparing
        /// `listAllAssets` pagination. Runs in parallel with the
        /// pre-hash work, but surfaces as a phase here so the activity
        /// feed has a row per page.
        case fetchingServer
        /// SHA1 work — the existing progress bar covers this.
        case hashing
        /// Engine compute + orphan match.
        case reconciling
        /// Journal append + persistSnapshot + post-sync refresh helpers.
        case finalizing

        /// Display label rendered in `SyncDetailSheet`'s timeline +
        /// header. `idle` collapses to "Idle" so the empty-state row
        /// reads cleanly when the sheet opens before the first sync.
        public var displayName: String {
            switch self {
            case .idle: "Idle"
            case .preparing: "Preparing"
            case .fetchingServer: "Fetching server"
            case .hashing: "Hashing"
            case .reconciling: "Reconciling"
            case .finalizing: "Finalizing"
            }
        }
    }

    /// Forensic ring buffer of recent sync events. Populated by
    /// `appendSyncActivity` from the reconciler's `onPhaseChange`
    /// callback, the hashing throttle, and per-page server fetch
    /// emits. Only `SyncDetailSheet` reads this property — Status'
    /// `syncCard` MUST NOT read `syncActivity.count` or any derivative,
    /// or it would re-render on every emit (potentially 4×/sec
    /// during hashing, since the throttle is 250ms).
    public var syncActivity: [SyncActivity] = []

    /// Cap on `syncActivity` size. ~12s of recent hashing history at
    /// the 250ms throttle, plus phase + server-fetch entries on top.
    /// Sufficient for "is anything happening?" confidence without
    /// growing unboundedly during a multi-minute scan.
    public static let syncActivityCap: Int = 50

    /// One forensic row in the sync activity feed. Newest first.
    public struct SyncActivity: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let timestamp: Date
        public let kind: Kind
        public let detail: String

        public init(
            id: UUID = UUID(),
            timestamp: Date = Date(),
            kind: Kind,
            detail: String
        ) {
            self.id = id
            self.timestamp = timestamp
            self.kind = kind
            self.detail = detail
        }

        public enum Kind: Sendable, Equatable {
            /// New phase started. `detail` is the phase's display name.
            case phaseStart
            /// One asset finished hashing. `detail` is the original
            /// filename; throttled to ≤ one entry per 250ms.
            case hashed
            /// One server-asset page returned. `detail` is short prose
            /// like "page 3 · 1000 assets".
            case fetched
            /// One or more confirmed-deleted stamps landed. `detail` is
            /// short prose like "5 confirmed deleted".
            case stamped
            /// Generic info ("Untracked sweep: 142 ids"). Plain text.
            case note
            /// Degraded mode notice. Renders in warn tone in the sheet.
            case warning
        }
    }

    /// Append `entry` to `syncActivity`, capped at `syncActivityCap`.
    /// Newest first — the sheet renders top-down.
    public func appendSyncActivity(_ entry: SyncActivity) {
        syncActivity.insert(entry, at: 0)
        if syncActivity.count > Self.syncActivityCap {
            syncActivity.removeLast()
        }
    }

    /// Record a sync/trash failure with the right amount of UI noise.
    /// Network-class errors fire the "Couldn't finish" alert exactly
    /// once per disconnected session; subsequent attempts within the
    /// same disconnected window only let the existing
    /// `Degraded.serverDown` banner persist on Status. Non-network
    /// errors always pop the alert (auth, permissions, malformed
    /// input — these need user attention each time).
    ///
    /// Pair with `recordSyncSuccess()` on the happy path so the
    /// dedup flag resets when we're back online and the next
    /// disconnect re-pops.
    public func recordSyncError(_ message: String, isNetworkLike: Bool) {
        if isNetworkLike {
            if !connectionErrorAcknowledged {
                lastError = message
                connectionErrorAcknowledged = true
            }
            // else: banner is already on screen via degraded, no
            // second modal needed.
        } else {
            lastError = message
        }
    }

    /// Reset the network-error dedup flag. Call after any successful
    /// Immich-touching action (sync, trash, restore) so the next
    /// disconnect re-pops the modal exactly once.
    public func recordSyncSuccess() {
        connectionErrorAcknowledged = false
    }

    /// Reset the activity feed and timeline. Called at the start of
    /// each sync so the sheet shows just the current run, not
    /// accumulated history across syncs.
    public func resetSyncNarration() {
        syncActivity.removeAll(keepingCapacity: true)
        syncTimeline.removeAll(keepingCapacity: true)
    }

    /// Per-phase elapsed plus order. Cleared on each sync start;
    /// rebuilt as phases advance. Each transition closes the prior
    /// phase (sets `durationMs`) and appends the new one with
    /// `durationMs == nil`. Final entry stays open until the sync
    /// completes.
    public var syncTimeline: [PhaseEntry] = []

    /// One row in `syncTimeline`. `durationMs == nil` means "in
    /// flight" — `SyncDetailSheet` renders an elapsed timer for the
    /// open phase.
    public struct PhaseEntry: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let phase: SyncPhase
        public let startedAt: Date
        public var durationMs: Int?

        public init(
            id: UUID = UUID(),
            phase: SyncPhase,
            startedAt: Date,
            durationMs: Int? = nil
        ) {
            self.id = id
            self.phase = phase
            self.startedAt = startedAt
            self.durationMs = durationMs
        }
    }

    /// Transition `syncPhase` to `next`, closing the previous phase's
    /// `durationMs` in `syncTimeline` and appending a new in-flight
    /// row. Idempotent on identical phases (no-op when `next` ==
    /// `syncPhase`) so accidental double-emits from the reconciler
    /// don't duplicate timeline rows.
    public func transitionSyncPhase(to next: SyncPhase, at now: Date = Date()) {
        guard syncPhase != next else { return }
        // Close every still-open entry, not just the last one.
        // `performLiveReconciliation` appends a synthetic
        // `.fetchingServer` entry already-closed (its parallel task
        // owns its own duration) BETWEEN an open phase (e.g. still
        // `.preparing` because no hashing happened, or open `.hashing`
        // because a callback raced) and the next sequential
        // transition. The closed synthetic captures the lastIdx slot,
        // so a single-element close skips the still-open earlier
        // phase and leaves it perpetually unchecked in the timeline
        // sheet. Looping over every nil-durationMs entry fixes the
        // common case where exactly one earlier phase is stuck open;
        // it also handles less common races where two open phases
        // overlap.
        for idx in syncTimeline.indices where syncTimeline[idx].durationMs == nil {
            let started = syncTimeline[idx].startedAt
            syncTimeline[idx].durationMs = max(0, Int(now.timeIntervalSince(started) * 1000))
        }
        syncPhase = next
        if next != .idle {
            syncTimeline.append(PhaseEntry(phase: next, startedAt: now))
        }
        // Announce phase changes to VoiceOver. Without this, a screen-
        // reader user starts a sync and gets no audible feedback about
        // its progress until the next interactive element is focused.
        // Polite priority queues behind in-flight speech rather than
        // interrupting, which matches "background activity" vibes
        // better than .high for a multi-second background operation.
        if next != .idle {
            AccessibilityNotification.Announcement("Sync phase: \(next.displayName)").post()
        } else if next == .idle && syncTimeline.last?.phase == .finalizing {
            AccessibilityNotification.Announcement("Sync complete").post()
        }
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

    /// Count of trash intents in the persistent retry queue —
    /// `confirmTrash` calls that failed and are awaiting a successful
    /// retry. Drives the Status pending-trash banner. Refreshed after
    /// every `confirmTrash`, `retryPendingTrashes`, exclude/restore
    /// (which prune intents), and successful `requestSync`.
    public var pendingTrashCount: Int = 0

    /// Subset of `pendingTrashCount` that has already exceeded the
    /// configured `maxRetryAttempts`. These intents stay in the queue
    /// but the auto-drain skips them — the user has to either tap
    /// "Retry now" or address the root cause (e.g., re-verify the
    /// API key). Surfaced in a danger-tone banner separate from the
    /// regular pending banner.
    public var pendingTrashStuckCount: Int = 0

    /// Snapshot of pending-trash intents for the failed-attempts
    /// sheet view. Populated by the host immediately before opening
    /// `.pendingTrashes`; same shape as `deferredQueueEntries`.
    public var pendingTrashIntents: [PendingTrashIntent] = []

    /// State of the Settings → Recovery → Find missed deletions sheet.
    /// `idle` outside the flow; `scanning` while the host fetches the
    /// server list + filters; `loaded` once results are ready;
    /// `error` if the scan failed (network, permission). Mutates on
    /// MainActor — the sheet observes it directly.
    public var missedDeletionsState: MissedDeletionsState = .idle

    public enum MissedDeletionsState: Sendable, Equatable {
        case idle
        case scanning
        case loaded([ServerAsset])
        case error(String)
    }

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

    /// Persisted per-asset hash duration (milliseconds) from prior
    /// sessions on this device. Loaded from UserDefaults at bootstrap
    /// and updated continuously as new emits arrive (see
    /// `AppDependencies` `onHashProgress` callback). Used by
    /// `InitialScanScreen` as a bootstrap ETA value before the live
    /// rate has warmed up — the user sees a number immediately on tap-
    /// Start, displayed at "low confidence" tier until session-only
    /// data dominates. `nil` only on a fresh install (no prior runs).
    public var persistedSyncRate: Double?

    public struct SyncProgress: Sendable, Equatable {
        public let hashed: Int
        public let total: Int
        /// Snapshot of `hashed` captured on the very first emit of the
        /// current sync session — i.e., the count of assets resumed
        /// from prior cache. Used by `InitialScanScreen.etaSeconds` to
        /// compute a session-only rate: `elapsed / (hashed - initialHashed)`.
        /// Without this baseline, a resumed scan that starts at
        /// `hashed=3327` immediately reports `~0s remaining` because
        /// the rate calc divides ~0 elapsed by 3327 cached → wildly
        /// optimistic. Defaults to `0` for fresh syncs / call sites
        /// that don't track baselines.
        public let initialHashed: Int

        public init(hashed: Int, total: Int, initialHashed: Int = 0) {
            self.hashed = hashed
            self.total = total
            self.initialHashed = initialHashed
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
        case albumPicker
        /// `SyncDetailSheet` drill-down. Reads `model.syncActivity`,
        /// `model.syncTimeline`, and the high-level phase. The sheet's
        /// dedicated re-render isolation (only this sheet reads the
        /// activity feed) means opening it during an active sync
        /// doesn't slow Status' redraw cycle.
        case syncDetail
        /// Failed-trash detail sheet — list of intents in the retry
        /// queue with their per-intent error and attempt count. Routed
        /// from the Status pending-trash banner's "Tap to see what
        /// failed" affordance and from the Retry-now path when stuck
        /// intents exist.
        case pendingTrashes
        /// Settings → Recovery → "Find missed deletions" — scans the
        /// Immich server for assets that look like prior iPhone uploads
        /// cairn never observed and aren't currently alive on the
        /// device. Manual flow (not auto-running) because the signal
        /// is filename-based, less precise than the SHA1 pipeline.
        case missedDeletions
        /// Settings → Advanced → "Session sign-in for incremental
        /// sync" — email/password form that calls
        /// `signInForSession`, persists the access token, and rebuilds
        /// the ImmichClient + coordinator so subsequent `/sync/*`
        /// calls go via Bearer auth.
        case sessionSignIn

        public var id: String {
            switch self {
            case .dryRun: "dry-run"
            case .runDetail(let r, _): "run-detail-\(r.id)"
            case .pendingReview: "pending-review"
            case .deferredQueue: "deferred-queue"
            case .albumPicker: "album-picker"
            case .syncDetail: "sync-detail"
            case .pendingTrashes: "pending-trashes"
            case .sessionSignIn: "session-sign-in"
            case .missedDeletions: "missed-deletions"
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
    public let observedAdded: Int
    public let exclusionsAdded: Int
    public let journalLinesAppended: Int
    public let settingsApplied: Bool
    public let serverCount: Int

    public init(observedAdded: Int, exclusionsAdded: Int, journalLinesAppended: Int, settingsApplied: Bool, serverCount: Int) {
        self.observedAdded = observedAdded
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
    /// `trigger` records what initiated the sync. Default-nil callers
    /// (mostly SwiftUI buttons) get treated as `.manualForeground`.
    /// Background-task handlers, Shortcuts intents, and the DEBUG
    /// Fire button pass their specific trigger so the Status journal
    /// tail can show "triggered by background" etc.
    public var requestSync: @Sendable (_ trigger: JournalEntry.SyncTrigger?) async throws -> Void

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

    /// Setup wizard step: request iOS Photos access. Returns the
    /// outcome (`.full`, `.limited`, or `.denied`) rather than a plain
    /// Bool because the wizard renders different copy for `.limited`
    /// and the engine layer applies a safety guard when the user picks
    /// limited Selected Photos.
    ///
    /// Also handles the "user previously denied" case: PhotoKit's
    /// `requestAuthorization` won't re-prompt for `.denied` /
    /// `.restricted`, so this closure deep-links to iOS Settings via
    /// `UIApplication.openSettingsURLString` instead. The user grants
    /// (or doesn't) in Settings and `currentPhotoAuthStatus` re-polls
    /// when the app foregrounds.
    public var requestPhotosAccess: @Sendable () async -> SetupScreen.PhotoAuthOutcome

    /// Read the current Photos auth status without showing any prompt.
    /// Returns `nil` for `.notDetermined` (the user hasn't been asked
    /// yet) and a concrete outcome otherwise. Used by the Photos
    /// onboarding step to pre-fill state on appear and to re-check
    /// after the user returns from iOS Settings.
    public var currentPhotoAuthStatus: @Sendable () async -> SetupScreen.PhotoAuthOutcome?

    /// Setup wizard step: request Background App Refresh.
    public var requestBackgroundRefresh: @Sendable () async -> Bool

    /// Settings → Danger zone. Each is a destructive op the host wires
    /// to its real teardown logic (rebuild observed, delete journal,
    /// clear keychain).
    ///
    /// `resetIndex` clears the *current* (URL, userId) partition's
    /// engine state plus the global content-addressed caches. The
    /// `…AllAccounts` variant additionally walks every other on-disk
    /// partition directory and removes it, plus resets the per-key
    /// activation map. Use the all-accounts form for "nuke everything
    /// cairn has cached on this device" — e.g., wiping a shared
    /// development device or the demo install.
    ///
    /// `clearJournal` is per-key by default: it bumps the current
    /// API key's `activatedAt` to now in the keychain map, hiding
    /// existing journal entries from this key's runs/journal-tail UI.
    /// Other keys' views and the on-disk journal are preserved. The
    /// `…AllKeys` variant is the legacy behavior — physically deletes
    /// the journal file.
    public var resetIndex:             @Sendable () async -> Void
    public var resetIndexAllAccounts:  @Sendable () async -> Void
    public var clearJournal:           @Sendable () async -> Void
    public var clearJournalAllKeys:    @Sendable () async -> Void
    /// Wipe every entry in `ExclusionStore` for the active partition.
    /// Surgical — doesn't touch the index, journal, or credentials.
    /// Use case: testing flows where prior restore-via-cairn auto-
    /// exclusions need to be cleared without nuking the index. Also
    /// callable from the Excluded Assets screen as a "Clear all"
    /// alternative to per-row unexclude.
    public var clearExclusions:        @Sendable () async -> Void
    public var signOut:                @Sendable () async -> Void

    /// Settings → Library. Clears the persistent-change token + the
    /// deferred-hash queue so the next sync re-enumerates the library
    /// from scratch. Lighter than `resetIndex` — observed and
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
    /// cache + token + defer queue + observed + confirmed-deleted so
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

    /// Refresh `ObservedStore` album tags to match the currently
    /// selected scope. Called automatically when
    /// `CairnSettings.indexingScope` changes (host wires this from a
    /// SwiftUI `.onChange`). For `.fullLibrary` scope this is a no-op
    /// — the engine bypasses the tag filter in that mode. For
    /// `.selectedAlbums(ids)`, walks each selected album, looks up
    /// the contained assets' checksums via `LocalHashStore`, and
    /// updates `ObservedStore` tags via `recordObserved`. Idempotent;
    /// safe to call repeatedly.
    public var recomputeScopeTags: @Sendable () async -> Void

    /// Re-render the cached journal tail from the persisted journal.
    /// Wired to a SwiftUI `.onChange(of: settings.timeDisplayFormat)`
    /// so toggling the clock-format picker flips already-cached rows
    /// (which were pre-formatted with the prior setting) in place.
    /// Other settings changes that affect derived state should ride
    /// alongside this if they alter what `refreshJournalTail` emits.
    public var refreshJournalTail: @Sendable () async -> Void

    /// Read the keychain-backed recent-servers list, sorted by
    /// `lastUsedAt` descending. Powers the URL-field autocomplete on
    /// onboarding (and the "switch account" UX once it lands).
    /// Returns `[]` for installs that predate the storage.
    public var recentServers: @Sendable () async -> [RecentServerEntry]

    /// Wipe the recent-servers list. Surfaced as a Settings → Privacy
    /// row so the user can clear the autocomplete history without
    /// taking the heavier "Reset Index — all accounts" path.
    public var clearRecentServers: @Sendable () async -> Void

    /// Drain the persistent retry queue: re-attempt every pending
    /// trash intent that hasn't hit `maxRetryAttempts` yet. Wired
    /// to "Retry now" in the Status banner and called automatically
    /// after every successful `requestSync`. Failures bump
    /// `attemptCount` and update `lastError`; successes remove the
    /// intent from the queue. The host updates
    /// `model.pendingTrashCount` afterward.
    public var retryPendingTrashes: @Sendable () async -> Void

    /// Snapshot the pending-trash retry queue for the detail sheet.
    /// Same shape as `loadDeferredEntries` — host returns the rows,
    /// `CairnAppRoot` stashes them on `model.pendingTrashIntents`
    /// before opening `.pendingTrashes`.
    public var loadPendingTrashes: @Sendable () async -> [PendingTrashIntent]

    /// Drop a single intent from the retry queue without trashing
    /// it. Wired to the per-row trash icon in `PendingTrashesSheet`.
    /// The host removes from store + refreshes counts.
    public var discardPendingTrash: @Sendable (_ id: UUID) async -> Void

    /// DEBUG-only: trigger the same handler code path as the
    /// `BGAppRefreshTask` slot, without iOS's scheduling layer. Useful
    /// for verifying the new logging + scan-completion code on device
    /// when `_simulateLaunchForTaskWithIdentifier:` is unreliable on a
    /// given iOS version (queue assertions). Surfaced via Settings →
    /// Advanced when DEBUG is set. No-op in Release builds.
    public var simulateBackgroundRefresh: @Sendable () async -> Void

    /// Outcome of `signInForSession`. UI shows a result label based on
    /// the case; specific cases drive copy ("Invalid email or
    /// password" vs. "Couldn't reach server").
    public enum SessionSignInResult: Sendable, Equatable {
        case success
        /// HTTP 401 from `/api/auth/login` — wrong email or password.
        case invalidCredentials
        /// HTTP 400 / 405 / 5xx — server reachable but rejected the
        /// request shape. Message is the truncated server body.
        case serverError(code: Int, message: String)
        /// URLError / transport failure. Message is a human-readable
        /// summary (already plain-language via `describeSyncError`).
        case networkError(message: String)
    }

    /// Sign in via `POST /api/auth/login` to acquire a session token
    /// for the `/sync/*` endpoint family (which Immich rejects on
    /// API-key auth). Token is persisted in Keychain and the
    /// in-memory `ImmichClient` is rebuilt so subsequent sync calls
    /// authenticate via Bearer. Returns a result the UI inspects to
    /// surface success / invalid-credentials / transport-failure.
    public var signInForSession: @Sendable (_ email: String, _ password: String) async -> SessionSignInResult

    /// Drop the persisted session token (Keychain row deleted) and
    /// rebuild `ImmichClient` in API-key-only mode. After this, the
    /// sync coordinator falls back to the paginated `searchAllAssets`
    /// path (or, if `useIncrementalServerSync` is on, the missing-
    /// scope warning surfaces — toggling it off avoids the noise).
    public var signOutSession: @Sendable () async -> Void

    /// Settings → Recovery: scan Immich for assets that look like
    /// prior iPhone uploads cairn never observed, then filter against
    /// the currently-alive local library so we don't surface
    /// legitimately-kept photos. Returns a newest-first list.
    /// `MissedDeletionFinder.find` does the heavy lifting; the host
    /// supplies the inputs (server list, observed set, exclusions,
    /// live local filenames).
    ///
    /// `minCreatedAt` and `maxCreatedAt` constrain the server-side
    /// `fileCreatedAt` range. `nil` for either side disables that bound.
    /// The Recovery sheet surfaces these as date pickers so the user
    /// can narrow the window manually — the practical mitigation for
    /// the structural false-positive class (Immich-album uploads with
    /// iPhone-style filenames that were never on this device).
    public var findMissedDeletions: @Sendable (_ minCreatedAt: Date?, _ maxCreatedAt: Date?, _ strictHistorical: Bool) async throws -> [ServerAsset]

    /// Trash a user-picked subset of missed-deletion candidates. Goes
    /// straight to `TrashOrchestrator.run` — no quarantine, no
    /// reconciliation, the user has already reviewed each one.
    public var trashMissedDeletions: @Sendable (_ assets: [ServerAsset]) async throws -> Void

    public init(
        requestSync: @escaping @Sendable (JournalEntry.SyncTrigger?) async throws -> Void = { _ in },
        confirmTrash: @escaping @Sendable () async throws -> Void = {},
        restore: @escaping @Sendable ([String], String) async throws -> Void = { _, _ in },
        exclude: @escaping @Sendable ([String], [String], String) async throws -> Void = { _, _, _ in },
        unexclude: @escaping @Sendable ([String]) async throws -> Void = { _ in },
        approvePending: @escaping @Sendable ([String]) async throws -> Void = { _ in },
        excludePending: @escaping @Sendable ([String]) async throws -> Void = { _ in },
        dismissPending: @escaping @Sendable ([String]) async throws -> Void = { _ in },
        loadDeferredEntries: @escaping @Sendable () async throws -> [DeferredHashEntry] = { [] },
        exportData: @escaping @Sendable (CairnExportScope) async throws -> URL = { _ in URL(fileURLWithPath: "/dev/null") },
        importData: @escaping @Sendable (URL, Bool) async throws -> CairnImportResult = { _, _ in CairnImportResult(observedAdded: 0, exclusionsAdded: 0, journalLinesAppended: 0, settingsApplied: false, serverCount: 0) },
        bulkExcludeRecentOffload: @escaping @Sendable () async throws -> Void = {},
        verifyServer: @escaping @Sendable (String, String) async -> SetupScreen.ServerVerifyResult = { _, _ in
            SetupScreen.ServerVerifyResult(success: true, assetCount: 0, errorMessage: nil)
        },
        retryConnection: @escaping @Sendable () async -> Void = {},
        requestPhotosAccess: @escaping @Sendable () async -> SetupScreen.PhotoAuthOutcome = { .full },
        currentPhotoAuthStatus: @escaping @Sendable () async -> SetupScreen.PhotoAuthOutcome? = { nil },
        requestBackgroundRefresh: @escaping @Sendable () async -> Bool = { true },
        resetIndex: @escaping @Sendable () async -> Void = {},
        resetIndexAllAccounts: @escaping @Sendable () async -> Void = {},
        clearJournal: @escaping @Sendable () async -> Void = {},
        clearJournalAllKeys: @escaping @Sendable () async -> Void = {},
        clearExclusions: @escaping @Sendable () async -> Void = {},
        signOut: @escaping @Sendable () async -> Void = {},
        rescanLibrary: @escaping @Sendable () async -> Void = {},
        persistSettings: @escaping @Sendable (CairnSettings) async -> Void = { _ in },
        dismissInitialScan: @escaping @Sendable () async -> Void = {},
        startOverInitialScan: @escaping @Sendable () async -> Void = {},
        forceDrainDeferred: @escaping @Sendable () async -> Void = {},
        replayOnboarding: @escaping @Sendable () async -> Void = {},
        recomputeScopeTags: @escaping @Sendable () async -> Void = {},
        refreshJournalTail: @escaping @Sendable () async -> Void = {},
        recentServers: @escaping @Sendable () async -> [RecentServerEntry] = { [] },
        clearRecentServers: @escaping @Sendable () async -> Void = {},
        retryPendingTrashes: @escaping @Sendable () async -> Void = {},
        loadPendingTrashes: @escaping @Sendable () async -> [PendingTrashIntent] = { [] },
        discardPendingTrash: @escaping @Sendable (UUID) async -> Void = { _ in },
        findMissedDeletions: @escaping @Sendable (Date?, Date?, Bool) async throws -> [ServerAsset] = { _, _, _ in [] },
        trashMissedDeletions: @escaping @Sendable ([ServerAsset]) async throws -> Void = { _ in },
        simulateBackgroundRefresh: @escaping @Sendable () async -> Void = {},
        signInForSession: @escaping @Sendable (String, String) async -> SessionSignInResult = { _, _ in .success },
        signOutSession: @escaping @Sendable () async -> Void = {}
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
        self.currentPhotoAuthStatus = currentPhotoAuthStatus
        self.requestBackgroundRefresh = requestBackgroundRefresh
        self.resetIndex = resetIndex
        self.resetIndexAllAccounts = resetIndexAllAccounts
        self.clearJournal = clearJournal
        self.clearJournalAllKeys = clearJournalAllKeys
        self.clearExclusions = clearExclusions
        self.signOut = signOut
        self.rescanLibrary = rescanLibrary
        self.persistSettings = persistSettings
        self.dismissInitialScan = dismissInitialScan
        self.startOverInitialScan = startOverInitialScan
        self.forceDrainDeferred = forceDrainDeferred
        self.replayOnboarding = replayOnboarding
        self.recomputeScopeTags = recomputeScopeTags
        self.refreshJournalTail = refreshJournalTail
        self.recentServers = recentServers
        self.clearRecentServers = clearRecentServers
        self.retryPendingTrashes = retryPendingTrashes
        self.loadPendingTrashes = loadPendingTrashes
        self.discardPendingTrash = discardPendingTrash
        self.findMissedDeletions = findMissedDeletions
        self.trashMissedDeletions = trashMissedDeletions
        self.simulateBackgroundRefresh = simulateBackgroundRefresh
        self.signInForSession = signInForSession
        self.signOutSession = signOutSession
    }

    /// All-no-op closures with successful default returns. Use in previews
    /// to render `CairnAppRoot` without a host.
    public static let preview: CairnAppActions = CairnAppActions()
}
