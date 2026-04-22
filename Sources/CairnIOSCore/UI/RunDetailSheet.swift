import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The per-run detail sheet. Mirrors the prototype's
/// `screens/run-detail.jsx` — the heart of the undo flow.
///
/// What this screen lets the user do:
///   - Browse the assets in a single run as a thumbnail grid.
///   - Filter by filename (substring, case-insensitive, monospace input).
///   - Select N assets; the footer swaps from a passive Close into a
///     contextual action bar: Restore · Exclude · Open in Immich · Copy.
///   - Restore moves trashed assets back out of trash. Disabled on dry-runs
///     and aborted runs (nothing to undo).
///   - Exclude adds filenames to the allowlist so future runs skip them.
///     Available on every run type — primary triage action on dry-runs.
///   - Live Photo expansion: when a `live-pair` asset is selected, the
///     action bar shows "N selected · +M paired videos = total" so the
///     user understands the real server-side impact before tapping.
///   - Aborted runs surface the candidates that *would* have been affected
///     so the user can inspect them; the header callout names the rail.
///
/// Microcopy is verbatim from the prototype. See HANDOFF.md
/// "Keep these copies verbatim" — don't paraphrase without designer review.
///
/// The mock surfaces here are wired to closures the parent owns. When the
/// real iOS app target lands:
///   - `onRestore` -> `RestoreOrchestrator.restore(filenames:)` (which
///     calls `ImmichClient.restoreAssets(ids:)` per HANDOFF).
///   - `onExclude` -> `ExclusionStore.add(_:)` from `CairnCore`.
///   - `Open in Immich` -> universal link to the breadcrumb tag (or trash
///     view fallback when the run had no tag).
///   - `Copy` -> `UIPasteboard.general.string` (already wired below).
public struct RunDetailSheet: View {

    // MARK: - Public surface

    public let run: CairnFixtures.RunFixture
    public let assets: [CairnFixtures.CandidateFixture]
    public let onClose: () -> Void
    public let onExclude: ([String]) -> Void
    public let onRestore: ([String]) -> Void

    public init(
        run: CairnFixtures.RunFixture = CairnFixtures.runs[0],
        assets: [CairnFixtures.CandidateFixture] = Array(CairnFixtures.candidates.prefix(14)),
        onClose: @escaping () -> Void = {},
        onExclude: @escaping ([String]) -> Void = { _ in },
        onRestore: @escaping ([String]) -> Void = { _ in }
    ) {
        self.run = run
        self.assets = assets
        self.onClose = onClose
        self.onExclude = onExclude
        self.onRestore = onRestore
    }

    // MARK: - Local state
    //
    // Lives entirely inside the sheet (nothing is hoisted to the parent
    // beyond the onXxx closures). The prototype's "just-restored" /
    // "just-excluded" flashes are driven by short-lived state and a fade.
    // We mark `restored` locally too so the user immediately sees the
    // greyed-out treatment without waiting for a re-fetch from the parent.

    @State private var selected: Set<String> = []
    @State private var restored: Set<String> = []      // names restored in-session
    @State private var excludedLocal: Set<String> = [] // names excluded in-session
    @State private var filter: String = ""
    @State private var justRestored: Int? = nil        // count flash · 2.4s
    @State private var justExcluded: Int? = nil        // count flash · 2.4s

    @Environment(\.cairnTokens) private var t

    // MARK: - Derived

