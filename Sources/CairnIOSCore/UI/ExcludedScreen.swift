import SwiftUI
import CairnCore

/// The Excluded (allowlist) screen — filenames protected from future runs.
///
/// Mirrors the prototype `cairn/screens/excluded.jsx`. Reachable from
/// Settings → Safety rails → Excluded assets.
///
/// Two sources feed this list today:
///   · Manual exclusion from a run detail (primary flow)
///   · (Future) rule-based excludes like "never trash videos > 30s"
///
/// Each row pairs a thumbnail with its filename + "from run <id>" context so
/// the user can see *why* something is protected and unexclude with one tap.
/// Empty state explains how to get here from a run.
///
/// Microcopy is verbatim from the prototype — see HANDOFF.md "Keep these
/// copies verbatim". Don't paraphrase without designer review.
public struct ExcludedScreen: View {
    public let entries: [ExcludedScreenEntry]
    public let onBack: () -> Void
    /// Filenames the user wants to remove from the allowlist. The host wires
    /// this to a real `ExclusionStore.remove(...)` call (after translating
    /// filename → checksum). UI-side we work in filenames because that's
    /// what the row identity is and what the prototype's `excluded` Set
    /// holds; checksum lookup is a host concern.
    public let onUnexclude: ([String]) -> Void

    @Environment(\.cairnTokens) private var t
    @State private var pendingClearAll = false
    @State private var pendingRemoval: ExcludedScreenEntry?

