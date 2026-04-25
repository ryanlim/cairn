import SwiftUI
import CairnCore

/// Wave 4 pending-review surface. Not a direct port from the prototype —
/// the prototype predates the positive-deletion signal — but holds to the
/// prototype's design language: `AppHeader`, `KeylineSection`, `CairnCard`,
/// `MockAssetThumb`, `Callout`, per-row bordered buttons that match
/// `ExcludedScreen`'s "Remove" chip.
///
/// Content:
///   - Mass-offload banner at the top when the last scan's burst exceeds
///     `CairnAppModel.massOffloadThreshold`. Two primary affordances:
///     "Bulk exclude" (route through `actions.bulkExcludeRecentOffload`)
///     and an implicit "Review one-by-one" (the rest of the screen).
///   - "Aging out" section — candidates held by quarantine, each with a
///     countdown showing when they become eligible to trash.
///   - "Unconfirmed" section — candidates with no positive deletion signal
///     at all. Only appears in `.strict` mode; `.trusting` sends these
///     straight to trash candidates so they never land here.
///
/// Per-row affordances mirror the Excluded screen's compact button style:
/// two chips ("Trash now", "Exclude") on the trailing edge.
public struct PendingReviewScreen: View {

    public let heldCandidates: [CairnFixtures.CandidateFixture]
    public let unconfirmedCandidates: [CairnFixtures.CandidateFixture]
    /// Quarantine countdown per candidate id. Populated by the host from
    /// `LiveReconciliation.confirmedDeletedAt`. Missing ids skip the
    /// countdown (falls back to "held").
    public let confirmedDeletedAt: [String: Date]
    public let quarantineDays: Int
    public let massOffloadCount: Int
    public let showsMassOffloadBanner: Bool
    public let onBack: () -> Void
    public let onApprove: ([String]) -> Void
    public let onExclude: ([String]) -> Void
    public let onDismiss: ([String]) -> Void
    public let onBulkExcludeOffload: () -> Void

    @Environment(\.cairnTokens) private var t
    @State private var pendingAction: PendingAction?
    @State private var selectionMode: Bool = false
    @State private var selectedFilenames: Set<String> = []

    private enum PendingAction: Identifiable {
        case approve(filename: String)
        case exclude(filename: String)
        case dismiss(filename: String)
        case bulkOffload(count: Int)
        case bulkApprove(count: Int)
        case bulkExcludeSelected(count: Int)
        case bulkDismiss(count: Int)
        case trashAll(count: Int)

        var id: String {
            switch self {
            case .approve(let name): return "approve-\(name)"
            case .exclude(let name): return "exclude-\(name)"
            case .dismiss(let name): return "dismiss-\(name)"
            case .bulkOffload(let n): return "bulk-\(n)"
            case .bulkApprove(let n): return "bulk-approve-\(n)"
            case .bulkExcludeSelected(let n): return "bulk-exclude-\(n)"
            case .bulkDismiss(let n): return "bulk-dismiss-\(n)"
            case .trashAll(let n): return "trash-all-\(n)"
            }
        }
    }

    public init(
        heldCandidates: [CairnFixtures.CandidateFixture] = [],
        unconfirmedCandidates: [CairnFixtures.CandidateFixture] = [],
        confirmedDeletedAt: [String: Date] = [:],
        quarantineDays: Int = 14,
        massOffloadCount: Int = 0,
        showsMassOffloadBanner: Bool = false,
        onBack: @escaping () -> Void = {},
        onApprove: @escaping ([String]) -> Void = { _ in },
        onExclude: @escaping ([String]) -> Void = { _ in },
        onDismiss: @escaping ([String]) -> Void = { _ in },
        onBulkExcludeOffload: @escaping () -> Void = {}
    ) {
        self.heldCandidates = heldCandidates
        self.unconfirmedCandidates = unconfirmedCandidates
        self.confirmedDeletedAt = confirmedDeletedAt
        self.quarantineDays = quarantineDays
        self.massOffloadCount = massOffloadCount
        self.showsMassOffloadBanner = showsMassOffloadBanner
        self.onBack = onBack
        self.onApprove = onApprove
        self.onExclude = onExclude
        self.onDismiss = onDismiss
        self.onBulkExcludeOffload = onBulkExcludeOffload
    }

    private var totalCount: Int { heldCandidates.count + unconfirmedCandidates.count }
    private var isEmpty: Bool { totalCount == 0 }

