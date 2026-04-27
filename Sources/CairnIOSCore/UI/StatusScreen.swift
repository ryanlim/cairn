import SwiftUI

/// The default landing screen. Mirrors the prototype's `screens/status.jsx`.
///
/// Surfaces (top-to-bottom):
///   1. Wordmark + status chip ("synced" / "offline" / "limited" / etc.)
///   2. Subhead: "reconciling iPhone 15 Pro against <server>"
///   3. Optional degraded banner (server down / auth stale / Photos limited / tiny library)
///   4. Optional state banner (threshold tripped / first-sync dry-run nudge)
///   5. Pending-candidates card with the primary "Review & sync" CTA
///   6. Library snapshot — three stats (on iPhone, indexed, on server)
///   7. Recent runs — compact timeline (4 most recent + "see all")
///   8. Latest journal — monospace tail
///
/// State model:
///   - `appState`: steady (default) | dryRun (first-sync nudge) | thresholdTripped
///   - `degraded`: none | serverDown | authStale | photosLimited | tinyLibrary
///   These are orthogonal — degraded preempts the CTA, appState colors banners.
///
/// Microcopy is verbatim from the prototype. See HANDOFF.md "Keep these
/// copies verbatim" — don't paraphrase without designer review.
public struct StatusScreen: View {

    public enum AppState: Sendable {
        case steady
        case dryRun
        case thresholdTripped
    }

    public enum Degraded: Sendable {
        case none
        case serverDown
        case authStale
        case photosLimited
        case tinyLibrary
    }

    public let appState: AppState
    public let degraded: Degraded
    public let library: CairnFixtures.LibrarySize
    public let runs: [CairnFixtures.RunFixture]
    public let journalTail: [CairnFixtures.JournalTailEntry]
    public let serverHost: String
    public let maxDeletePercent: Double
    /// Minimum candidate count before the percent-threshold rail
    /// engages. Surfaced on the sync card as the "(≥N items)" qualifier
    /// next to the percent cap so the user sees both gates together.
    public let minDeleteFloor: Int
    /// Total count of candidates awaiting the user's call (held +
    /// unconfirmed). When > 0 the screen surfaces a compact pending-review
    /// card directly below the sync card.
    public let pendingReviewCount: Int
    /// Items confirmed-deleted but still within the quarantine window.
    /// Shown as a secondary line under the big number.
    public let quarantineCount: Int
    /// Earliest date a quarantined item becomes eligible, if any.
    /// Drives the "earliest eligible in N days" annotation.
    public let earliestQuarantineEligible: Date?
    /// Sum of every bucket awaiting user action (held-by-quarantine +
    /// pending-review + eligible-to-trash candidates). Drives the
    /// backlog-alert banner when it crosses
    /// `backlogAlertThreshold`.
    public let deletionBacklog: Int
    /// Count threshold above which the backlog banner appears. 0
    /// disables the banner entirely.
    public let backlogAlertThreshold: Int
    /// Optional transient toast (e.g. "Library up to date") surfaced as
    /// a Callout above the sync card after a no-op sync. Host is
    /// responsible for clearing after the auto-dismiss window.
    public let syncToast: CairnAppModel.SyncToast?
    /// Number of locally-restored photos that were previously trashed
    /// via cairn within Immich's 30-day hard-delete window. Drives a
    /// warn-tone banner so the user knows to restore on Immich too —
    /// the Immich mobile app silently no-ops the upload while the
    /// asset is in Immich trash with the same SHA1.
    public let restoredAfterCairnTrashCount: Int
    /// User dismissed the "restored after trash" banner. Host clears
    /// `model.restoredAfterCairnTrash` to make this fire — next sync
    /// re-evaluates, so if the conditions still hold, the banner returns.
    public let onDismissRestoredAfterCairnTrash: () -> Void
    /// Number of inferred orphans from the most recent scan — server
    /// assets matched by filename + creationDate against locally-
    /// observed metadata where cairn never finished hashing the asset
    /// (typically the cull-burst case: take a photo, Immich uploads,
    /// user deletes within seconds). Drives a warn-tone banner that
    /// routes the user to Pending Review.
    public let inferredOrphanCount: Int
    /// Tap handler for the orphan banner. Routes to Pending Review.
    public let onOpenInferredOrphans: () -> Void
    /// When true, the user dismissed the initial-scan screen and the
    /// library hasn't been indexed yet. Surfaces a persistent callout
    /// prompting the user to begin or resume the scan.
    public let initialScanPending: Bool
    /// Handler for the "Begin initial scan" affordance on that banner.
    public let onResumeInitialScan: () -> Void
    /// Current deferred-hash queue summary. When `count > 0` Status
    /// surfaces a banner with a "Hash now" affordance so the user
    /// doesn't have to dig into Settings to clear the queue.
    public let deferredQueue: CairnAppModel.DeferredQueueSummary
    public let onForceDrainDeferred: () -> Void
    /// Action wired to the "Retry" button in the
    /// `Immich server unreachable` banner. Re-pings the configured
    /// server and refreshes `connectionStatus` + `degraded` based on
    /// the result.
    public let onRetryConnection: () -> Void
    /// True while `actions.requestSync` is mid-flight. Drives spinner +
    /// disabled state on the CTA so taps don't feel dead.
    public let isSyncing: Bool
    /// Optional hashing progress, surfaced in the CTA label when the
    /// full-enumeration path is running ("Hashing 1,245 / 4,218").
    public let syncProgress: (hashed: Int, total: Int)?
    /// When the last reconciliation ran. Surfaces as "Last checked N ago"
    /// so stale data has context.
    public let lastCheckedAt: Date?
    /// Required API permissions the key is missing. Empty = all good.
    public let missingPermissions: [String]
    /// Live indexed count (checksums in the hash store).
    public let indexed: Int
    public let syncPhase: CairnAppModel.SyncPhase
    public let onStartSync: () -> Void
    public let onCancelSync: () -> Void
    public let onOpenRun: (CairnFixtures.RunFixture) -> Void
    /// Tapping a journal-tail row whose `runId` matches a real run
    /// opens the run-detail sheet. The host (CairnAppRoot) maps
    /// `runId → RunFixture` and routes through `presentRunDetail`.
    /// Rows with no matching run are rendered the same but
    /// non-tappable.
    public let onJournalRowTap: (String) -> Void
    public let onSeeAllRuns: () -> Void
    public let onOpenPendingReview: () -> Void
    /// Tapping the big "ready to trash" number opens a read-only view of
    /// the current delete queue (DryRunSheet with cached reconciliation).
    public let onOpenDeleteQueue: () -> Void
    /// Tapping the deferred queue line opens the queue detail sheet.
    public let onOpenDeferredQueue: () -> Void

