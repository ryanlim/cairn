import SwiftUI

/// The review-and-sync modal — the safety-critical core flow. Mirrors
/// `screens/dryrun.jsx`. Multi-stage:
///
///   review → confirming → running → done
///
/// `review` is where the user sees the candidate grid, the safety-checks
/// list, and decides. `confirming` is the rust-banner second-confirm
/// (live mode only). `running` shows progress. `done` is the receipt.
///
/// In tripped mode (over the percent + floor cap), the layout is the same
/// but the CTA changes to "Proceed anyway" + a quieter "Raise threshold
/// to N% and retry" affordance — the design wants users to *see* the
/// candidates before deciding, not be hidden behind a separate screen.
///
/// Microcopy is verbatim from the prototype. See HANDOFF.md "Keep these
/// copies verbatim" — don't paraphrase.
public struct DryRunSheet: View {

    public enum Phase: Sendable, Equatable {
        case review, confirming, running, done
    }

    public let candidates: [CairnFixtures.CandidateFixture]
    public let library: CairnFixtures.LibrarySize
    public let maxDeletePercent: Double
    public let minDeleteFloor: Int
    public let dryRunByDefault: Bool
    public let forceTripped: Bool
    public let onClose: () -> Void
    public let onConfirm: () -> Void

    @State private var phase: Phase = .review
    @State private var sort: Sort = .recent

    @Environment(\.cairnTokens) private var t

    public init(
        candidates: [CairnFixtures.CandidateFixture] = CairnFixtures.candidates,
        library: CairnFixtures.LibrarySize = CairnFixtures.medium,
        maxDeletePercent: Double = 1.0,
        minDeleteFloor: Int = 5,
        dryRunByDefault: Bool = false,
        forceTripped: Bool = false,
        onClose: @escaping () -> Void = {},
        onConfirm: @escaping () -> Void = {}
    ) {
        self.candidates = candidates
        self.library = library
        self.maxDeletePercent = maxDeletePercent
        self.minDeleteFloor = minDeleteFloor
        self.dryRunByDefault = dryRunByDefault
        self.forceTripped = forceTripped
        self.onClose = onClose
        self.onConfirm = onConfirm
    }

    public enum Sort: Sendable { case recent, type }

    private var pct: Double {
        guard library.matched > 0 else { return 0 }
        return Double(candidates.count) / Double(library.matched) * 100
    }
    private var overPct: Bool { pct > maxDeletePercent }
    private var overFloor: Bool { candidates.count > minDeleteFloor }
    private var tripped: Bool { forceTripped || (overPct && overFloor) }

    private var totalBytes: Int { candidates.reduce(0) { $0 + $1.bytes } }
    private var livePairs: Int { candidates.filter { $0.kind == .livePair }.count }
    private var videoCount: Int { candidates.filter { $0.kind == .video }.count }

    private var sorted: [CairnFixtures.CandidateFixture] {
        switch sort {
        case .recent: return candidates
        case .type:
            return candidates.sorted { a, b in
                rank(a.kind) != rank(b.kind) ? rank(a.kind) < rank(b.kind) : a.name < b.name
            }
        }
    }

    private func rank(_ k: CairnFixtures.CandidateFixture.Kind) -> Int {
        switch k {
        case .video: 0
        case .livePair: 1
        case .photo: 2
        }
    }