    public var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if isEmpty {
                        emptyState
                    } else {
                        if showsMassOffloadBanner {
                            massOffloadCallout
                        }
                        if !selectionMode && totalCount > 1 {
                            trashAllButton
                        }
                        if !heldCandidates.isEmpty {
                            heldSection
                        }
                        if !unconfirmedCandidates.isEmpty {
                            unconfirmedSection
                        }
                        // Trailing space so the last row clears the
                        // floating bulk-action bar in selection mode.
                        Spacer(minLength: selectionMode ? 120 : 40)
                    }
                }
                // Spring-driven entry/exit for the mass-offload
                // callout when burst detection toggles. Paired with
                // `.transition(.cairnBanner)` on the callout itself
                // so the motion matches Status-screen banners.
                .cairnBannerAnimation(value: showsMassOffloadBanner)
            }
            .background(t.bg)

            if selectionMode {
                bulkActionBar
                    .transition(.cairnBannerBottom)
            }
        }
        .cairnBannerAnimation(value: selectionMode)
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            confirmationButtons
        } message: {
            confirmationMessage
        }
    }

    // MARK: - Header

    private var header: some View {
        AppHeader(
            title: selectionMode ? (selectedFilenames.isEmpty ? "Select items" : "\(selectedFilenames.count) selected") : "Pending review",
            subtitle: selectionMode ? nil : (isEmpty
                ? "Nothing waiting — every candidate has been handled"
                : subtitleCopy),
            leading: {
                if selectionMode {
                    Button(action: exitSelectionMode) {
                        Text("Cancel")
                            .font(.system(size: 15))
                            .foregroundStyle(t.textBody)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: onBack) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Status")
                                .font(.system(size: 15))
                        }
                        .foregroundStyle(t.textBody)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            },
            trailing: {
                if !isEmpty {
                    if selectionMode {
                        Button(action: toggleSelectAll) {
                            Text(allSelected ? "None" : "All")
                                .font(.system(size: 13, weight: .semibold))
                                .tracking(0.66)
                                .foregroundStyle(t.textBody)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button(action: enterSelectionMode) {
                            Text("Select")
                                .font(.system(size: 13, weight: .semibold))
                                .tracking(0.66)
                                .foregroundStyle(t.textBody)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        )
    }

    private var allFilenames: [String] {
        (heldCandidates + unconfirmedCandidates).map(\.name)
    }

    private var allSelected: Bool {
        !allFilenames.isEmpty && Set(allFilenames).isSubset(of: selectedFilenames)
    }

    private func enterSelectionMode() {
        selectionMode = true
        selectedFilenames = []
    }

    private func exitSelectionMode() {
        selectionMode = false
        selectedFilenames = []
    }

    private func toggleSelectAll() {
        if allSelected {
            selectedFilenames = []
        } else {
            selectedFilenames = Set(allFilenames)
        }
    }

    private func toggleSelection(_ filename: String) {
        if selectedFilenames.contains(filename) {
            selectedFilenames.remove(filename)
        } else {
            selectedFilenames.insert(filename)
        }
    }

    // MARK: - Bulk action bar

    private var bulkActionBar: some View {
        VStack(spacing: 0) {
            Divider().background(t.divider)
            HStack(spacing: 10) {
                bulkChip(
                    label: "Move \(selectedFilenames.count) to Trash",
                    foreground: t.dangerInk,
                    disabled: selectedFilenames.isEmpty,
                    action: { pendingAction = .bulkApprove(count: selectedFilenames.count) }
                )
                bulkChip(
                    label: "Dismiss \(selectedFilenames.count)",
                    foreground: t.textBody,
                    disabled: selectedFilenames.isEmpty,
                    action: { pendingAction = .bulkDismiss(count: selectedFilenames.count) }
                )
                bulkChip(
                    label: "Exclude \(selectedFilenames.count)",
                    foreground: t.textBody,
                    disabled: selectedFilenames.isEmpty,
                    action: { pendingAction = .bulkExcludeSelected(count: selectedFilenames.count) }
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(t.surface)
    }

    private func bulkChip(label: String, foreground: Color, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(disabled ? t.textHint : foreground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(t.bg)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(t.divider, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(CairnPressStyle())
        .disabled(disabled)
    }

    private var subtitleCopy: String {
        var parts: [String] = []
        if !heldCandidates.isEmpty {
            parts.append("\(heldCandidates.count) aging out")
        }
        if !unconfirmedCandidates.isEmpty {
            parts.append("\(unconfirmedCandidates.count) unconfirmed")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Trash all

    private var trashAllButton: some View {
        Button(action: { pendingAction = .trashAll(count: totalCount) }) {
            HStack(spacing: 8) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                Text("Trash all \(totalCount) now")
                    .font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(t.dangerInk)
            .background(t.dangerSoft)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(CairnPressStyle())
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(t.verifiedSoft)
                    .frame(width: 56, height: 56)
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(t.verifiedInk)
            }
            .padding(.bottom, 14)

            Text("Nothing to review")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(t.text)
                .padding(.bottom, 6)

            Text("Recent deletions are either ready to move to Immich's Trash or still inside the quarantine window. Anything that needs your input will show up here.")
                .font(.system(size: 13))
                .foregroundStyle(t.textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .padding(.horizontal, 40)
        .padding(.bottom, 20)
    }

    // MARK: - Mass-offload callout

    private var massOffloadCallout: some View {
        Callout(.pending, icon: "arrow.down.circle") {
            VStack(alignment: .leading, spacing: 10) {
                (Text("Detected \(massOffloadCount) deletions in a recent scan — that's a lot at once. If you were intentionally offloading photos to free up space, exclude them now so ") + .cairnWord + Text(" stops flagging them."))
                    .fixedSize(horizontal: false, vertical: true)
                CairnChip("Bulk exclude \(massOffloadCount)") {
                    pendingAction = .bulkOffload(count: massOffloadCount)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .transition(.cairnBanner)
    }

    // MARK: - Sections

    private var heldSection: some View {
        Group {
            KeylineSection("Aging out") {
                Text("\(heldCandidates.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.99)
                    .foregroundStyle(t.textMuted)
                    .monospacedDigit()
            }
            CairnCard {
                VStack(spacing: 0) {
                    ForEach(Array(heldCandidates.enumerated()), id: \.element.id) { idx, c in
                        PendingReviewRow(
                            candidate: c,
                            countdown: countdownFor(c),
                            selectionMode: selectionMode,
                            isSelected: selectedFilenames.contains(c.name),
                            onToggleSelect: { toggleSelection(c.name) },
                            onApprove: { pendingAction = .approve(filename: c.name) },
                            onExclude: { pendingAction = .exclude(filename: c.name) },
                            onDismiss: { pendingAction = .dismiss(filename: c.name) }
                        )
                        if idx < heldCandidates.count - 1 {
                            RowDivider()
                        }
                    }
                }
            }
            .padding(.bottom, 20)
        }
    }

    private var unconfirmedSection: some View {
        Group {
            KeylineSection("Unconfirmed") {
                Text("\(unconfirmedCandidates.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.99)
                    .foregroundStyle(t.textMuted)
                    .monospacedDigit()
            }
            Callout(.info, icon: "questionmark.circle") {
                (Text("These weren't caught by the deletion log — they may have left your library before ") + .cairnWord + Text(" was watching. Review each one before trashing."))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            CairnCard {
                VStack(spacing: 0) {
                    ForEach(Array(unconfirmedCandidates.enumerated()), id: \.element.id) { idx, c in
                        PendingReviewRow(
                            candidate: c,
                            countdown: nil,
                            selectionMode: selectionMode,
                            isSelected: selectedFilenames.contains(c.name),
                            onToggleSelect: { toggleSelection(c.name) },
                            onApprove: { pendingAction = .approve(filename: c.name) },
                            onExclude: { pendingAction = .exclude(filename: c.name) },
                            onDismiss: { pendingAction = .dismiss(filename: c.name) }
                        )
                        if idx < unconfirmedCandidates.count - 1 {
                            RowDivider()
                        }
                    }
                }
            }
            .padding(.bottom, 20)
        }
    }

    // MARK: - Countdown

    private func countdownFor(_ candidate: CairnFixtures.CandidateFixture) -> String? {
        guard let confirmedAt = confirmedDeletedAt[candidate.id] else { return nil }
        let eligibleAt = confirmedAt.addingTimeInterval(TimeInterval(quarantineDays) * 86_400)
        let remaining = eligibleAt.timeIntervalSinceNow
        if remaining <= 0 { return "eligible" }
        let days = Int((remaining / 86_400).rounded(.up))
        return days == 1 ? "eligible in 1 day" : "eligible in \(days) days"
    }

    // MARK: - Confirmation dialog

    private var confirmationTitle: String {
        switch pendingAction {
        case .approve(let name): return "Move \(name) to Trash now?"
        case .exclude(let name): return "Exclude \(name) from future runs?"
        case .dismiss(let name): return "Dismiss \(name)?"
        case .bulkOffload(let n): return "Exclude all \(n) recent deletions?"
        case .bulkApprove(let n): return "Move \(n) selected item\(n == 1 ? "" : "s") to Trash now?"
        case .bulkExcludeSelected(let n): return "Exclude \(n) selected item\(n == 1 ? "" : "s")?"
        case .bulkDismiss(let n): return "Dismiss \(n) selected item\(n == 1 ? "" : "s")?"
        case .trashAll(let n): return "Move all \(n) item\(n == 1 ? "" : "s") to Trash now?"
        case .none:              return ""
        }
    }

    private var confirmationMessage: Text {
        switch pendingAction {
        case .approve:
            return Text("Skips the quarantine wait. Immich keeps it in Trash for 30 days.")
        case .exclude:
            return Text("Future runs will skip this one. You can unexclude later from Settings.")
        case .dismiss:
            return Text("Removes it from the pending list. If you delete the same photo again, it will reappear.")
        case .bulkOffload:
            return Text("All \(massOffloadCount) recent deletions will move to the excluded list. ") + .cairnWord + Text(" will stop considering them.")
        case .bulkApprove:
            return Text("Skips the quarantine wait for every selected item. Immich keeps them in Trash for 30 days.")
        case .bulkExcludeSelected:
            return Text("Future runs will skip every selected item. You can unexclude later from Settings.")
        case .bulkDismiss:
            return Text("Removes selected items from the pending list. If you delete them again, they will reappear.")
        case .trashAll:
            return Text("Skips the quarantine wait for every item. Immich keeps them in Trash for 30 days.")
        case .none:
            return Text("")
        }
    }

    @ViewBuilder
    private var confirmationButtons: some View {
        switch pendingAction {
        case .approve(let name):
            Button("Move to Trash", role: .destructive) { onApprove([name]) }
            Button("Cancel", role: .cancel) {}
        case .exclude(let name):
            Button("Exclude", role: .destructive) { onExclude([name]) }
            Button("Cancel", role: .cancel) {}
        case .dismiss(let name):
            Button("Dismiss") { onDismiss([name]) }
            Button("Cancel", role: .cancel) {}
        case .bulkOffload:
            Button("Exclude all", role: .destructive) { onBulkExcludeOffload() }
            Button("Cancel", role: .cancel) {}
        case .bulkApprove:
            Button("Move selected to Trash", role: .destructive) {
                onApprove(Array(selectedFilenames))
                exitSelectionMode()
            }
            Button("Cancel", role: .cancel) {}
        case .bulkExcludeSelected:
            Button("Exclude selected", role: .destructive) {
                onExclude(Array(selectedFilenames))
                exitSelectionMode()
            }
            Button("Cancel", role: .cancel) {}
        case .bulkDismiss:
            Button("Dismiss selected") {
                onDismiss(Array(selectedFilenames))
                exitSelectionMode()
            }
            Button("Cancel", role: .cancel) {}
        case .trashAll:
            Button("Move all to Trash", role: .destructive) {
                onApprove(allFilenames)
            }
            Button("Cancel", role: .cancel) {}
        case .none:
            EmptyView()
        }
    }
}

// MARK: - Row

/// Single pending-review row. Shape mirrors `ExcludedRow` so the two
/// screens feel like siblings: thumbnail, filename, metadata line, trailing
/// chips. Two chips instead of one because pending-review has two actions
/// where excluded has only "Remove."
private struct PendingReviewRow: View {
    let candidate: CairnFixtures.CandidateFixture
    /// "eligible in N days" or similar. `nil` when unconfirmed (no positive
    /// signal, so no quarantine clock to count down).
    let countdown: String?
    let selectionMode: Bool
    let isSelected: Bool
    let onToggleSelect: () -> Void
    let onApprove: () -> Void
    let onExclude: () -> Void
    let onDismiss: () -> Void

    @Environment(\.cairnTokens) private var t

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if selectionMode {
                selectionIndicator
            }
            ImmichAssetThumb(assetId: candidate.assetId, filename: candidate.name, size: 44, isLivePair: candidate.isLivePair)

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name)
                    .font(.system(size: 13, design: .monospaced))
                    .tracking(-0.065)
                    .foregroundStyle(t.text)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 8) {
                    Text(kindLabel)
                    if let countdown {
                        Text("·")
                        Text(countdown)
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(t.textMuted)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !selectionMode {
                HStack(spacing: 8) {
                    RowIconButton(
                        systemName: "trash",
                        tone: .danger,
                        accessibilityLabel: "Move \(candidate.name) to Trash",
                        action: onApprove
                    )
                    RowIconButton(
                        systemName: "xmark.circle",
                        tone: .neutral,
                        accessibilityLabel: "Dismiss \(candidate.name)",
                        action: onDismiss
                    )
                    RowIconButton(
                        systemName: "shield",
                        tone: .neutral,
                        accessibilityLabel: "Exclude \(candidate.name)",
                        action: onExclude
                    )
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            // In selection mode the whole row becomes a toggle — large
            // hit target, easier for thumb navigation through a long
            // list. Chips are hidden in this mode so there's no
            // competing gesture.
            if selectionMode { onToggleSelect() }
        }
    }

    private var selectionIndicator: some View {
        ZStack {
            Circle()
                .strokeBorder(isSelected ? t.primary : t.divider, lineWidth: isSelected ? 0 : 1)
                .background(Circle().fill(isSelected ? t.primary : .clear))
                .frame(width: 22, height: 22)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .accessibilityLabel(isSelected ? "Selected" : "Not selected")
    }

    private var kindLabel: String {
        switch candidate.kind {
        case .photo:    return "photo"
        case .video:    return "video"
        case .livePair: return "live-pair"
        }
    }
}

// MARK: - Row action button

/// Icon-only action button used on Pending Review rows, where two
/// labeled chips wouldn't fit alongside the filename + metadata.
/// The trash icon reads as "Move to Trash" (danger-tone), the shield
/// icon as "Exclude" (neutral). Full action phrasing lives in the
/// `accessibilityLabel` so VoiceOver users get the same context
/// sighted users recognize from the icon + color.
private struct RowIconButton: View {
    enum Tone { case danger, neutral }

    let systemName: String
    let tone: Tone
    let accessibilityLabel: String
    let action: () -> Void

    @Environment(\.cairnTokens) private var t

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 32, height: 28)
                .background(t.bg)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(t.divider, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(CairnPressStyle())
        .accessibilityLabel(accessibilityLabel)
    }

    private var foreground: Color {
        switch tone {
        case .danger:  return t.dangerInk
        case .neutral: return t.textBody
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Pending review — populated") {
    let held = Array(CairnFixtures.candidates.prefix(5))
    let unconfirmed = Array(CairnFixtures.candidates.dropFirst(5).prefix(3))
    let confirmedAt: [String: Date] = Dictionary(
        uniqueKeysWithValues: held.enumerated().map { i, c in
            (c.id, Date(timeIntervalSinceNow: -TimeInterval(i) * 86_400))
        }
    )
    return PendingReviewScreen(
        heldCandidates: held,
        unconfirmedCandidates: unconfirmed,
        confirmedDeletedAt: confirmedAt,
        quarantineDays: 14,
        massOffloadCount: 0,
        showsMassOffloadBanner: false
    )
    .cairnTheme()
}

#Preview("Pending review — mass offload") {
    let held = Array(CairnFixtures.candidates.prefix(12))
    let confirmedAt: [String: Date] = Dictionary(
        uniqueKeysWithValues: held.map { ($0.id, Date(timeIntervalSinceNow: -3_600)) }
    )
    return PendingReviewScreen(
        heldCandidates: held,
        unconfirmedCandidates: [],
        confirmedDeletedAt: confirmedAt,
        quarantineDays: 14,
        massOffloadCount: 312,
        showsMassOffloadBanner: true
    )
    .cairnTheme()
}

#Preview("Pending review — empty") {
    PendingReviewScreen()
        .cairnTheme()
}

#Preview("Pending review — dark") {
    let held = Array(CairnFixtures.candidates.prefix(4))
    return PendingReviewScreen(
        heldCandidates: held,
        confirmedDeletedAt: Dictionary(uniqueKeysWithValues: held.map { ($0.id, Date()) }),
        quarantineDays: 14
    )
    .cairnTheme()
    .preferredColorScheme(.dark)
}
#endif
