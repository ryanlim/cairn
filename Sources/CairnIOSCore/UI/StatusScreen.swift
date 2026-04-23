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
    /// Wave 4: total count of candidates awaiting the user's call (held +
    /// unconfirmed). When > 0 the screen surfaces a compact pending-review
    /// card directly below the sync card.
    public let pendingReviewCount: Int
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
    /// True while `actions.requestSync` is mid-flight. Drives spinner +
    /// disabled state on the CTA so taps don't feel dead.
    public let isSyncing: Bool
    /// Optional hashing progress, surfaced in the CTA label when the
    /// full-enumeration path is running ("Hashing 1,245 / 4,218").
    public let syncProgress: (hashed: Int, total: Int)?
    public let onStartSync: () -> Void
    public let onCancelSync: () -> Void
    public let onOpenRun: (CairnFixtures.RunFixture) -> Void
    public let onSeeAllRuns: () -> Void
    public let onOpenPendingReview: () -> Void

    @Environment(\.cairnTokens) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var journalExpanded: Bool = false
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
    @AppStorage("cairn.status.dismissedDeferredAtCount")
    private var dismissedDeferredAtCount: Int = -1

    public init(
        appState: AppState = .steady,
        degraded: Degraded = .none,
        library: CairnFixtures.LibrarySize = CairnFixtures.medium,
        runs: [CairnFixtures.RunFixture] = CairnFixtures.runs,
        journalTail: [CairnFixtures.JournalTailEntry] = CairnFixtures.journalTail,
        serverHost: String = "immich.home.arpa",
        maxDeletePercent: Double = 1.0,
        pendingReviewCount: Int = 0,
        deletionBacklog: Int = 0,
        backlogAlertThreshold: Int = 25,
        syncToast: CairnAppModel.SyncToast? = nil,
        initialScanPending: Bool = false,
        isSyncing: Bool = false,
        syncProgress: (hashed: Int, total: Int)? = nil,
        onStartSync: @escaping () -> Void = {},
        onCancelSync: @escaping () -> Void = {},
        onOpenRun: @escaping (CairnFixtures.RunFixture) -> Void = { _ in },
        onSeeAllRuns: @escaping () -> Void = {},
        onOpenPendingReview: @escaping () -> Void = {},
        onResumeInitialScan: @escaping () -> Void = {},
        deferredQueue: CairnAppModel.DeferredQueueSummary = .empty,
        onForceDrainDeferred: @escaping () -> Void = {}
    ) {
        self.appState = appState
        self.degraded = degraded
        self.library = library
        self.runs = runs
        self.journalTail = journalTail
        self.serverHost = serverHost
        self.maxDeletePercent = maxDeletePercent
        self.pendingReviewCount = pendingReviewCount
        self.deletionBacklog = deletionBacklog
        self.backlogAlertThreshold = backlogAlertThreshold
        self.syncToast = syncToast
        self.initialScanPending = initialScanPending
        self.isSyncing = isSyncing
        self.syncProgress = syncProgress
        self.onStartSync = onStartSync
        self.onCancelSync = onCancelSync
        self.onOpenRun = onOpenRun
        self.onSeeAllRuns = onSeeAllRuns
        self.onOpenPendingReview = onOpenPendingReview
        self.onResumeInitialScan = onResumeInitialScan
        self.deferredQueue = deferredQueue
        self.onForceDrainDeferred = onForceDrainDeferred
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
            deferredQueue.count > 0 && !initialScanPending && dismissedDeferredAtCount != deferredQueue.count,
        ]
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                wordmarkHeader
                degradedBanner
                stateBanner
                initialScanPendingBanner
                backlogAlertBanner
                syncToastBanner
                deferredQueueBanner
                syncCard
                pendingReviewCard
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

    // MARK: - Pending review card

    @ViewBuilder
    private var pendingReviewCard: some View {
        if pendingReviewCount > 0 {
            // Wrapped in a Button so we pick up `CairnPressStyle`'s
            // scale + dim on press. Previous `.onTapGesture` rendered
            // no feedback, which made the card feel like decoration
            // rather than a tappable row.
            Button(action: onOpenPendingReview) {
                CairnCard {
                    HStack(alignment: .center, spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(t.pendingSoft)
                                .frame(width: 44, height: 44)
                            Image(systemName: "tray.and.arrow.down")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(t.pendingInk)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pending review")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(t.text)
                            (Text("\(pendingReviewCount) \(pendingReviewCount == 1 ? "item needs" : "items need") your review before ") + .cairnWord + Text(" moves them to Immich's Trash."))
                                .font(.system(size: 12))
                                .foregroundStyle(t.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(t.textHint)
                    }
                }
            }
            .buttonStyle(CairnPressStyle())
            .padding(.top, 12)
        }
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
    private var degradedBanner: some View {
        switch degraded {
        case .none: EmptyView()
        case .serverDown:
            Callout(.danger, icon: "server.rack") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Immich server unreachable").fontWeight(.semibold)
                    (Text("Tried ") + Text(serverHost).font(.system(size: 12, design: .monospaced)) + Text(" three times over 2m. Check VPN or server health before syncing."))
                        .opacity(0.88).fixedSize(horizontal: false, vertical: true)
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
        }
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
    /// the initial scan to completion, the deferred queue (whatever's
    /// left) becomes a valid call-to-action.
    @ViewBuilder
    private var deferredQueueBanner: some View {
        if deferredQueue.count > 0
            && !initialScanPending
            && dismissedDeferredAtCount != deferredQueue.count {
            Callout(.info, icon: "tray.and.arrow.down") {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(deferredQueue.count) \(deferredQueue.count == 1 ? "asset" : "assets") queued for background hashing")
                            .fontWeight(.semibold)
                        Group {
                            if deferredQueue.totalKnownBytes > 0 {
                                Text("\(formatDeferredBytes(deferredQueue.totalKnownBytes)) of iCloud downloads. Waiting for a charging + Wi-Fi slot, or tap Hash now.")
                            } else {
                                Text("Waiting for a background slot (charging + Wi-Fi), or tap Hash now.")
                            }
                        }
                        .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Button(action: onForceDrainDeferred) {
                        Text("Hash now")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(t.primaryInk)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(t.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(CairnPressStyle())
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            .cairnSwipeToDismiss {
                dismissedDeferredAtCount = deferredQueue.count
            }
            .transition(bannerTransition)
        }
    }

    /// Body text for the `upToDate` toast. When `indexed == total`
    /// there's no "rest to catch up" — drop that clause so the line
    /// doesn't imply missing work. When some assets are still
    /// deferred (indexed < total), keep the catch-up caveat so the
    /// user isn't surprised by the queue sitting in Settings.
    private func upToDateSubline(indexed: Int, total: Int) -> Text {
        let count = Text("\(indexed) of \(total)").bold()
        if indexed >= total {
            // Everything hashed. No caveat needed.
            return Text("Nothing new to trash. ") + count + Text(" assets indexed.")
        } else {
            return Text("Nothing new to trash. ") + count
                + Text(" assets indexed — the rest will catch up in the background.")
        }
    }

    private func formatDeferredBytes(_ bytes: Int64) -> String {
        CairnTimeHelpers.formatBytes(bytes)
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

    private var syncCard: some View {
        CairnCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PENDING CANDIDATES")
                            .font(.system(size: 11, weight: .semibold)).tracking(0.9)
                            .foregroundStyle(t.textMuted)
                        Text("\(library.candidates)")
                            .font(.system(size: 52, weight: .semibold).monospacedDigit())
                            .tracking(-2.0)
                            .foregroundStyle(t.pendingInk)
                            .lineLimit(1)
                        (Text("would move to ") + Text("Immich's Trash").foregroundStyle(t.text) + Text(" on next run"))
                            .font(.system(size: 13))
                            .foregroundStyle(t.textMuted)
                            .padding(.top, 2)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Chip(label: String(format: "%.2f%% of matched", pct),
                             tone: withinBudget ? .verified : .pending)
                        Text(String(format: "cap %.1f%%", maxDeletePercent))
                            .font(.system(size: 11))
                            .foregroundStyle(t.textMuted)
                    }
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
                } else {
                    ProgressBar(
                        fraction: min(1.0, pct / max(0.001, maxDeletePercent)),
                        tone: withinBudget ? .pending : .danger
                    )
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
                }
            }
            .padding(18)
        }
        .padding(.bottom, 14)
    }

    private var syncCtaLabel: String {
        if syncBlocked { return "Can’t sync — see banner" }
        if isSyncing {
            if let progress = syncProgress, progress.total > 0 {
                return "Hashing \(progress.hashed.formatted(.number)) / \(progress.total.formatted(.number))"
            }
            return "Syncing…"
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
        let visible = journalExpanded
            ? journalTail
            : Array(journalTail.prefix(Self.collapsedJournalTailLimit))
        return CairnCard {
            VStack(alignment: .leading, spacing: 10) {
                if journalTail.isEmpty {
                    Text("No events yet. Events appear here after the first sync.")
                        .font(.system(size: 12))
                        .foregroundStyle(t.textMuted)
                        .padding(.vertical, 6)
                } else {
                    // Single outer ScrollView: every row shifts
                    // together when the user swipes horizontally.
                    // `.scrollBounceBehavior(.basedOnSize)` suppresses
                    // the bounce when content already fits.
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(visible) { entry in
                                JournalTailRow(entry: entry, eventInk: eventColor(entry.event))
                            }
                        }
                        .padding(.trailing, 4)   // breathing room on the right edge
                    }
                    .scrollBounceBehavior(.basedOnSize)

                    if journalTail.count > Self.collapsedJournalTailLimit {
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
                                     : "Show \(journalTail.count - Self.collapsedJournalTailLimit) more")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(t.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    /// How many journal rows show in the collapsed state. Everything
    /// beyond this hides behind the "Show more" toggle.
    private static let collapsedJournalTailLimit: Int = 8

    private func eventColor(_ ev: String) -> Color {
        switch ev {
        case "safety.ok":     return t.verifiedInk
        case "tag.create", "tag.attach", "reconcile": return t.infoInk
        case "delete.batch":  return t.pendingInk
        case "abort":         return t.dangerInk
        default:              return t.textBody
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

    @Environment(\.cairnTokens) private var t

    var body: some View {
        HStack(spacing: 8) {
            // Time is the only column with a fixed width — so rows
            // scan cleanly by time across the tail. The date-prefixed
            // format ("Apr 22 · 17:57:19.325") needs more room than
            // the time-only version the column was originally sized
            // for.
            Text(entry.time)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(t.textHint)
                .frame(width: 160, alignment: .leading)
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
        }
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
