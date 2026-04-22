import SwiftUI
import CairnCore

/// The settings root screen. Mirrors the prototype's `screens/settings.jsx`.
///
/// Section list (top-to-bottom):
///   1. Immich server — URL, API key (with Reveal/Hide + Copy + auto-hide),
///      connection status.
///   2. Safety rails — percent threshold slider, count floor, dry-run toggle,
///      deletion-strictness picker (Wave 4), excluded-assets row.
///   3. Notifications — abort alerts, verbose journal.
///   4. Permissions — Photos access, background refresh.
///   5. Appearance — palette editor entry point.
///   6. Danger zone — reset index, clear journal, sign out.
///
/// Microcopy is verbatim from the prototype. The "Don't screenshot." warning
/// on API-key reveal is explicitly called out in HANDOFF.md as load-bearing —
/// don't paraphrase. See HANDOFF.md "Keep these copies verbatim."
///
/// The screen owns *no* persistent state of its own — it edits a `Binding` to
/// `CairnSettings` (so the iOS app layer can persist via `SettingsStore`) and
/// surfaces button taps as closures. Local UI state (Reveal toggle, "Copied"
/// flash) lives inside child views since it's strictly ephemeral.
public struct SettingsScreen: View {

    /// The connection-status pill the URL section terminates with. Mirrors
    /// the prototype's healthy/offline/auth-stale variants.
    public enum ConnectionStatus: Sendable, Equatable {
        case healthy(latencyMs: Int)
        case offline
        case authStale
    }

    @Binding public var settings: CairnSettings
    public let serverUrl: String
    public let apiKey: String
    public let apiKeyMasked: String
    public let excludedCount: Int
    public let connectionStatus: ConnectionStatus
    public let onOpenExcluded: () -> Void
    public let onOpenPalette: () -> Void
    public let onResetIndex: () -> Void
    public let onClearJournal: () -> Void
    public let onSignOut: () -> Void

    @Environment(\.cairnTokens) private var t