    public init(
        entries: [ExcludedScreenEntry] = ExcludedScreenEntry.previewEntries,
        onBack: @escaping () -> Void = {},
        onUnexclude: @escaping ([String]) -> Void = { _ in }
    ) {
        self.entries = entries
        self.onBack = onBack
        self.onUnexclude = onUnexclude
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if entries.isEmpty {
                    emptyState
                } else {
                    explainerCard
                    sectionHeader
                    listCard
                }
                Spacer(minLength: 40)
            }
        }
        .background(t.bg)
        // "Clear all" confirm dialog. The prototype uses window.confirm with
        // copy: "Unexclude all <N> assets? They'll be eligible for future runs again."
        .confirmationDialog(
            "Unexclude all \(entries.count) \(entries.count == 1 ? "asset" : "assets")?",
            isPresented: $pendingClearAll,
            titleVisibility: .visible
        ) {
            Button("Unexclude all", role: .destructive) {
                onUnexclude(entries.map { $0.filename })
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They'll be eligible for future runs again.")
        }
        // Per-row remove confirm — mirrors the prototype's toast-on-confirm
        // pattern. We don't ship a toast system here; the closure handoff
        // is the seam.
        .confirmationDialog(
            pendingRemoval.map { "Remove \($0.filename) from excluded list?" } ?? "",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let entry = pendingRemoval {
                Button("Remove", role: .destructive) {
                    onUnexclude([entry.filename])
                }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            Text("Future runs can trash this again.")
        }
    }

    // MARK: - Header

    private var header: some View {
        AppHeader(
            title: "Excluded",
            // Subtitle copy verbatim from screens/excluded.jsx.
            subtitle: entries.isEmpty
                ? "Nothing excluded — every indexed asset is fair game"
                : "\(entries.count) \(entries.count == 1 ? "asset" : "assets") protected from future runs",
            leading: {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Settings")
                            .font(.system(size: 15))
                    }
                    .foregroundStyle(t.textBody)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(t.infoSoft)
                    .frame(width: 56, height: 56)
                Image(systemName: "shield")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(t.infoInk)
            }
            .padding(.bottom, 14)

            // Copy verbatim from screens/excluded.jsx::EmptyState.
            Text("No assets excluded")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(t.text)
                .padding(.bottom, 6)

            (Text("Open any run, select the assets you want to keep in scope, and tap ")
                + Text("Exclude").foregroundColor(t.textBody).bold()
                + Text(". They'll show up here."))
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

    // MARK: - Explainer card

    private var explainerCard: some View {
        // Info-tone Callout. Copy verbatim from screens/excluded.jsx.
        Callout(.info, icon: "shield") {
            Text("Excluded assets stay indexed — cairn still knows they exist — but every future reconcile will skip them. Useful for photos you plan to re-trash yourself, or anything you'd rather keep on server even if it's gone from the phone.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Section header with "Clear all"

    private var sectionHeader: some View {
        KeylineSection("Protected assets") {
            Button {
                pendingClearAll = true
            } label: {
                Text("Clear all")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.99)
                    .foregroundStyle(t.textMuted)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Rows

    private var listCard: some View {
        CairnCard {
            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                    ExcludedRow(entry: entry) {
                        pendingRemoval = entry
                    }
                    if idx < entries.count - 1 {
                        RowDivider()
                    }
                }
            }
        }
        .padding(.bottom, 20)
    }
}

// MARK: - Row

/// A single allowlist row: thumb + filename + kind/size/run context + Remove.
/// Mirrors prototype `screens/excluded.jsx::ExcludedRow`.
private struct ExcludedRow: View {
    let entry: ExcludedScreenEntry
    let onRemove: () -> Void

    @Environment(\.cairnTokens) private var t

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            MockAssetThumb(filename: entry.filename, size: 44, isLivePair: entry.isLivePair)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.filename)
                    .font(.system(size: 13, design: .monospaced))
                    .tracking(-0.065) // -0.005em at 13pt
                    .foregroundStyle(t.text)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 8) {
                    Text(kindLabel)
                    Text("·")
                    Text(sizeLabel)
                    if let runSuffix = runSuffix {
                        Text("·")
                        (Text("from run ")
                            + Text(runSuffix).font(.system(size: 11.5, design: .monospaced)))
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(t.textMuted)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onRemove) {
                Text("Remove")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.66) // ~0.06em at 11pt
                    .foregroundStyle(t.textBody)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(t.bg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(t.divider, lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(entry.filename) from excluded list")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var kindLabel: String {
        switch entry.kind {
        case .photo:    return "photo"
        case .video:    return "video"
        case .livePair: return "live-pair"
        }
    }

    private var sizeLabel: String {
        // The prototype uses `bytes / 1_048_576` with one decimal (always
        // MB). Match that exactly so the row reads identically; the shared
        // `formatBytes` helper would switch to GB on large values.
        String(format: "%.1f MB", Double(entry.bytes) / 1_048_576)
    }

    private var runSuffix: String? {
        guard let runId = entry.metadata.fromRunId, runId.count >= 8 else {
            return entry.metadata.fromRunId
        }
        return String(runId.suffix(8))
    }
}

// MARK: - Public entry model

/// One row in the excluded list. We model the row in UI terms (filename,
/// bytes, kind, paired-flag, plus the on-disk metadata) so the screen can
/// render without reaching back to the candidate fixtures or the live
/// `ExclusionStore`. Hosts assemble these by joining their PHAsset/server
/// records against `ExclusionStore.snapshot()`.
public struct ExcludedScreenEntry: Sendable, Identifiable {
    public var id: String { filename }
    public let filename: String
    public let bytes: Int
    public let kind: CairnFixtures.CandidateFixture.Kind
    public let isLivePair: Bool
    public let metadata: ExclusionMetadata

    public init(
        filename: String,
        bytes: Int,
        kind: CairnFixtures.CandidateFixture.Kind,
        isLivePair: Bool,
        metadata: ExclusionMetadata
    ) {
        self.filename = filename
        self.bytes = bytes
        self.kind = kind
        self.isLivePair = isLivePair
        self.metadata = metadata
    }
}

extension ExcludedScreenEntry {
    /// Preview fixtures: take the first few candidate fixtures and pretend
    /// the user excluded them from a recent run. Stable run id mirrors
    /// `CairnFixtures.runs[0].id` so the "from run …034389BC" suffix lines
    /// up across previews.
    public static let previewEntries: [ExcludedScreenEntry] = {
        let runId = "2026-04-21T17:57:15Z-034389BC"
        let addedAt = Date(timeIntervalSinceNow: -3_600 * 6)
        return CairnFixtures.candidates.prefix(5).map { c in
            ExcludedScreenEntry(
                filename: c.name,
                bytes: c.bytes,
                kind: c.kind,
                isLivePair: c.isLivePair,
                metadata: ExclusionMetadata(
                    addedAt: addedAt,
                    fromRunId: runId,
                    reason: nil
                )
            )
        }
    }()
}

// MARK: - Preview

#if DEBUG
#Preview("Excluded — populated") {
    ExcludedScreen()
        .cairnTheme()
}

#Preview("Excluded — empty") {
    ExcludedScreen(entries: [])
        .cairnTheme()
}

#Preview("Excluded — dark") {
    ExcludedScreen()
        .cairnTheme()
        .preferredColorScheme(.dark)
}
#endif