    @Environment(\.cairnTokens) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var journalExpanded: Bool = false
    /// Filter chip on the journal-tail card. ON by default — routine
    /// no-op syncs are noise. `@AppStorage` so the user's choice
    /// survives tab navigation and relaunch.
    @AppStorage("cairn.status.hideRoutineSyncs")
    private var hideRoutineSyncs: Bool = true
    /// Latches the count at which the user dismissed the banner so
    /// it doesn't re-show until the underlying state *changes* (more
    /// items accrue, or some get cleared). `@AppStorage` persists
    /// the value to UserDefaults, which survives view re-creation
    /// (tab navigation, background/foreground) and app relaunch —
    /// so a deliberate dismissal isn't un-dismissed by just coming
    /// back to the screen. Sentinel value `-1` means "never
    /// dismissed"; real counts are always >= 0, so `stored == count`
    /// cleanly tests "dismissed at this exact value".
    @AppStorage("cairn.status.dismissedBacklogAtCount")
    private var dismissedBacklogAtCount: Int = -1

    public init(
        appState: AppState = .steady,
        degraded: Degraded = .none,
        library: CairnFixtures.LibrarySize = CairnFixtures.medium,
        runs: [CairnFixtures.RunFixture] = CairnFixtures.runs,
        journalTail: [CairnFixtures.JournalTailEntry] = CairnFixtures.journalTail,
        serverHost: String = "immich.home.arpa",
        maxDeletePercent: Double = 1.0,
        minDeleteFloor: Int = 5,
        pendingReviewCount: Int = 0,
        quarantineCount: Int = 0,
        earliestQuarantineEligible: Date? = nil,
        deletionBacklog: Int = 0,
        backlogAlertThreshold: Int = 25,
        syncToast: CairnAppModel.SyncToast? = nil,
        restoredAfterCairnTrashCount: Int = 0,
        onDismissRestoredAfterCairnTrash: @escaping () -> Void = {},
        inferredOrphanCount: Int = 0,
        onOpenInferredOrphans: @escaping () -> Void = {},
        initialScanPending: Bool = false,
        isSyncing: Bool = false,
        syncProgress: (hashed: Int, total: Int)? = nil,
        lastCheckedAt: Date? = nil,
        missingPermissions: [String] = [],
        indexed: Int = 0,
        syncPhase: CairnAppModel.SyncPhase = .idle,
        onStartSync: @escaping () -> Void = {},
        onCancelSync: @escaping () -> Void = {},
        onOpenRun: @escaping (CairnFixtures.RunFixture) -> Void = { _ in },
        onJournalRowTap: @escaping (String) -> Void = { _ in },
        onSeeAllRuns: @escaping () -> Void = {},
        onOpenPendingReview: @escaping () -> Void = {},
        onOpenDeleteQueue: @escaping () -> Void = {},
        onOpenDeferredQueue: @escaping () -> Void = {},
        onResumeInitialScan: @escaping () -> Void = {},
        deferredQueue: CairnAppModel.DeferredQueueSummary = .empty,
        onForceDrainDeferred: @escaping () -> Void = {},
        onRetryConnection: @escaping () -> Void = {}
    ) {
        self.appState = appState
        self.degraded = degraded
        self.library = library
        self.runs = runs
        self.journalTail = journalTail
        self.serverHost = serverHost
        self.maxDeletePercent = maxDeletePercent
        self.minDeleteFloor = minDeleteFloor
        self.pendingReviewCount = pendingReviewCount
        self.quarantineCount = quarantineCount
        self.earliestQuarantineEligible = earliestQuarantineEligible
        self.deletionBacklog = deletionBacklog
        self.backlogAlertThreshold = backlogAlertThreshold
        self.syncToast = syncToast
        self.restoredAfterCairnTrashCount = restoredAfterCairnTrashCount
        self.onDismissRestoredAfterCairnTrash = onDismissRestoredAfterCairnTrash
        self.inferredOrphanCount = inferredOrphanCount
        self.onOpenInferredOrphans = onOpenInferredOrphans
        self.initialScanPending = initialScanPending
        self.isSyncing = isSyncing
        self.syncProgress = syncProgress
        self.lastCheckedAt = lastCheckedAt
        self.missingPermissions = missingPermissions
        self.indexed = indexed
        self.syncPhase = syncPhase
        self.onStartSync = onStartSync
        self.onCancelSync = onCancelSync
        self.onOpenRun = onOpenRun
        self.onJournalRowTap = onJournalRowTap
        self.onSeeAllRuns = onSeeAllRuns
        self.onOpenPendingReview = onOpenPendingReview
        self.onOpenDeleteQueue = onOpenDeleteQueue
        self.onOpenDeferredQueue = onOpenDeferredQueue
        self.onResumeInitialScan = onResumeInitialScan
        self.deferredQueue = deferredQueue
        self.onForceDrainDeferred = onForceDrainDeferred
        self.onRetryConnection = onRetryConnection
    }