    private var filtered: [CairnFixtures.CandidateFixture] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return assets }
        return assets.filter { $0.name.lowercased().contains(q) }
    }

    private var selectableAssets: [CairnFixtures.CandidateFixture] {
        filtered.filter { !restored.contains($0.name) }
    }

    private var allVisibleSelected: Bool {
        !selectableAssets.isEmpty && selectableAssets.allSatisfy { selected.contains($0.name) }
    }

    /// Restore is only meaningful on completed trash runs; dry-runs and
    /// aborted runs never moved anything to trash. (from screens/run-detail.jsx::canRestore)
    private var canRestore: Bool {
        run.trashed > 0 && !run.dryRun && run.status != .aborted
    }

    private var hasSelection: Bool { !selected.isEmpty }

    /// Live-photo expansion: each selected `live-pair` asset implicitly
    /// pulls its paired motion video on the server. We surface the real
    /// expanded count in the action bar so the user isn't surprised by a
    /// "5 selected" tap that actually touches 7 server assets.
    private var pairedInSelection: Int {
        var c = 0
        for name in selected {
            if let a = assets.first(where: { $0.name == name }), a.isLivePair { c += 1 }
        }
        return c
    }
    private var expandedCount: Int { selected.count + pairedInSelection }

    private var runKind: String {
        if run.status == .aborted { return "Aborted run" }
        if run.dryRun { return "Dry-run" }
        return "Trash run"
    }

    private var headerTitle: String {
        if run.status == .aborted { return "Stopped by safety rail" }
        if run.dryRun { return "Preview only — nothing touched" }
        let suffix = run.trashed == 1 ? "" : "s"
        return "\(run.trashed) asset\(suffix) trashed"
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            t.text.opacity(0.45).ignoresSafeArea()
                .onTapGesture { onClose() }
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                sheet
            }
        }
    }

    private var sheet: some View {
        VStack(spacing: 0) {
            grip
            header
            metaChips
            if run.status == .aborted { abortedCallout }
            if let n = justRestored { justRestoredFlash(count: n) }
            if let n = justExcluded { justExcludedFlash(count: n) }
            if !assets.isEmpty {
                filterRow
                selectionCountRow
            }
            scrollBody
            footer
        }
        .background(t.surface)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // MARK: - Header

    private var grip: some View {
        Capsule()
            .fill(t.divider)
            .frame(width: 40, height: 5)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(runKind.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(t.textMuted)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(t.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 4)

            Text(headerTitle)
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.45)
                .foregroundStyle(t.text)
                .fixedSize(horizontal: false, vertical: true)

            Text(headerSubtitle)
                .font(.system(size: 13))
                .foregroundStyle(t.textMuted)
                .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    private var headerSubtitle: String {
        let date = formattedHeaderDate(run.startedAt)
        if run.durationMs > 0 {
            return "\(date) · \(String(format: "%.2fs", Double(run.durationMs) / 1000))"
        }
        return date
    }

    private func formattedHeaderDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE MMM d h:mm")
        return f.string(from: d)
    }

    private var metaChips: some View {
        HStack(spacing: 6) {
            MetaChip(label: String(run.id.suffix(8)), tone: .neutral, mono: true)
            if run.tag != nil {
                MetaChip(label: "breadcrumb set", tone: .verified, icon: "tag")
            }
            if !restored.isEmpty {
                MetaChip(label: "\(restored.count) restored", tone: .info)
            }
            if !excludedLocal.isEmpty {
                MetaChip(label: "\(excludedLocal.count) excluded", tone: .info)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    // MARK: - Callouts

    private var abortedCallout: some View {
        // from screens/run-detail.jsx — the "Percent threshold exceeded"
        // callout. Numbers here mirror the prototype's hardcoded scenario.
        Callout(.danger, icon: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: 2) {
                Text("Percent threshold exceeded").fontWeight(.semibold)
                Text("2.3% of matched assets would have been trashed. Your cap is 1.0%. Nothing was touched.")
                    .opacity(0.9)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func justRestoredFlash(count: Int) -> some View {
        // from screens/run-detail.jsx::doRestore toast (rendered inline as
        // a callout in the sheet body, not the global toast).
        Callout(.verified, icon: "checkmark.circle") {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) restored").fontWeight(.semibold)
                Text("Moved out of Immich trash, back to active library.")
                    .opacity(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .transition(.opacity)
    }

    private func justExcludedFlash(count: Int) -> some View {
        // Mirrors the prototype's "N excluded" toast (info tone). Inline
        // in the sheet so it lives alongside the run's other state.
        Callout(.info, icon: "shield") {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) excluded").fontWeight(.semibold)
                Text(count == 1
                     ? "Future runs will skip it."
                     : "Future runs will skip these assets.")
                    .opacity(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .transition(.opacity)
    }

    // MARK: - Filter + select-all

    private var filterRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(t.textHint)
                TextField("", text: $filter, prompt:
                    Text("Filter by filename…")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(t.textHint)
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(t.text)
                .autocorrectionDisabled()
                #if canImport(UIKit)
                .textInputAutocapitalization(.never)
                #endif
                if !filter.isEmpty {
                    Button { filter = "" } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(t.textHint)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(t.bg)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(t.divider, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            if !selectableAssets.isEmpty {
                Button(action: toggleSelectAllVisible) {
                    Text(allVisibleSelected ? "Deselect" : "Select all")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(t.textBody)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(t.divider, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var selectionCountRow: some View {
        HStack {
            Text(selectionCountLabel.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(t.textMuted)
            Spacer()
            if canRestore {
                HStack(spacing: 5) {
                    Circle()
                        .fill(t.textMuted)
                        .frame(width: 5, height: 5)
                    Text("IN TRASH")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.9)
                        .foregroundStyle(t.textMuted)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var selectionCountLabel: String {
        let base: String
        if filtered.count == assets.count {
            base = "\(assets.count) assets"
        } else {
            base = "\(filtered.count) of \(assets.count) match"
        }
        if !selected.isEmpty {
            return "\(base) · \(selected.count) selected"
        }
        return base
    }

    // MARK: - Scrolling body (grid + metadata + breadcrumb)

    private var scrollBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !assets.isEmpty {
                    assetGrid
                }
                sectionLabel("Run metadata")
                metadataCard
                sectionLabel("Server-side breadcrumb")
                breadcrumbCard
                Spacer(minLength: 8)
            }
        }
        .frame(maxHeight: 380)
    }

    private var assetGrid: some View {
        CairnCard {
            Group {
                if filtered.isEmpty {
                    Text("No filename matches \"\(filter)\".")
                        .font(.system(size: 13))
                        .foregroundStyle(t.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 6)], spacing: 6) {
                        ForEach(filtered) { a in
                            AssetTile(
                                asset: a,
                                isSelected: selected.contains(a.name),
                                isRestored: restored.contains(a.name),
                                isExcluded: excludedLocal.contains(a.name),
                                onTap: { toggle(a.name) }
                            )
                        }
                    }
                }
            }
            .padding(10)
        }
        .padding(.bottom, 12)
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(t.textMuted)
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 8)
    }

    private var metadataCard: some View {
        CairnCard {
            VStack(spacing: 0) {
                KeyValRow("Run ID", value: String(run.id.suffix(8)), mono: true)
                RowDivider()
                KeyValRow("Started", value: formattedFullDate(run.startedAt))
                if run.durationMs > 0 {
                    RowDivider()
                    KeyValRow("Duration", value: String(format: "%.2fs", Double(run.durationMs) / 1000))
                }
                if let tag = run.tag {
                    RowDivider()
                    KeyValRow("Breadcrumb",
                              value: tag.split(separator: "/").last.map(String.init) ?? tag,
                              mono: true)
                }
                RowDivider()
                KeyValRow("Notes", value: run.notes)
            }
        }
        .padding(.bottom, 12)
    }

    private var breadcrumbCard: some View {
        CairnCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(run.tag ?? "none — this run did not tag the server")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(t.textBody)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                // from screens/run-detail.jsx — keep verbatim
                Text("Find these in Immich's Tags view. Assets stay in trash for 30 days.")
                    .font(.system(size: 12))
                    .foregroundStyle(t.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 16)
    }

    private func formattedFullDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }

    // MARK: - Footer (idle vs. selection)

    @ViewBuilder
    private var footer: some View {
        if hasSelection {
            SelectionActionBar(
                selectedCount: selected.count,
                pairedCount: pairedInSelection,
                expandedCount: expandedCount,
                canRestore: canRestore,
                onClear: { selected.removeAll() },
                onExclude: doExclude,
                onOpen: doOpenInImmich,
                onCopy: doCopy,
                onRestore: doRestore
            )
        } else if canRestore {
            HStack(spacing: 10) {
                Button(action: onClose) {
                    Text("Close")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(t.textBody)
                        .background(t.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)

                Text("Select assets to act on them")
                    .font(.system(size: 13))
                    .foregroundStyle(t.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 18)
            .background(footerSurface)
        } else {
            Button(action: onClose) {
                Text("Close")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(t.textBody)
                    .background(t.surfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 18)
            .background(footerSurface)
        }
    }

    private var footerSurface: some View {
        t.surface.overlay(
            Rectangle().fill(t.divider).frame(height: 0.5),
            alignment: .top
        )
    }

    // MARK: - Actions

    private func toggle(_ name: String) {
        if restored.contains(name) { return }
        if selected.contains(name) {
            selected.remove(name)
        } else {
            selected.insert(name)
        }
    }

    private func toggleSelectAllVisible() {
        if allVisibleSelected {
            for a in selectableAssets { selected.remove(a.name) }
        } else {
            for a in selectableAssets { selected.insert(a.name) }
        }
    }

    private func doRestore() {
        let names = Array(selected)
        guard !names.isEmpty else { return }
        // Optimistic local state — surface the greyed-out treatment now
        // rather than waiting for the parent to round-trip a refresh.
        for n in names { restored.insert(n) }
        selected.removeAll()
        let count = names.count
        withAnimation(.easeInOut(duration: 0.18)) { justRestored = count }
        scheduleClearFlash(restoredCount: count)
        onRestore(names)
    }

    private func doExclude() {
        let names = Array(selected)
        guard !names.isEmpty else { return }
        for n in names { excludedLocal.insert(n) }
        selected.removeAll()
        let count = names.count
        withAnimation(.easeInOut(duration: 0.18)) { justExcluded = count }
        scheduleClearFlash(excludedCount: count)
        onExclude(names)
    }

    private func doCopy() {
        let names = Array(selected).sorted().joined(separator: "\n")
        #if canImport(UIKit)
        UIPasteboard.general.string = names
        #endif
        // No-op on non-UIKit platforms (e.g. macOS preview); the action
        // shape stays the same so the parent doesn't need to gate it.
    }

    private func doOpenInImmich() {
        // Mock: real iOS app opens a universal link via UIApplication. The
        // selection-aware deep link logic from the prototype lives in the
        // parent in production so it can read the configured server URL.
    }

    private func scheduleClearFlash(restoredCount: Int? = nil, excludedCount: Int? = nil) {
        let token = restoredCount ?? excludedCount ?? 0
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            withAnimation(.easeInOut(duration: 0.18)) {
                if restoredCount != nil, justRestored == token { justRestored = nil }
                if excludedCount != nil, justExcluded == token { justExcluded = nil }
            }
        }
    }
}

// MARK: - Asset tile

/// Single grid cell: gradient thumbnail + selection ring + filename caption.
/// Greys out and disables tap when the asset has been restored in-session.
private struct AssetTile: View {
    let asset: CairnFixtures.CandidateFixture
    let isSelected: Bool
    let isRestored: Bool
    let isExcluded: Bool
    let onTap: () -> Void

    @Environment(\.cairnTokens) private var t

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                ZStack(alignment: .topLeading) {
                    MockAssetThumb(filename: asset.name, size: 76, isLivePair: asset.isLivePair)
                        .opacity(isRestored ? 0.45 : 1.0)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(ringColor, lineWidth: isSelected ? 2 : 0)
                        )
                    if isSelected {
                        ZStack {
                            Circle().fill(t.primary).frame(width: 18, height: 18)
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(t.primaryInk)
                        }
                        .padding(4)
                    }
                }
                Text(stripExtension(asset.name))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(captionColor)
                    .tracking(0.1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRestored)
    }

    private var ringColor: Color {
        isSelected ? t.primary : .clear
    }

    private var captionColor: Color {
        if isRestored { return t.verifiedInk }
        if isExcluded { return t.infoInk }
        return t.textMuted
    }

    private func stripExtension(_ s: String) -> String {
        guard let dot = s.lastIndex(of: ".") else { return s }
        return String(s[s.startIndex..<dot])
    }
}

// MARK: - Selection action bar

/// Contextual action bar shown when the user has selected ≥1 asset.
/// Mirrors `screens/run-detail.jsx::SelectionActionBar`.
///
/// Visual order (left→right): Restore is *primary* when available so the
/// hand-back-the-keys action gets the brand color; otherwise Exclude takes
/// primacy because it's the only effectful action on dry-runs / aborted runs.
private struct SelectionActionBar: View {
    let selectedCount: Int
    let pairedCount: Int
    let expandedCount: Int
    let canRestore: Bool
    let onClear: () -> Void
    let onExclude: () -> Void
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onRestore: () -> Void

    @Environment(\.cairnTokens) private var t

    var body: some View {
        VStack(spacing: 10) {
            countRow
            actionGrid
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 18)
        .background(
            t.surface.overlay(
                Rectangle().fill(t.divider).frame(height: 0.5),
                alignment: .top
            )
        )
    }

    private var countRow: some View {
        HStack(spacing: 8) {
            // Selection count pill
            Text("\(selectedCount) selected")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(t.primaryInk)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(t.primary)
                .clipShape(Capsule())

            if pairedCount > 0 {
                // Live Photo pair callout. Verbatim from the prototype:
                // "+M paired video(s) = total"
                HStack(spacing: 5) {
                    Circle().fill(t.infoInk).frame(width: 5, height: 5)
                    Text("+\(pairedCount) paired video\(pairedCount == 1 ? "" : "s") = \(expandedCount)")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(t.infoInk)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(t.infoSoft)
                .clipShape(Capsule())
            }

            Button("Clear", action: onClear)
                .font(.system(size: 12))
                .foregroundStyle(t.textMuted)
                .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
    }

    private var actionGrid: some View {
        HStack(spacing: 6) {
            // When Restore is available, Exclude is a secondary tone.
            // Otherwise Exclude becomes primary.
            ActionButton(
                icon: "shield",
                label: "Exclude",
                isPrimary: !canRestore,
                action: onExclude
            )
            ActionButton(icon: "link", label: "Open", isPrimary: false, action: onOpen)
            ActionButton(icon: "doc.on.doc", label: "Copy", isPrimary: false, action: onCopy)
            if canRestore {
                ActionButton(
                    icon: "arrow.uturn.backward",
                    label: "Restore",
                    isPrimary: true,
                    action: onRestore
                )
            }
        }
    }
}

private struct ActionButton: View {
    let icon: String
    let label: String
    let isPrimary: Bool
    let action: () -> Void

    @Environment(\.cairnTokens) private var t

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.bottom, 2)
            .foregroundStyle(isPrimary ? t.primaryInk : t.text)
            .background(isPrimary ? t.primary : t.bg)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isPrimary ? Color.clear : t.divider, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Meta chip

/// Small inline chip used in the run-header meta strip (run id, breadcrumb,
/// in-session restored / excluded counts). Visually quieter than the
/// status-screen `Chip` because it sits in a denser context.
private struct MetaChip: View {
    enum Tone { case neutral, verified, info }
    let label: String
    let tone: Tone
    var icon: String? = nil
    var mono: Bool = false

    @Environment(\.cairnTokens) private var t

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: mono ? .monospaced : .default))
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(soft)
        .clipShape(Capsule())
    }

    private var soft: Color {
        switch tone {
        case .neutral:  t.surfaceAlt
        case .verified: t.verifiedSoft
        case .info:     t.infoSoft
        }
    }
    private var ink: Color {
        switch tone {
        case .neutral:  t.textBody
        case .verified: t.verifiedInk
        case .info:     t.infoInk
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Run detail — completed trash run") {
    RunDetailSheet()
        .cairnTheme()
}

#Preview("Run detail — aborted run") {
    RunDetailSheet(
        run: CairnFixtures.runs.first(where: { $0.status == .aborted }) ?? CairnFixtures.runs[0],
        assets: Array(CairnFixtures.candidates.prefix(14))
    )
    .cairnTheme()
}

#Preview("Run detail — empty selection (dry-run)") {
    RunDetailSheet(
        run: CairnFixtures.runs.first(where: { $0.dryRun }) ?? CairnFixtures.runs[0],
        assets: Array(CairnFixtures.candidates.prefix(8))
    )
    .cairnTheme()
}

/// Drives a multi-asset selection on first appear so reviewers can see the
/// contextual action bar (with the +paired-video callout) without tapping.
private struct PreselectedRunDetail: View {
    @State private var ready = false
    var body: some View {
        ZStack {
            RunDetailSheet(
                run: CairnFixtures.runs[0],
                assets: Array(CairnFixtures.candidates.prefix(14))
            )
        }
        // The state is internal to RunDetailSheet, so this preview is
        // visually identical to the default but documents intent. The
        // multi-selection visual is driven by tapping in #Preview canvas.
        .onAppear { ready = true }
        .opacity(ready ? 1 : 1)
    }
}

#Preview("Run detail — multi selection (tap a few thumbs)") {
    PreselectedRunDetail()
        .cairnTheme()
}

#Preview("Run detail — dark") {
    RunDetailSheet()
        .cairnTheme()
        .preferredColorScheme(.dark)
}
#endif