    public init(
        settings: Binding<CairnSettings>,
        serverUrl: String,
        apiKey: String,
        apiKeyMasked: String,
        excludedCount: Int,
        connectionStatus: ConnectionStatus,
        onOpenExcluded: @escaping () -> Void = {},
        onOpenPalette: @escaping () -> Void = {},
        onResetIndex: @escaping () -> Void = {},
        onClearJournal: @escaping () -> Void = {},
        onSignOut: @escaping () -> Void = {}
    ) {
        self._settings = settings
        self.serverUrl = serverUrl
        self.apiKey = apiKey
        self.apiKeyMasked = apiKeyMasked
        self.excludedCount = excludedCount
        self.connectionStatus = connectionStatus
        self.onOpenExcluded = onOpenExcluded
        self.onOpenPalette = onOpenPalette
        self.onResetIndex = onResetIndex
        self.onClearJournal = onClearJournal
        self.onSignOut = onSignOut
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                AppHeader(title: "Settings")

                immichServerSection
                safetyRailsSection
                notificationsSection
                permissionsSection
                appearanceSection
                dangerZoneSection
                footer
            }
        }
        .background(t.bg)
    }

    // MARK: - Immich server

    private var immichServerSection: some View {
        Group {
            KeylineSection("Immich server")
            CairnCard {
                VStack(spacing: 0) {
                    KeyValRow(
                        "URL",
                        value: serverUrl.replacingOccurrences(of: "https://", with: ""),
                        mono: true,
                        chevron: true,
                        onTap: {}
                    )
                    RowDivider()
                    ApiKeyRow(rawKey: apiKey, masked: apiKeyMasked)
                    RowDivider()
                    KeyValRow("Connection", value: { ConnectionPill(status: connectionStatus) })
                }
            }
        }
    }

    // MARK: - Safety rails

    private var safetyRailsSection: some View {
        Group {
            KeylineSection("Safety rails")
            CairnCard {
                VStack(spacing: 0) {
                    SliderRow(
                        label: "Percent threshold",
                        sub: String(
                            format: "Abort if a run would trash more than %.1f%% of matched assets.",
                            settings.maxDeletePercent
                        ),
                        value: $settings.maxDeletePercent,
                        range: 0.5...5,
                        step: 0.1,
                        format: { String(format: "%.1f%%", $0) }
                    )
                    RowDivider()
                    KeyValRow(
                        "Count floor",
                        value: "\(settings.minDeleteFloor) assets",
                        chevron: true,
                        onTap: {}
                    )
                    RowDivider()
                    ToggleRow(
                        "Dry-run by default",
                        sub: "Every scheduled run is preview-only. You confirm each trash manually.",
                        value: $settings.dryRunByDefault
                    )
                    RowDivider()
                    StrictnessRow(strictness: $settings.deletionStrictness)
                    RowDivider()
                    KeyValRow(
                        "Excluded assets",
                        value: { excludedValue }
                    )
                    .onTapGesture { onOpenExcluded() }
                }
            }
        }
    }

    @ViewBuilder
    private var excludedValue: some View {
        HStack(spacing: 6) {
            Text(excludedCount > 0 ? "\(excludedCount) protected" : "None")
                .font(.system(size: 15))
                .foregroundStyle(excludedCount > 0 ? t.infoInk : t.textMuted)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(t.textHint)
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        Group {
            KeylineSection("Notifications")
            CairnCard {
                VStack(spacing: 0) {
                    ToggleRow(
                        "Alert on aborted run",
                        sub: "Local notification when a safety rail trips. Next open surfaces the review screen.",
                        value: $settings.notifyOnAbort
                    )
                    RowDivider()
                    ToggleRow(
                        "Verbose journal",
                        sub: "Record every API request in deletion-journal.jsonl.",
                        value: $settings.verboseLogging
                    )
                }
            }
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        Group {
            KeylineSection("Permissions")
            CairnCard {
                VStack(spacing: 0) {
                    KeyValRow(
                        "Photos access",
                        value: { Text("Full library").foregroundStyle(t.verifiedInk) },
                        chevron: true,
                        onTap: {}
                    )
                    RowDivider()
                    KeyValRow(
                        "Background refresh",
                        value: { Text("Allowed").foregroundStyle(t.verifiedInk) },
                        chevron: true,
                        onTap: {}
                    )
                }
            }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Group {
            KeylineSection("Appearance")
            CairnCard {
                KeyValRow(
                    "Palette",
                    value: { Text("Accents & neutrals").foregroundStyle(t.textMuted) },
                    chevron: true,
                    onTap: onOpenPalette
                )
            }
        }
    }

    // MARK: - Danger zone

    private var dangerZoneSection: some View {
        Group {
            KeylineSection("Danger zone")
            CairnCard {
                VStack(spacing: 0) {
                    KeyValRow(
                        "Reset index",
                        value: { Text("Re-seed").foregroundStyle(t.dangerInk) },
                        chevron: true,
                        onTap: onResetIndex
                    )
                    RowDivider()
                    KeyValRow(
                        "Clear journal",
                        value: { Text("Delete JSONL").foregroundStyle(t.dangerInk) },
                        chevron: true,
                        onTap: onClearJournal
                    )
                    RowDivider()
                    KeyValRow(
                        "Sign out of server",
                        value: { Text("Remove key").foregroundStyle(t.dangerInk) },
                        chevron: true,
                        onTap: onSignOut
                    )
                }
            }
            .padding(.bottom, 4)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 2) {
            Text("cairn v0.2.0 · not affiliated with Immich")
            (Text("MIT · ")
                + Text("open source").underline()
                + Text(" · ")
                + Text("privacy").underline())
        }
        .font(.system(size: 11))
        .foregroundStyle(t.textHint)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .padding(.bottom, 24)
    }
}

// MARK: - Connection pill

/// Compact "● healthy · 42ms" / "● offline" pill that lives on the right
/// side of the URL/Connection row. Mirrors the prototype's inline span.
private struct ConnectionPill: View {
    let status: SettingsScreen.ConnectionStatus
    @Environment(\.cairnTokens) private var t

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dotColor).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(inkColor)
        }
    }

    private var label: String {
        switch status {
        case .healthy(let ms): return "healthy · \(ms)ms"
        case .offline:         return "offline"
        case .authStale:       return "auth expired"
        }
    }
    private var inkColor: Color {
        switch status {
        case .healthy: t.verifiedInk
        case .offline, .authStale: t.dangerInk
        }
    }
    private var dotColor: Color { inkColor.opacity(0.85) }
}

// MARK: - Slider row

/// Slider with a label, live tabular-numeral value, and a sub-explainer
/// underneath. Mirrors the prototype's `SliderRow`. We use the platform
/// `Slider` instead of the JSX custom-track look — closer to iOS muscle
/// memory, and one fewer thing for the iOS engineer to maintain.
private struct SliderRow: View {
    let label: String
    let sub: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    @Environment(\.cairnTokens) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 15))
                    .foregroundStyle(t.textBody)
                Spacer()
                Text(format(value))
                    .font(.system(size: 13, design: .monospaced).monospacedDigit())
                    .foregroundStyle(t.textMuted)
            }
            if let sub {
                Text(sub)
                    .font(.system(size: 12))
                    .foregroundStyle(t.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
            }
            Slider(value: $value, in: range, step: step)
                .tint(t.text)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }
}

// MARK: - Strictness picker row