    public var body: some View {
        ZStack {
            t.text.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                sheet
            }
        }
    }

    @ViewBuilder
    private var sheet: some View {
        switch phase {
        case .review, .confirming:
            reviewSheet
        case .running, .done:
            terminalSheet
        }
    }

    // MARK: - Review

    private var reviewSheet: some View {
        VStack(spacing: 0) {
            grip
            header
            if tripped { trippedBanner }
            summaryStrip
            sortStrip
            candidateGrid
            safetyChecks
            actionsBar
        }
        .background(t.surface)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 0)
    }

    private var grip: some View {
        Capsule().fill(t.divider).frame(width: 40, height: 5).padding(.top, 8).padding(.bottom, 4)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ModeChip(dryRun: dryRunByDefault, tripped: tripped)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(t.textMuted)
                }
                .buttonStyle(.plain)
            }
            Text(headerTitle)
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.45)
                .foregroundStyle(t.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(headerSubtitle)
                .font(.system(size: 13))
                .foregroundStyle(t.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    private var headerTitle: String {
        if tripped { return "\(candidates.count) candidates is above your cap" }
        if dryRunByDefault { return "\(candidates.count) would move to trash" }
        return "Trash \(candidates.count) on Immich?"
    }

    private var headerSubtitle: String {
        if tripped { return "Nothing was touched. Review the photos before deciding." }
        if dryRunByDefault {
            return "\(CairnTimeHelpers.formatBytes(totalBytes)) · preview only, nothing will be touched on your server"
        }
        return "\(CairnTimeHelpers.formatBytes(totalBytes)) · stays in Immich trash for 30 days"
    }

    private var trippedBanner: some View {
        Callout(.danger, icon: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%.2f%% of matched would be trashed", pct))
                    .fontWeight(.semibold)
                (Text("Your cap is ") + Text(String(format: "%.1f%%", maxDeletePercent)).bold()
                    + Text(" (and ") + Text("\(minDeleteFloor)+").bold() + Text(" assets). ")
                    + Text("Look through the grid — does it match what you deleted on your phone?"))
                    .opacity(0.9).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var summaryStrip: some View {
        CairnCard {
            HStack(spacing: 12) {
                MiniStat(label: tripped ? "Over cap" : "Of matched",
                         value: String(format: "%.2f%%", pct),
                         sub: String(format: "cap %.1f%%", maxDeletePercent),
                         tone: tripped ? .danger : .neutral)
                Rectangle().fill(t.divider).frame(width: 0.5)
                MiniStat(label: "Live pairs", value: "\(livePairs)", sub: "still + motion")
                Rectangle().fill(t.divider).frame(width: 0.5)
                MiniStat(label: "Videos", value: "\(videoCount)")
                Rectangle().fill(t.divider).frame(width: 0.5)
                let bytesParts = CairnTimeHelpers.formatBytes(totalBytes).split(separator: " ")
                MiniStat(label: "Freed",
                         value: String(bytesParts.first ?? "0"),
                         sub: bytesParts.count > 1 ? String(bytesParts[1]) : nil)
            }
            .padding(12)
        }
        .padding(.bottom, 12)
    }

    private var sortStrip: some View {
        HStack {
            Text("\(candidates.count) PHOTOS · TAP TO ZOOM")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(t.textHint)
            Spacer()
            HStack(spacing: 2) {
                SegBtn(label: "Recent", active: sort == .recent) { sort = .recent }
                SegBtn(label: "By type", active: sort == .type) { sort = .type }
            }
            .padding(2)
            .background(t.bg)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var candidateGrid: some View {
        ScrollView {
            CairnCard {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 6)], spacing: 6) {
                    ForEach(sorted) { c in
                        VStack(spacing: 4) {
                            MockAssetThumb(filename: c.name, size: 76, isLivePair: c.isLivePair)
                            Text(c.name.replacingOccurrences(of: ".HEIC", with: "").replacingOccurrences(of: ".MP4", with: ""))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(t.textMuted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(10)
            }
            .padding(.bottom, 12)
        }
        .frame(maxHeight: 260)
    }

    private var safetyChecks: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SAFETY CHECKS")
                .font(.system(size: 11, weight: .semibold)).tracking(0.9)
                .foregroundStyle(t.textHint)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            CairnCard {
                VStack(spacing: 0) {
                    CheckRow(label: String(format: "Under %.1f%% cap", maxDeletePercent), pass: !overPct)
                    RowDivider()
                    CheckRow(label: "Over \(minDeleteFloor)-asset floor", pass: overFloor)
                    RowDivider()
                    CheckRow(label: "Server returned > 0 assets", pass: true)
                    RowDivider()
                    CheckRow(label: "Photos access is Full", pass: true)
                    RowDivider()
                    CheckRow(label: "Purview set populated", pass: true)
                }
            }
            .padding(.bottom, 16)
        }
    }

    private var actionsBar: some View {
        VStack(spacing: 10) {
            switch phase {
            case .review:
                if tripped { trippedActions } else { normalActions }
            case .confirming:
                confirmingActions
            case .running, .done:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .background(
            t.surface.overlay(
                Rectangle().fill(t.divider).frame(height: 0.5),
                alignment: .top
            )
        )
    }

    private var normalActions: some View {
        HStack(spacing: 10) {
            ActionButton(label: "Not now", role: .secondary, action: onClose)
                .frame(maxWidth: .infinity)
            if dryRunByDefault {
                ActionButton(label: "Log dry-run", icon: "eye", role: .primary) {
                    runIt()
                }
                .frame(maxWidth: .infinity)
                .frame(maxWidth: .infinity)
            } else {
                ActionButton(label: "Move \(candidates.count) to trash", icon: "trash", role: .danger) {
                    phase = .confirming
                }
                .frame(maxWidth: .infinity)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var trippedActions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ActionButton(label: "Cancel", role: .secondary, action: onClose)
                    .frame(maxWidth: .infinity)
                ActionButton(label: "Proceed anyway", icon: "exclamationmark.triangle", role: .primary) {
                    phase = .confirming
                }
                .frame(maxWidth: .infinity)
                .frame(maxWidth: .infinity)
            }
            ActionButton(label: "Raise threshold to \(Int(ceil(pct * 1.2)))% and retry", role: .quiet) {}
        }
    }

    private var confirmingActions: some View {
        VStack(spacing: 12) {
            Callout(.danger, icon: "exclamationmark.triangle") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Confirm once more").fontWeight(.semibold)
                    (Text("cairn will tag ") + Text("cairn/v1/run/…").font(.system(size: 11.5, design: .monospaced))
                        + Text(" then move \(candidates.count) asset\(candidates.count == 1 ? "" : "s") to Immich trash."))
                        .opacity(0.9).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                ActionButton(label: "Back", role: .secondary) { phase = .review }
                    .frame(maxWidth: .infinity)
                ActionButton(label: "Yes, trash \(candidates.count)", role: .danger) {
                    runIt()
                }
                .frame(maxWidth: .infinity)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Terminal phases

    private var terminalSheet: some View {
        VStack(spacing: 0) {
            grip
            VStack(spacing: 14) {
                if phase == .running {
                    runningContent
                } else {
                    doneContent
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 30)
            .padding(.bottom, 24)
        }
        .background(t.surface)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var runningContent: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(t.surfaceAlt).frame(width: 48, height: 48)
                ProgressView().tint(t.textBody)
            }
            Text(dryRunByDefault ? "Recording preview" : "Tagging and trashing")
                .font(.system(size: 20, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(t.text)
            Text(dryRunByDefault
                 ? "Nothing touched · \(candidates.count) assets noted"
                 : "Writing breadcrumb · \(candidates.count) assets")
                .font(.system(size: 13))
                .foregroundStyle(t.textMuted)
        }
    }

    private var doneContent: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(dryRunByDefault ? t.infoSoft : t.verifiedSoft)
                    .frame(width: 48, height: 48)
                Image(systemName: dryRunByDefault ? "eye" : "checkmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(dryRunByDefault ? t.infoInk : t.verifiedInk)
            }
            Text(dryRunByDefault ? "\(candidates.count) preview logged" : "\(candidates.count) moved to trash")
                .font(.system(size: 20, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(t.text)
            (dryRunByDefault
                ? Text("Nothing touched on server. Turn off ") + Text("Dry-run by default").foregroundStyle(t.text) + Text(" in Settings to actually trash.")
                : Text("Tagged ") + Text("cairn/v1/run/…").font(.system(size: 11.5, design: .monospaced)) + Text(". Recoverable in Immich trash for 30 days."))
                .font(.system(size: 13))
                .foregroundStyle(t.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            ActionButton(label: "Back to status", role: .primary) {
                onConfirm()
                onClose()
            }
            .padding(.top, 8)
        }
    }

    private func runIt() {
        phase = .running
        // Simulated work for the preview animation; real implementation calls
        // through the orchestrator and transitions on completion.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            phase = .done
        }
    }
}

// MARK: - Sub-views

private struct ModeChip: View {
    let dryRun: Bool
    let tripped: Bool

    @Environment(\.cairnTokens) private var t

    var body: some View {
        let (label, soft, ink): (String, Color, Color) = {
            if tripped { return ("Tripped · review needed", t.dangerSoft, t.dangerInk) }
            if dryRun { return ("Dry-run mode", t.infoSoft, t.infoInk) }
            return ("Live · will trash", t.dangerSoft.mix(with: t.danger, amount: 0.30), t.dangerInk)
        }()
        return Text(label.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.9)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(ink)
            .background(soft)
            .clipShape(Capsule())
    }
}

private struct MiniStat: View {
    let label: String
    let value: String
    var sub: String? = nil
    var tone: Tone = .neutral

    enum Tone { case neutral, danger }

    @Environment(\.cairnTokens) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(t.textHint)
            Text(value)
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                .foregroundStyle(tone == .danger ? t.dangerInk : t.text)
            if let sub {
                Text(sub)
                    .font(.system(size: 11))
                    .foregroundStyle(t.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SegBtn: View {
    let label: String
    let active: Bool
    let action: () -> Void

    @Environment(\.cairnTokens) private var t

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(active ? t.text : t.textMuted)
                .background(active ? t.surface : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct CheckRow: View {
    let label: String
    let pass: Bool

    @Environment(\.cairnTokens) private var t

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: pass ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(pass ? t.verifiedInk : t.dangerInk)
                .font(.system(size: 14))
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(t.textBody)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct ActionButton: View {
    let label: String
    var icon: String? = nil
    let role: Role
    let action: () -> Void

    enum Role { case primary, secondary, danger, quiet }

    @Environment(\.cairnTokens) private var t

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(ink)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var bg: Color {
        switch role {
        case .primary: t.primary
        case .secondary: t.surfaceAlt
        case .danger: t.danger
        case .quiet: Color.clear
        }
    }
    private var ink: Color {
        switch role {
        case .primary: t.primaryInk
        case .secondary: t.text
        case .danger: t.bg.opacity(0.95)  // light text on red
        case .quiet: t.textMuted
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("DryRun — review (live mode)") {
    DryRunSheet()
        .cairnTheme()
}

#Preview("DryRun — review (dry-run mode)") {
    DryRunSheet(dryRunByDefault: true)
        .cairnTheme()
}

#Preview("DryRun — tripped (forced)") {
    DryRunSheet(forceTripped: true)
        .cairnTheme()
}

#Preview("DryRun — dark") {
    DryRunSheet()
        .cairnTheme()
        .preferredColorScheme(.dark)
}
#endif