    private var pct: Double {
        guard library.matched > 0 else { return 0 }
        return (Double(library.candidates) / Double(library.matched)) * 100
    }
    private var withinBudget: Bool { pct <= maxDeletePercent }
    private var syncBlocked: Bool {
        switch degraded {
        case .serverDown, .authStale, .photosLimited: return true
        case .none, .tinyLibrary: return false
        }
    }

    /// Compound value whose changes trigger the banner-area spring
    /// animation. Every boolean below maps to one banner's
    /// visibility gate. When any flips, SwiftUI re-layouts the
    /// enclosing VStack and the paired `.transition` on each
    /// banner plays in-spring.
    private var bannerVisibilityKey: [Bool] {
        [
            degraded != .none,
            appState != .steady,
            initialScanPending,
            backlogAlertThreshold > 0 && deletionBacklog >= backlogAlertThreshold && !initialScanPending && dismissedBacklogAtCount != deletionBacklog,
            syncToast != nil,
            restoredAfterCairnTrashCount > 0,
            inferredOrphanCount > 0,
        ]
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                wordmarkHeader
                degradedBanner
                missingPermissionsBanner
                stateBanner
                initialScanPendingBanner
                restoredAfterCairnTrashBanner
                inferredOrphanBanner
                backlogAlertBanner
                syncToastBanner
                syncCard
                KeylineSection("Library")
                libraryStats
                KeylineSection("Recent runs")
                recentRuns
                KeylineSection("Latest journal")
                journalTailCard
                Spacer(minLength: 24)
            }
            // Canonical spring timing shared across the app —
            // see `cairnBannerAnimation(value:)` in
            // CairnPrimitives.swift. Without this, the
            // `.transition(.cairnBanner)` modifiers on individual
            // banners are no-ops (SwiftUI only plays transitions
            // inside an animated context).
            .cairnBannerAnimation(value: bannerVisibilityKey)
        }
        .background(t.bg)
    }

    // MARK: - Header

    private var wordmarkHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                CairnWordmark(size: 28, variant: .adaptive)
                Spacer()
                statusChip
            }
            Text(reconcilingSubhead)
                .font(.system(size: 13))
                .foregroundStyle(t.textMuted)
        }
        .padding(.horizontal, 20)
        .padding(.top, 60)
        .padding(.bottom, 18)
    }

    private var reconcilingSubhead: AttributedString {
        var s = AttributedString("reconciling ")
        s.foregroundColor = t.textMuted
        var device = AttributedString("iPhone 15 Pro")
        device.foregroundColor = t.textBody
        var middle = AttributedString(" against ")
        middle.foregroundColor = t.textMuted
        var host = AttributedString(serverHost)
        host.foregroundColor = t.textHint
        host.font = .system(size: 12, design: .monospaced)
        return s + device + middle + host
    }

    private var statusChip: some View {
        let (label, tone): (String, ChipTone) = {
            switch degraded {
            case .none:           return ("synced", .verified)
            case .serverDown:     return ("offline", .danger)
            case .authStale:      return ("auth expired", .danger)
            case .photosLimited:  return ("limited", .danger)
            case .tinyLibrary:    return ("small library", .info)
            }
        }()
        return Chip(label: label, tone: tone)
    }

    // MARK: - Banners

    /// Alias to the module-wide `.cairnBanner` transition. Kept as a
    /// per-instance computed property so the call sites below don't
    /// have to change — `bannerTransition` is used in ~6 places in
    /// this file and swapping to `.cairnBanner` at each was noisier
    /// than keeping the shim.
    private var bannerTransition: AnyTransition { .cairnBanner }

    @ViewBuilder
    private var missingPermissionsBanner: some View {
        Group { if !missingPermissions.isEmpty {
            Callout(.pending, icon: "exclamationmark.shield") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API key missing permissions").fontWeight(.semibold)
                    Text("Required: \(missingPermissions.joined(separator: ", ")). Update your key in Immich to include these scopes.")
                        .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            .transition(bannerTransition)
        } }
    }

    private var degradedBanner: some View {
        Group { switch degraded {
        case .none: EmptyView()
        case .serverDown:
            Callout(.danger, icon: "server.rack") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Immich server unreachable").fontWeight(.semibold)
                    (Text("Tried ") + Text(serverHost).font(.system(size: 12, design: .monospaced)) + Text(" three times over 2m. Check VPN or server health, then retry."))
                        .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                    Button(action: onRetryConnection) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Retry connection")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(t.dangerInk)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(t.dangerSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(CairnPressStyle())
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            .transition(bannerTransition)
        case .authStale:
            Callout(.pending, icon: "key") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API key rejected").fontWeight(.semibold)
                    Text("Server returned 401. Your key may have been revoked or expired. Paste a new one in Settings.")
                        .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            .transition(bannerTransition)
        case .photosLimited:
            Callout(.pending, icon: "photo.on.rectangle.angled") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Photos access is Limited").fontWeight(.semibold)
                    (Text("With Limited access, ") + .cairnWord + Text(" only sees the assets you picked. Everything else looks “missing” and would be flagged for deletion — dangerous. Grant Full access to continue."))
                        .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            .transition(bannerTransition)
        case .tinyLibrary:
            Callout(.pending, icon: "info.circle") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Library is small").fontWeight(.semibold)
                    Text("Your iPhone has a small photo library. With fewer than ~200 assets, any single deletion is a large fraction of the library and the percent-based safety rail can't protect you as well. You can still sync — just treat the first run carefully.")
                        .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            .transition(bannerTransition)
        } }
    }

    @ViewBuilder
    private var stateBanner: some View {
        switch appState {
        case .thresholdTripped:
            let tripCount = max(6, Int(Double(library.matched) * 0.023))
            Callout(.danger, icon: "exclamationmark.triangle") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Safety rail tripped").fontWeight(.semibold)
                    (Text("Last run would have trashed ") + Text("\(tripCount) assets").bold() + Text(" (") + Text("2.3%").bold() + Text(" of matched), above your ") + Text(String(format: "%.1f%%", maxDeletePercent)).bold() + Text(" cap. Review before re-running."))
                        .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            .transition(bannerTransition)
        case .dryRun:
            Callout(.info, icon: "info.circle") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("First sync is a dry-run").fontWeight(.semibold)
                    Text("We'll show exactly what would be trashed. Nothing gets touched on your server until you confirm.")
                        .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            .transition(bannerTransition)
        case .steady:
            EmptyView()
        }
    }

    @ViewBuilder
    private var initialScanPendingBanner: some View {
        if initialScanPending {
            Button(action: onResumeInitialScan) {
                Callout(.pending, icon: "sparkle.magnifyingglass") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Initial scan pending").fontWeight(.semibold)
                        (Text("Tap to index your library. ")
                            + .cairnWord
                            + Text(" needs a one-time SHA1 pass before it can tell real deletions apart from sync hiccups."))
                            .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.bottom, 12)
            .transition(bannerTransition)
        }
    }

    /// Escalation banner for a large accumulated backlog of confirmed
    /// deletions + pending-review items. Gated by the user's
    /// configurable threshold (0 disables). The pending-candidates
    /// card already surfaces the raw count; this banner adds a
    /// louder "you've let a lot pile up" signal for users who open
    /// cairn infrequently. Tapping routes to the most relevant
    /// destination: Pending Review if there's anything to review,
    /// otherwise it opens the dry-run sheet for eligible-to-trash
    /// candidates.
    @ViewBuilder
    private var backlogAlertBanner: some View {
        if backlogAlertThreshold > 0
            && deletionBacklog >= backlogAlertThreshold
            && !initialScanPending
            && dismissedBacklogAtCount != deletionBacklog {
            Button(action: backlogTapTarget) {
                Callout(.pending, icon: "bell.badge") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(deletionBacklog) deletions waiting").fontWeight(.semibold)
                        Text("Since your last trash run. Tap to review, or swipe to dismiss.")
                            .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.bottom, 12)
            .cairnSwipeToDismiss {
                dismissedBacklogAtCount = deletionBacklog
            }
            .transition(bannerTransition)
        }
    }

    /// Warning banner for "user restored locally what cairn already
    /// trashed on Immich." The Immich mobile app silently no-ops the
    /// re-upload while the asset is still in Immich trash with the
    /// same SHA1; after the 30-day hard-delete clock fires, the photo
    /// is gone server-side. Surfacing the count gives the user a
    /// chance to restore on Immich too. Dismissible — next sync
    /// re-evaluates.
    @ViewBuilder
    private var restoredAfterCairnTrashBanner: some View {
        if restoredAfterCairnTrashCount > 0 {
            Callout(.pending, icon: "arrow.uturn.backward.circle") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(restoredAfterCairnTrashTitle).fontWeight(.semibold)
                    Text("Open Immich → Trash to restore them there too. They'll hard-delete after 30 days.")
                        .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            .cairnSwipeToDismiss { onDismissRestoredAfterCairnTrash() }
            .transition(bannerTransition)
        }
    }

    /// Title text for the restored-after-trash banner, with proper
    /// singular/plural handling. "1 photo" reads better than "1 photos."
    private var restoredAfterCairnTrashTitle: String {
        let n = restoredAfterCairnTrashCount
        let noun = n == 1 ? "photo" : "photos"
        return "\(n) restored \(noun) also trashed in Immich"
    }

    /// Warn-tone banner for inferred orphans — server assets matched by
    /// filename + creationDate where cairn observed but never finished
    /// hashing the asset (typical cull-burst: photo taken, Immich
    /// uploads, user deletes within seconds). Tapping routes to Pending
    /// Review where the user can approve or exclude each. Not
    /// dismissible: dismissing wouldn't clear the underlying state, and
    /// the count moves down naturally as the user reviews.
    @ViewBuilder
    private var inferredOrphanBanner: some View {
        if inferredOrphanCount > 0 {
            Button(action: onOpenInferredOrphans) {
                Callout(.pending, icon: "questionmark.diamond") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(inferredOrphanTitle).fontWeight(.semibold)
                        (Text("Uploaded from this iPhone, then deleted before ") + .cairnWord + Text(" could index. Review before trashing."))
                            .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.bottom, 12)
            .transition(bannerTransition)
        }
    }

    private var inferredOrphanTitle: String {
        let n = inferredOrphanCount
        let noun = n == 1 ? "likely orphan" : "likely orphans"
        return "\(n) \(noun) on Immich"
    }

    /// Smart routing for the backlog banner: pending review first,
    /// else the dry-run sheet for eligible-to-trash candidates.
    private func backlogTapTarget() {
        if pendingReviewCount > 0 {
            onOpenPendingReview()
        } else {
            onStartSync()
        }
    }

    /// Surfaces the deferred-hash queue on Status when it's non-empty,
    /// with a "Hash now" button that runs the unlimited-drain path.
    /// Without this, the queue is only visible in Settings — users
    /// land on Status after an initial scan, see the same "Indexed"
    /// number across repeated syncs, and wonder why it's stuck.
    ///
    /// Suppressed while `initialScanPending`: an aborted earlier scan
    /// can leave orphan deferred rows on disk, and showing both the
    /// "Initial scan pending" banner AND a "queued for background
    /// hashing" banner reads as contradictory. Once the user runs
    /// Body text for the `upToDate` toast. Differentiates the
    /// `indexed < total` reasons so the user isn't told "the rest will
    /// catch up" when some of "the rest" are permanently above the
    /// size ceiling and won't catch up. Categories surfaced:
    ///   - queued: in the deferred queue, under-ceiling → real
    ///     background-hash backlog
    ///   - above-cap: in the deferred queue, exceeds the user's iCloud
    ///     download ceiling → permanent unless the cap is raised
    ///   - untracked: visible in the library but neither indexed nor
    ///     in the queue → coverage gap, can't say what'll happen
    private func upToDateSubline(indexed: Int, total: Int) -> Text {
        let count = Text("\(indexed) of \(total)").bold()
        if indexed >= total {
            return Text("Nothing new to trash. ") + count + Text(" assets indexed.")
        }
        let gap = max(0, total - indexed)
        let queued = deferredQueue.count
        let aboveCap = deferredQueue.aboveCeiling
        let untracked = max(0, gap - queued - aboveCap)

        var clauses: [String] = []
        if queued > 0 { clauses.append("\(queued) queued for background hashing") }
        if aboveCap > 0 { clauses.append("\(aboveCap) above your size cap") }
        if untracked > 0 { clauses.append("\(untracked) not yet processed") }

        let suffix = clauses.isEmpty ? "." : " — " + clauses.joined(separator: ", ") + "."
        return Text("Nothing new to trash. ") + count + Text(" assets indexed") + Text(suffix)
    }

    @ViewBuilder
    private var syncToastBanner: some View {
        if let toast = syncToast {
            Group {
                switch toast {
                case .upToDate(let indexed, let total):
                    Callout(.verified, icon: "checkmark.seal") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Library in sync").fontWeight(.semibold)
                            upToDateSubline(indexed: indexed, total: total)
                                .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                case .journalCleared:
                    Callout(.verified, icon: "trash") {
                        Text("Journal cleared.").fontWeight(.semibold)
                    }
                case .indexReset:
                    Callout(.verified, icon: "arrow.counterclockwise") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Index reset").fontWeight(.semibold)
                            Text("Next sync will re-enumerate your library from scratch.")
                                .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                case .rescanQueued:
                    Callout(.verified, icon: "arrow.triangle.2.circlepath") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Rescan queued").fontWeight(.semibold)
                            Text("The initial-scan screen will run a fresh full enumeration.")
                                .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            .transition(bannerTransition)
        }
    }

    // MARK: - Sync card

    /// Three-band color for the "ready to trash" hero number. Tied to
    /// the user's existing `backlogAlertThreshold` setting so the
    /// red/yellow boundary lines up with the alert they've already
    /// opted into:
    ///   - 0 candidates → verified (green) — nothing to act on
    ///   - 1 to threshold-1 → pending (yellow) — accumulating
    ///   - ≥ threshold → danger (red) — past the user's alert line
    /// When the threshold is 0 (alerts disabled), fall back to a
    /// two-band "0 vs non-zero" mapping using yellow for any positive
    /// count — there's no calibrated red boundary to fall back to.
    private var readyToTrashColor: Color {
        let n = library.candidates
        if n == 0 { return t.verifiedInk }
        if backlogAlertThreshold > 0 && n >= backlogAlertThreshold { return t.dangerInk }
        return t.pendingInk
    }

    private var syncCard: some View {
        CairnCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("READY TO TRASH")
                            .font(.system(size: 11, weight: .semibold)).tracking(0.9)
                            .foregroundStyle(t.textMuted)
                        Button(action: { if library.candidates > 0 { onOpenDeleteQueue() } }) {
                            Text("\(library.candidates)")
                                .font(.system(size: 52, weight: .semibold).monospacedDigit())
                                .tracking(-2.0)
                                .foregroundStyle(readyToTrashColor)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .disabled(library.candidates == 0)
                        .accessibilityLabel("\(library.candidates) ready to trash. Tap to view.")
                        (Text("would move to ") + Text("Immich's Trash").foregroundStyle(t.text) + Text(" on next run"))
                            .font(.system(size: 13))
                            .foregroundStyle(t.textMuted)
                            .padding(.top, 2)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Chip(label: String(format: "%.2f%% of synced", pct),
                             tone: withinBudget ? .verified : .pending)
                        HStack(spacing: 0) {
                            Text(String(format: "stops above %.1f%% past %d items", maxDeletePercent, minDeleteFloor))
                                .font(.system(size: 11))
                                .foregroundStyle(t.textMuted)
                            HelpPopover {
                                Text("**Two safety rails on every run.** Both must be true for cairn to actually move assets to Immich's Trash.")

                                Text("**Percent threshold** — a run aborts if it would trash more than \(String(format: "%.1f%%", maxDeletePercent)) of your synced photos. Catches runaway deletions like accidental select-all, iCloud library glitches, etc.")
                                    .padding(.top, 4)

                                Text("**Count floor** — the percent check only engages when a run would move more than \(minDeleteFloor) assets. At or below the floor the run proceeds without the percent check, so small real deletions on small libraries aren't blocked by 1% rounding to 1–2 photos.")
                                    .padding(.top, 4)

                                Text("Adjust both in Settings → Safety rails. Raise the floor if your library is small, or tighten the percent if you want stricter brakes.")
                                    .padding(.top, 4)
                            }
                        }
                    }
                }

                if !isSyncing, let checked = lastCheckedAt {
                    Text("Last checked \(Self.relativeTime(checked))")
                        .font(.system(size: 11))
                        .foregroundStyle(t.textHint)
                }

                if quarantineCount > 0 {
                    quarantineLine
                }

                // Dual-purpose progress bar:
                //   - During an active sync with a known total (full
                //     enumeration, or a drain), show hashed-of-total
                //     so the user watches work tick by — was
                //     previously only visible on the Initial Scan
                //     screen; now surfaces on Status too.
                //   - Otherwise, show the original "candidates as a
                //     fraction of the `maxDeletePercent` cap", which
                //     is the safety-rail budget indicator.
                if isSyncing, let progress = syncProgress, progress.total > 0 {
                    ProgressBar(
                        fraction: min(1.0, Double(progress.hashed) / Double(progress.total)),
                        tone: .pending
                    )
                    ProcessingBreakdown(indexed: indexed, deferredQueueCount: deferredQueue.count, processed: progress.hashed)
                } else {
                    ProgressBar(
                        fraction: min(1.0, pct / max(0.001, maxDeletePercent)),
                        tone: withinBudget ? .pending : .danger
                    )
                }

                if !isSyncing {
                    deferredQueueLine
                }

                Button(action: { if !syncBlocked && !isSyncing { onStartSync() } }) {
                    HStack(spacing: 8) {
                        if isSyncing {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                                .tint(t.primaryInk)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        Text(syncCtaLabel)
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(syncBlocked ? t.textMuted : t.primaryInk)
                    .background(syncBlocked ? t.surfaceAlt : t.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(CairnPressStyle())
                .disabled(syncBlocked || isSyncing)
                .opacity(syncBlocked ? 0.85 : 1)

                // Cancel affordance during sync. Separate from the locked
                // primary button so there's no ambiguity about what the
                // tap does — the primary renders progress, this one
                // interrupts. Kept subtle (text button, muted tone) so
                // it doesn't steal attention from the progress itself.
                if isSyncing {
                    Button(action: onCancelSync) {
                        Text("Cancel")
                            .font(.system(size: 13, weight: .semibold))
                            .tracking(0.66)
                            .foregroundStyle(t.dangerInk)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(CairnPressStyle())
                    .accessibilityLabel("Cancel sync")

                    SyncPhaseChecklist(phase: syncPhase)
                }
            }
            .padding(18)
        }
        .padding(.bottom, 14)
    }

    private var quarantineLine: some View {
        Button(action: onOpenPendingReview) {
            HStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(t.pendingInk)
                    Text("\(quarantineCount)")
                        .font(.system(size: 28, weight: .semibold).monospacedDigit())
                        .foregroundStyle(t.pendingInk)
                    Text("in quarantine")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(t.pendingInk)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if let earliest = earliestQuarantineEligible {
                        Text("next in \(Self.relativeDay(earliest))")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(t.textMuted)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(t.textMuted)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(t.pendingSoft.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(CairnPressStyle())
        .accessibilityLabel("\(quarantineCount) items in quarantine. Tap to review.")
    }

    @ViewBuilder
    private var deferredQueueLine: some View {
        let total = deferredQueue.count + deferredQueue.aboveCeiling
        if total > 0 {
            Button(action: onOpenDeferredQueue) {
                HStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(t.infoInk)
                    if deferredQueue.count > 0 {
                        Text("\(deferredQueue.count.formatted(.number)) not yet indexed")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(t.textMuted)
                    }
                    if deferredQueue.aboveCeiling > 0 {
                        if deferredQueue.count > 0 {
                            Text("·").font(.system(size: 13)).foregroundStyle(t.textHint)
                        }
                        Text("\(deferredQueue.aboveCeiling.formatted(.number)) above cap")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(t.textHint)
                    }
                    Spacer()
                    if deferredQueue.count > 0 {
                        Button(action: onForceDrainDeferred) {
                            Text("Hash now")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(t.primaryInk)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(t.primary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(CairnPressStyle())
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(t.textMuted)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
                .background(t.infoSoft.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(CairnPressStyle())
        }
    }

    static func relativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }

    static func relativeDay(_ date: Date) -> String {
        let days = max(0, Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0)
        if days == 0 { return "<1d" }
        if days == 1 { return "1 day" }
        return "\(days) days"
    }

    private var syncCtaLabel: String {
        if syncBlocked { return "Can’t sync — see banner" }
        if isSyncing {
            switch syncPhase {
            case .hashing:
                if let progress = syncProgress, progress.total > 0 {
                    return "Processing \(progress.hashed.formatted(.number)) / \(progress.total.formatted(.number))"
                }
                return "Indexing…"
            case .fetchingServer:
                return "Fetching server data…"
            case .reconciling:
                return "Reconciling…"
            case .idle:
                return "Syncing…"
            }
        }
        if appState == .thresholdTripped { return "Review before syncing" }
        return "Review & sync"
    }

    // MARK: - Library stats

    private var libraryStats: some View {
        CairnCard {
            HStack(spacing: 16) {
                Stat(label: "On iPhone", value: library.local.formatted(.number), sub: "current")
                Rectangle().fill(t.divider).frame(width: 0.5)
                Stat(label: "Indexed", value: library.indexed.formatted(.number), sub: "SHA1 set", color: t.verifiedInk)
                Rectangle().fill(t.divider).frame(width: 0.5)
                Stat(label: "On server", value: library.server.formatted(.number),
                     sub: "\(library.matched.formatted(.number)) matched", color: t.infoInk)
            }
            .padding(18)
        }
    }

    // MARK: - Recent runs

    private var recentRuns: some View {
        CairnCard {
            VStack(spacing: 0) {
                ForEach(Array(runs.prefix(4).enumerated()), id: \.element.id) { idx, run in
                    RunRow(run: run, onOpen: { onOpenRun(run) })
                    if idx < min(3, runs.count - 1) {
                        RowDivider()
                    }
                }
                Button(action: onSeeAllRuns) {
                    HStack(spacing: 6) {
                        Text("See all runs")
                            .font(.system(size: 13))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(t.textMuted)
                    .background(
                        Rectangle()
                            .fill(t.divider)
                            .frame(height: 0.5),
                        alignment: .top
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Journal tail

    /// Monospace tail of recent journal events. All rows live inside
    /// one horizontal `ScrollView` so scrolling right reveals the tail
    /// of every row simultaneously — "cand=12 elapsed=37.58s" lines up
    /// column-wise with every other event's right edge, which makes
    /// it easy to eyeball what changed between runs.
    ///
    /// The collapsed view caps at `collapsedJournalTailLimit` rows;
    /// tapping "Show more" grows to the full buffered tail so the
    /// user can audit further back without leaving Status.
    private var journalTailCard: some View {
        // Routine-sync filter: drop no-op `sync` rows when the chip is
        // ON. Filtered first, then capped to `collapsedJournalTailLimit`
        // so the count badge ("Show N more") accounts for the visible
        // post-filter set, not the raw buffer.
        let filtered = hideRoutineSyncs
            ? journalTail.filter { !$0.isRoutineSync }
            : journalTail
        let hiddenCount = journalTail.count - filtered.count
        let visible = journalExpanded
            ? filtered
            : Array(filtered.prefix(Self.collapsedJournalTailLimit))
        // Prebuilt runId set so the row's tappability check is O(1)
        // — avoids a linear scan per row when the runs list is long.
        let runIds = Set(runs.map(\.id))
        return CairnCard {
            VStack(alignment: .leading, spacing: 10) {
                journalFilterChip
                if filtered.isEmpty {
                    Text(journalEmptyMessage(hidden: hiddenCount))
                        .font(.system(size: 12))
                        .foregroundStyle(t.textMuted)
                        .padding(.vertical, 6)
                } else {
                    // Single 2D ScrollView so rows shift together on
                    // both axes — column alignment stays correct when
                    // panning horizontally to read tail content, and
                    // vertical scroll inside the card keeps Status
                    // from bloating when the user expands hundreds of
                    // history rows. LazyVStack defers row construction
                    // so 500-entry buffers don't allocate eagerly.
                    // Fixed maxHeight only when expanded; collapsed
                    // (8 rows) sizes naturally so a quiet Status
                    // doesn't show a stub-height scrollbox.
                    ScrollView([.horizontal, .vertical], showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(visible) { entry in
                                JournalTailRow(
                                    entry: entry,
                                    eventInk: eventColor(entry.event),
                                    isTappable: runIds.contains(entry.runId),
                                    onTap: { onJournalRowTap(entry.runId) }
                                )
                            }
                        }
                        .padding(.trailing, 4)   // breathing room on the right edge
                    }
                    .frame(maxHeight: journalExpanded ? Self.expandedJournalCardMaxHeight : .infinity)
                    .scrollBounceBehavior(.basedOnSize)

                    if filtered.count > Self.collapsedJournalTailLimit {
                        Button {
                            withAnimation(reduceMotion ? .none : .snappy(duration: 0.16)) {
                                journalExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: journalExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(journalExpanded
                                     ? "Show fewer"
                                     : "Show \(filtered.count - Self.collapsedJournalTailLimit) more")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(t.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                        }
                        .buttonStyle(.plain)
                    }

                    if hideRoutineSyncs && hiddenCount > 0 {
                        Text("\(hiddenCount) routine sync\(hiddenCount == 1 ? "" : "s") hidden")
                            .font(.system(size: 11))
                            .foregroundStyle(t.textHint)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    /// Tap-to-toggle filter chip pinned above the journal rows. Uses
    /// the existing `Chip` view for visual consistency with the
    /// status header. Animates on toggle so the row list reflows with
    /// the rest of the banner-area motion.
    private var journalFilterChip: some View {
        Button {
            withAnimation(reduceMotion ? .none : .snappy(duration: 0.16)) {
                hideRoutineSyncs.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: hideRoutineSyncs
                                  ? "line.3.horizontal.decrease.circle.fill"
                                  : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 11, weight: .semibold))
                Text(hideRoutineSyncs ? "Hiding routine syncs" : "Showing all events")
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(hideRoutineSyncs ? t.infoInk : t.textBody)
            .background(hideRoutineSyncs ? t.infoSoft : t.surfaceAlt)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hideRoutineSyncs
            ? "Routine no-op syncs hidden. Tap to show."
            : "All events shown. Tap to hide routine no-op syncs.")
    }

    /// Empty-state copy for the journal card. Distinguishes "no
    /// events at all" from "everything got filtered out" so a user
    /// who's confused why the card is empty has a path forward.
    private func journalEmptyMessage(hidden: Int) -> String {
        if journalTail.isEmpty {
            return "No events yet. Events appear here after the first sync."
        }
        if hidden > 0 {
            return "All \(hidden) recent event\(hidden == 1 ? "" : "s") \(hidden == 1 ? "is" : "are") routine syncs. Tap the chip to show them."
        }
        return "No events to show."
    }

    /// How many journal rows show in the collapsed state. Everything
    /// beyond this hides behind the "Show more" toggle.
    private static let collapsedJournalTailLimit: Int = 8

    /// Cap for the expanded journal card's vertical extent. Beyond
    /// this, content scrolls within the card rather than pushing the
    /// rest of Status down. ≈12 rows visible at the current row
    /// height — roughly a screen-page of activity at a glance.
    private static let expandedJournalCardMaxHeight: CGFloat = 360

    /// Mapping pinned to the event-name strings `JournalTailEntry.from`
    /// actually emits. The previous version checked stale names
    /// (`safety.ok`, `tag.create`, `delete.batch`, `abort`) that the
    /// post-Wave-2 pipeline never writes — so every row rendered in
    /// the default `textBody` color regardless of severity.
    private func eventColor(_ ev: String) -> Color {
        switch ev {
        case "trash.ok", "run.complete", "restore.ok":
            return t.verifiedInk
        case "trash.fail", "restore.fail":
            return t.dangerInk
        case "run.abort":
            return t.dangerInk
        case "pending.hold":
            return t.pendingInk
        case "tag.apply", "restore.start", "run.start", "plan.trash", "exclude.add":
            return t.infoInk
        case "sync":
            return t.textBody
        default:
            return t.textBody
        }
    }
}

// MARK: - Journal tail row

/// One row inside the journal-tail card. Plain single-line layout;
/// horizontal scrolling happens at the *card* level (all rows shift
/// together) so column positions stay aligned. Fixed-width time and
/// event columns keep messages flush-left across rows.
private struct JournalTailRow: View {
    let entry: CairnFixtures.JournalTailEntry
    let eventInk: Color
    let isTappable: Bool
    let onTap: () -> Void

    @Environment(\.cairnTokens) private var t

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                // Leading status glyph — at-a-glance signal that
                // doesn't require parsing event-name strings. Tinted
                // to match `eventInk` so red/green/yellow/blue
                // semantics carry through whether the user reads the
                // glyph or the event word.
                Image(systemName: entry.glyph)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(eventInk)
                    .frame(width: 14, alignment: .center)
                // Time is fixed-width so rows scan cleanly by time
                // across the tail. The new compact format
                // (`HH:mm` today, `MMM d HH:mm` past) is
                // ~80pt — half the previous column's width.
                Text(entry.time)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(t.textHint)
                    .frame(width: 80, alignment: .leading)
                // Event hugs its content (no fixed column) — a short
                // name like "sync" sits right next to its message
                // rather than drifting out to the width of the longest
                // possible event. Ragged message-start columns read a
                // bit busier, but the cost of fixed-width dead space
                // was worse.
                Text(entry.event)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(eventInk)
                    .fixedSize()
                Text(entry.message)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(t.textMuted)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 12)
                // RunId suffix sits at the far right so users can
                // correlate events to a run at a glance. Hint-tone
                // monospace, fixed width to keep alignment with
                // adjacent rows even when they share a runId.
                if !entry.runIdSuffix.isEmpty {
                    Text(entry.runIdSuffix)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(t.textHint)
                        .frame(width: 64, alignment: .trailing)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Disabling the row both for hit-testing and for the wrapping
        // button so untappable rows match the previous render exactly.
        .allowsHitTesting(isTappable)
    }
}

// MARK: - Sub-views

/// Shared palette for small tinted pills / progress bars. Internal so
/// `ProgressBar` (reused by `InitialScanScreen`) can reference it across
/// files in this module without duplicating the enum.
enum ChipTone {
    case verified, danger, pending, info, neutral
}

private struct Chip: View {
    let label: String
    let tone: ChipTone

    @Environment(\.cairnTokens) private var t

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(inkColor)
        .background(softColor)
        .clipShape(Capsule())
    }

    private var softColor: Color {
        switch tone {
        case .verified: t.verifiedSoft
        case .danger:   t.dangerSoft
        case .pending:  t.pendingSoft
        case .info:     t.infoSoft
        case .neutral:  t.surfaceAlt
        }
    }
    private var inkColor: Color {
        switch tone {
        case .verified: t.verifiedInk
        case .danger:   t.dangerInk
        case .pending:  t.pendingInk
        case .info:     t.infoInk
        case .neutral:  t.textBody
        }
    }
    private var dotColor: Color { inkColor.opacity(0.85) }
}

/// 4pt capsule progress bar. Widened access so `InitialScanScreen`
/// can reuse the exact same visual — keeping progress styling consistent
/// across every surface that shows one.
struct ProgressBar: View {
    let fraction: Double
    let tone: ChipTone

    @Environment(\.cairnTokens) private var t

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(t.divider).frame(height: 4)
                Capsule().fill(fillColor).frame(width: geo.size.width * fraction, height: 4)
            }
        }
        .frame(height: 4)
    }

    private var fillColor: Color {
        switch tone {
        case .pending: t.pending
        case .danger:  t.danger
        case .verified: t.verified
        case .info:    t.info
        case .neutral: t.textMuted
        }
    }
}

private struct RunRow: View {
    let run: CairnFixtures.RunFixture
    let onOpen: () -> Void

    @Environment(\.cairnTokens) private var t

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(iconBg)
                        .frame(width: 30, height: 30)
                    Image(systemName: iconName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(iconInk)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(verb)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(t.text)
                        if run.restored > 0 {
                            Chip(label: "\(run.restored) restored", tone: .neutral)
                        }
                    }
                    HStack(spacing: 4) {
                        Text(CairnTimeHelpers.relativeTime(run.startedAt, now: Date()))
                            .font(.system(size: 11.5))
                            .foregroundStyle(t.textHint)
                        Text("·")
                            .font(.system(size: 11.5))
                            .foregroundStyle(t.textHint)
                        Text(String(run.id.suffix(8)))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(t.textHint)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(t.textHint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var verb: String {
        if run.status == .aborted { return "Aborted" }
        if run.dryRun { return "Dry-run" }
        if run.trashed == 0 { return "No changes" }
        return "\(run.trashed) trashed"
    }

    private var iconName: String {
        if run.status == .aborted { return "exclamationmark.triangle.fill" }
        if run.dryRun { return "eye" }
        return "trash"
    }

    private var iconBg: Color {
        if run.status == .aborted { return t.dangerSoft }
        if run.dryRun { return t.pendingSoft }
        return t.verifiedSoft
    }

    private var iconInk: Color {
        if run.status == .aborted { return t.dangerInk }
        if run.dryRun { return t.pendingInk }
        return t.verifiedInk
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Status — steady (medium library)") {
    StatusScreen()
        .cairnTheme()
}

#Preview("Status — threshold tripped") {
    StatusScreen(appState: .thresholdTripped)
        .cairnTheme()
}

#Preview("Status — server down") {
    StatusScreen(degraded: .serverDown)
        .cairnTheme()
}

#Preview("Status — first-run dry-run nudge") {
    StatusScreen(appState: .dryRun, library: CairnFixtures.small)
        .cairnTheme()
}

#Preview("Status — dark") {
    StatusScreen()
        .cairnTheme()
        .preferredColorScheme(.dark)
}
#endif