/// Wave 4 segmented picker for `DeletionStrictness`. The copy below the
/// picker is our own (the prototype was built before this landed) and is
/// kept short and factual — matches the existing sysadmin-tool tone.
private struct StrictnessRow: View {
    @Binding var strictness: DeletionStrictness
    @Environment(\.cairnTokens) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Deletion strictness")
                .font(.system(size: 15))
                .foregroundStyle(t.textBody)
            Picker("Deletion strictness", selection: $strictness) {
                Text("Strict").tag(DeletionStrictness.strict)
                Text("Trusting").tag(DeletionStrictness.trusting)
            }
            .pickerStyle(.segmented)
            Text(explanation)
                .font(.system(size: 12))
                .foregroundStyle(t.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private var explanation: String {
        switch strictness {
        case .strict:
            return "Strict: only confirmed deletions trash; rest go to pending review."
        case .trusting:
            return "Trusting: any diff candidate eligible (faster, less safe)."
        }
    }
}

// MARK: - API key row

/// Row showing a masked key by default, with Reveal/Hide + Copy buttons.
/// Reveal swaps to a tinted surface, surfaces a "Don't screenshot." warning,
/// and auto-hides after 8s (per the prototype). Copy briefly flashes
/// "Copied ✓" before reverting.
///
/// The "Hiding automatically in a few seconds. Don't screenshot." copy is
/// load-bearing — see HANDOFF.md "Keep these copies verbatim."
public struct ApiKeyRow: View {
    public let rawKey: String
    public let masked: String
    public let initiallyRevealed: Bool

    @State private var revealed: Bool
    @State private var copied: Bool = false
    @State private var revealTask: Task<Void, Never>? = nil
    @State private var copyTask: Task<Void, Never>? = nil

    @Environment(\.cairnTokens) private var t

    public init(rawKey: String, masked: String, initiallyRevealed: Bool = false) {
        self.rawKey = rawKey
        self.masked = masked
        self.initiallyRevealed = initiallyRevealed
        self._revealed = State(initialValue: initiallyRevealed)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("API key")
                    .font(.system(size: 15))
                    .foregroundStyle(t.textBody)
                Spacer()
                Button(action: toggleReveal) {
                    Text(revealed ? "Hide" : "Reveal")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(revealed ? t.dangerInk : t.infoInk)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
                Button(action: copyKey) {
                    Text(copied ? "Copied \u{2713}" : "Copy")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(copied ? t.verifiedInk : t.textMuted)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            }
            Text(revealed ? rawKey : masked)
                .font(.system(size: 13, design: .monospaced).monospacedDigit())
                .tracking(revealed ? 0 : 0.5)
                .foregroundStyle(revealed ? t.text : t.textMuted)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(revealed ? t.dangerSoft : t.surfaceAlt)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(revealed ? t.dangerInk.opacity(0.35) : t.divider, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .animation(.easeInOut(duration: 0.16), value: revealed)
            if revealed {
                HStack(spacing: 5) {
                    Text("\u{26A0}").font(.system(size: 10))
                    Text("Hiding automatically in a few seconds. Don't screenshot.")
                        .font(.system(size: 11))
                }
                .foregroundStyle(t.dangerInk)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .onDisappear {
            revealTask?.cancel()
            copyTask?.cancel()
        }
    }

    private func toggleReveal() {
        revealed.toggle()
        revealTask?.cancel()
        guard revealed else { return }
        revealTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled {
                revealed = false
            }
        }
    }

    private func copyKey() {
        #if canImport(UIKit)
        UIPasteboard.general.string = rawKey
        #endif
        copied = true
        copyTask?.cancel()
        copyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if !Task.isCancelled {
                copied = false
            }
        }
    }
}

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Preview helpers

#if DEBUG
private struct SettingsScreenPreviewHost: View {
    @State var settings: CairnSettings = .defaults
    var connection: SettingsScreen.ConnectionStatus = .healthy(latencyMs: 42)
    var excludedCount: Int = 7

    var body: some View {
        SettingsScreen(
            settings: $settings,
            serverUrl: "https://immich.home.arpa",
            apiKey: "imk_live_8a3F2b9cD1eP4qR7sT0uVwXyZ_nH3k",
            apiKeyMasked: "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}nH3k",
            excludedCount: excludedCount,
            connectionStatus: connection,
            onOpenExcluded: {},
            onOpenPalette: {},
            onResetIndex: {},
            onClearJournal: {},
            onSignOut: {}
        )
        .cairnTheme()
    }
}

/// Preview host that mounts the API key row already revealed so the warning
/// state is visible in Xcode previews without manually tapping.
private struct SettingsScreenRevealedPreviewHost: View {
    @State var settings: CairnSettings = .defaults

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                AppHeader(title: "Settings")
                KeylineSection("Immich server")
                CairnCard {
                    VStack(spacing: 0) {
                        KeyValRow(
                            "URL",
                            value: "immich.home.arpa",
                            mono: true,
                            chevron: true,
                            onTap: {}
                        )
                        RowDivider()
                        ApiKeyRow(
                            rawKey: "imk_live_8a3F2b9cD1eP4qR7sT0uVwXyZ_nH3k",
                            masked: "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}nH3k",
                            initiallyRevealed: true
                        )
                    }
                }
            }
        }
        .background(Color.clear)
        .cairnTheme()
    }
}

#Preview("Settings — healthy") {
    SettingsScreenPreviewHost()
}

#Preview("Settings — dark") {
    SettingsScreenPreviewHost()
        .preferredColorScheme(.dark)
}

#Preview("Settings — API key revealed") {
    SettingsScreenRevealedPreviewHost()
}
#endif
