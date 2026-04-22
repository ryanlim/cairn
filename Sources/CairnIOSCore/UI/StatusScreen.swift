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
    public let onStartSync: () -> Void
    public let onOpenRun: (CairnFixtures.RunFixture) -> Void
    public let onSeeAllRuns: () -> Void

    @Environment(\.cairnTokens) private var t

    public init(
        appState: AppState = .steady,
        degraded: Degraded = .none,
        library: CairnFixtures.LibrarySize = CairnFixtures.medium,
        runs: [CairnFixtures.RunFixture] = CairnFixtures.runs,
        journalTail: [CairnFixtures.JournalTailEntry] = CairnFixtures.journalTail,
        serverHost: String = "immich.home.arpa",
        maxDeletePercent: Double = 1.0,
        onStartSync: @escaping () -> Void = {},
        onOpenRun: @escaping (CairnFixtures.RunFixture) -> Void = { _ in },
        onSeeAllRuns: @escaping () -> Void = {}
    ) {
        self.appState = appState
        self.degraded = degraded
        self.library = library
        self.runs = runs
        self.journalTail = journalTail
        self.serverHost = serverHost
        self.maxDeletePercent = maxDeletePercent
        self.onStartSync = onStartSync
        self.onOpenRun = onOpenRun
        self.onSeeAllRuns = onSeeAllRuns
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

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                wordmarkHeader
                degradedBanner
                stateBanner
                syncCard
                KeylineSection("Library")
                libraryStats
                KeylineSection("Recent runs")
                recentRuns
                KeylineSection("Latest journal")
                journalTailCard
                Spacer(minLength: 24)
            }
        }
        .background(t.bg)
    }

    // MARK: - Header

    private var wordmarkHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 10) {
                    CairnMark(size: 28, crowned: true)
                    Text("cairn")
                        .font(.system(size: 28, weight: .semibold))
                        .tracking(-0.6)
                        .foregroundStyle(t.text)
                }
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
        case .authStale:
            Callout(.pending, icon: "key") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API key rejected").fontWeight(.semibold)
                    Text("Server returned 401. Your key may have been revoked or expired. Paste a new one in Settings.")
                        .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        case .photosLimited:
            Callout(.pending, icon: "photo.on.rectangle.angled") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Photos access is Limited").fontWeight(.semibold)
                    Text("cairn can only see the assets you picked. With Limited access it will flag everything outside as “missing” and suggest deleting them — dangerous. Grant Full access to continue.")
                        .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        case .tinyLibrary:
            Callout(.pending, icon: "info.circle") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Library is small").fontWeight(.semibold)
                    Text("Your iPhone has a small set of assets. cairn works best with 200+ so signals are reliable. You can still sync, but treat the first run carefully.")
                        .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
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
        case .dryRun:
            Callout(.info, icon: "info.circle") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("First sync is a dry-run").fontWeight(.semibold)
                    Text("We'll show exactly what would be trashed. Nothing gets touched on your server until you confirm.")
                        .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        case .steady:
            EmptyView()
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
                        (Text("would move to ") + Text("Immich trash").foregroundStyle(t.text) + Text(" on next run"))
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

                ProgressBar(
                    fraction: min(1.0, pct / max(0.001, maxDeletePercent)),
                    tone: withinBudget ? .pending : .danger
                )

                Button(action: { if !syncBlocked { onStartSync() } }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 14, weight: .semibold))
                        Text(syncCtaLabel)
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(syncBlocked ? t.textMuted : t.primaryInk)
                    .background(syncBlocked ? t.surfaceAlt : t.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(syncBlocked)
                .opacity(syncBlocked ? 0.85 : 1)
            }
            .padding(18)
        }
        .padding(.bottom, 14)
    }

    private var syncCtaLabel: String {
        if syncBlocked { return "Can’t sync — see banner" }
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

    private var journalTailCard: some View {
        CairnCard {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(journalTail) { entry in
                    HStack(spacing: 8) {
                        Text(entry.time)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(t.textHint)
                            .frame(width: 78, alignment: .leading)
                        Text(entry.event)
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(eventColor(entry.event))
                            .frame(width: 90, alignment: .leading)
                        Text(entry.message)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(t.textMuted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

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

// MARK: - Sub-views

private enum ChipTone {
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

private struct ProgressBar: View {
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
