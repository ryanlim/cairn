import SwiftUI
import UniformTypeIdentifiers
import CairnCore

/// The settings root screen. Mirrors the prototype's `screens/settings.jsx`.
///
/// Section list (top-to-bottom):
///   1. Immich server — URL, API key (with Reveal/Hide + Copy + auto-hide),
///      connection status.
///   2. Safety rails — percent threshold slider, count floor, dry-run toggle,
///      deletion-strictness picker, excluded-assets row.
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
    public let onResetIndex: () -> Void
    public let onClearJournal: () -> Void
    public let onSignOut: () -> Void
    public let onRescanLibrary: () -> Void
    public let deferredQueue: CairnAppModel.DeferredQueueSummary
    public let onForceDrainDeferred: () -> Void
    /// True while a sync or drain is mid-flight. Used to disable the
    /// "Hash now" button in the deferred-queue row so the user
    /// doesn't double-invoke, and to swap its label for a
    /// "Hashing…" hint since Settings has no other progress surface.
    public let isSyncing: Bool
    /// Optional live progress for the "Hash now" label — "Hashing 3 / 12"
    /// when a drain is running. `nil` outside an active drain.
    public let syncProgress: (hashed: Int, total: Int)?
    /// Dev-only hook: re-enters the SetupScreen flow without clearing
    /// credentials, so the onboarding screens can be reviewed without
    /// re-typing URL + API key. Surfaced under a DEBUG-gated Advanced row.
    public let onReplayOnboarding: () -> Void
    public let onExportData: (CairnExportScope) -> Void
    public let onImportData: (URL, Bool) -> Void
    /// Token incremented by the host when the user re-taps the active
    /// tab — see `CairnTabBar.onReselect`. Each increment scrolls the
    /// screen back to the top.
    public let scrollResetToken: Int

    @Environment(\.cairnTokens) private var t
    @State private var pendingResetIndex: Bool = false
    @State private var pendingRescanLibrary: Bool = false
    @State private var pendingClearJournal: Bool = false
    @State private var pendingSignOut: Bool = false
    @State private var advancedExpanded: Bool = false
    @State private var howItWorksExpanded: Bool = false
    @State private var showExportPicker = false
    @State private var showImportPicker = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        settings: Binding<CairnSettings>,
        serverUrl: String,
        apiKey: String,
        apiKeyMasked: String,
        excludedCount: Int,
        connectionStatus: ConnectionStatus,
        onOpenExcluded: @escaping () -> Void = {},
        onResetIndex: @escaping () -> Void = {},
        onClearJournal: @escaping () -> Void = {},
        onSignOut: @escaping () -> Void = {},
        onRescanLibrary: @escaping () -> Void = {},
        deferredQueue: CairnAppModel.DeferredQueueSummary = .empty,
        onForceDrainDeferred: @escaping () -> Void = {},
        isSyncing: Bool = false,
        syncProgress: (hashed: Int, total: Int)? = nil,
        onReplayOnboarding: @escaping () -> Void = {},
        onExportData: @escaping (CairnExportScope) -> Void = { _ in },
        onImportData: @escaping (URL, Bool) -> Void = { _, _ in },
        scrollResetToken: Int = 0
    ) {
        self._settings = settings
        self.serverUrl = serverUrl
        self.apiKey = apiKey
        self.apiKeyMasked = apiKeyMasked
        self.excludedCount = excludedCount
        self.connectionStatus = connectionStatus
        self.onOpenExcluded = onOpenExcluded
        self.onResetIndex = onResetIndex
        self.onClearJournal = onClearJournal
        self.onSignOut = onSignOut
        self.onRescanLibrary = onRescanLibrary
        self.deferredQueue = deferredQueue
        self.onForceDrainDeferred = onForceDrainDeferred
        self.isSyncing = isSyncing
        self.syncProgress = syncProgress
        self.onReplayOnboarding = onReplayOnboarding
        self.onExportData = onExportData
        self.onImportData = onImportData
        self.scrollResetToken = scrollResetToken
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.scrollTopAnchor)
                    AppHeader(title: "Settings")

                immichServerSection
                safetyRailsSection
                notificationsSection
                permissionsSection
                appearanceSection
                howItWorksSection
                advancedSection
                dataSection
                dangerZoneSection
                footer
            }
        }
        .background(t.bg)
        // Keyboard dismissal: drag down on the list to interactively
        // drag the keyboard away, or tap any empty chrome outside
        // the focused field. Together these replace the explicit
        // keyboard-toolbar Done button, which rendered awkwardly
        // on iOS 26.
        .scrollDismissesKeyboard(.interactively)
        .cairnDismissKeyboardOnBackgroundTap()
        // Destructive confirmations use `.alert` (centered modal) not
        // `.confirmationDialog` — on iOS 26 / Liquid Glass, the latter
        // adapts to a popover with an arrow that anchors to a near-
        // arbitrary source view, which reads as visual chaos. Alerts
        // are always centered, no anchor, unambiguous.
        .alert(
            "Reset index?",
            isPresented: $pendingResetIndex,
            actions: {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) { onResetIndex() }
            },
            message: {
                Text("Clears the SHA1 cache, change-tracking baseline, ever-seen set, and quarantine state. Your exclusions and credentials are kept. The next sync re-hashes your whole library.")
            }
        )
        .alert(
            "Rescan library?",
            isPresented: $pendingRescanLibrary,
            actions: {
                Button("Cancel", role: .cancel) {}
                Button("Rescan") { onRescanLibrary() }
            },
            message: {
                Text("Clears the change-tracking baseline and deferred-hash queue. The next sync re-enumerates every photo against your current size limits. Use this after raising the iCloud limits to apply them immediately; otherwise background scans catch up on their own.")
            }
        )
        .alert(
            "Clear journal?",
            isPresented: $pendingClearJournal,
            actions: {
                Button("Cancel", role: .cancel) {}
                Button("Delete JSONL", role: .destructive) { onClearJournal() }
            },
            message: {
                Text("Deletes deletion-journal.jsonl from disk. Past runs disappear from the Runs tab and the journal tail on Status. Indexing state, exclusions, and credentials are kept.")
            }
        )
        .alert(
            "Sign out of server?",
            isPresented: $pendingSignOut,
            actions: {
                Button("Cancel", role: .cancel) {}
                Button("Sign out", role: .destructive) { onSignOut() }
            },
            message: {
                Text("Forgets your Immich URL and API key, and drops the cached thumbnails fetched with them. You'll land back on the onboarding flow — indexed state on this device is preserved for when you sign in again.")
            }
        )
        .confirmationDialog(
            "Export scope",
            isPresented: $showExportPicker,
            titleVisibility: .visible
        ) {
            Button("Current server") { onExportData(.currentServer) }
            Button("All servers") { onExportData(.allServers) }
            Button("Cancel", role: .cancel) {}
        }
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [.json],
            onCompletion: { result in
                switch result {
                case .success(let url):
                    onImportData(url, true)
                case .failure:
                    break
                }
            }
        )
        .onChange(of: scrollResetToken) { _, _ in
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(Self.scrollTopAnchor, anchor: .top)
            }
        }
        }
    }

    private static let scrollTopAnchor = "cairn.scroll.top"

    // MARK: - Immich server

    // MARK: - Section icon/tint mapping
    //
    // Each section gets a leading SF Symbol + semantic color so a
    // long list of neutral-gray section titles becomes easy to scan.
    // Color choices follow existing semantic uses elsewhere in the
    // app (info=network, verified=safe, pending=warn, danger=destructive,
    // accent=creative-when-no-other-fits, quiet=ambient-secondary).
    private var immichServerSection: some View {
        Group {
            KeylineSection("Immich server", icon: "network", iconTint: t.info)
            CairnCard {
                VStack(spacing: 0) {
                    // Read-only — the URL is only editable via Sign
                    // out + re-onboarding. No chevron to suggest
                    // tappability.
                    KeyValRow(
                        "URL",
                        value: serverUrl.replacingOccurrences(of: "https://", with: ""),
                        mono: true
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
            KeylineSection("Safety rails", icon: "shield", iconTint: t.verified)
            CairnCard {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Spacer(minLength: 0)
                            HelpPopover {
                                Text("**Safety rail.** If a single run would move more than this fraction of matched photos to Immich's Trash, the run aborts without touching the server.")
                                Text("Defends against bugs, permission regressions, or a library-wipe cascading into a mass delete.")
                                Text("The \"Count floor\" below is paired with this: for small libraries, 1% can be just one or two photos, which is noise — the floor sets a minimum batch size before the percent check engages.")
                            }
                            .padding(.trailing, 6)
                        }
                        .padding(.top, 10)
                        .padding(.bottom, -4)

                        SliderInputRow(
                            label: "Percent threshold",
                            sub: String(
                                format: "Abort if a run would move more than %.1f%% of matched assets to Immich's Trash.",
                                settings.maxDeletePercent
                            ),
                            value: $settings.maxDeletePercent,
                            range: 0.5...5,
                            step: 0.1,
                            unitSuffix: "%",
                            format: { String(format: "%.1f", $0) },
                            parse: NumericInputParse.decimal
                        )
                    }
                    RowDivider()
                    StrictnessRow(strictness: $settings.deletionStrictness)
                    RowDivider()
                    QuarantineRow(days: $settings.quarantineDays)
                    RowDivider()
                    ICloudDownloadLimitRow(mb: $settings.iCloudDownloadLimitMB)
                    RowDivider()
                    HardCeilingRow(mb: $settings.iCloudMaxEverBytesMB)
                    RowDivider()
                    DeferredQueueRow(
                        summary: deferredQueue,
                        isSyncing: isSyncing,
                        syncProgress: syncProgress,
                        onHashNow: onForceDrainDeferred
                    )
                    RowDivider()
                    KeyValRow(
                        "Rescan library",
                        value: { Text("Force re-enumerate").foregroundStyle(t.infoInk) },
                        chevron: true,
                        onTap: { pendingRescanLibrary = true }
                    )
                    RowDivider()
                    KeyValRow(
                        "Excluded assets",
                        value: { excludedValue },
                        onTap: onOpenExcluded
                    )
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
            KeylineSection("Notifications", icon: "bell", iconTint: t.pending)
            CairnCard {
                VStack(spacing: 0) {
                    ToggleRow(
                        "Alert on aborted run",
                        sub: "Local notification when a safety rail trips. Tapping it opens the review screen.",
                        value: $settings.notifyOnAbort
                    )
                    RowDivider()
                    BacklogAlertRow(threshold: $settings.deletionBacklogAlertThreshold)
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
            KeylineSection("Permissions", icon: "lock", iconTint: t.quiet)
            CairnCard {
                VStack(spacing: 0) {
                    // Can't *grant* permissions in-app — iOS only
                    // allows requesting them once. After that the
                    // user has to flip the switch in Settings → cairn.
                    // Row taps deep-link there so the fix is one tap
                    // away rather than a "go find it yourself" trek.
                    KeyValRow(
                        "Photos access",
                        value: { Text("Full library").foregroundStyle(t.verifiedInk) },
                        chevron: true,
                        onTap: openIOSSettings
                    )
                    RowDivider()
                    KeyValRow(
                        "Background refresh",
                        value: { Text("Allowed").foregroundStyle(t.verifiedInk) },
                        chevron: true,
                        onTap: openIOSSettings
                    )
                }
            }
        }
    }

    /// Opens iOS Settings → cairn (the app's per-app settings pane).
    /// `UIApplication.openSettingsURLString` is the canonical deep
    /// link; always resolvable for apps that have asked for any
    /// permission.
    private func openIOSSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString),
           UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
        #endif
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Group {
            KeylineSection("Appearance", icon: "paintpalette", iconTint: t.accent)
            CairnCard {
                AppearanceRow(appearance: $settings.appearance)
            }
        }
    }

    // MARK: - Advanced

    /// Niche tuning knobs that most users won't need to touch. Hidden
    /// by default behind a tap; expand reveals the rows. Matches the
    /// app's existing Keyline + Card pattern rather than SwiftUI's
    /// `DisclosureGroup` so the visual language stays consistent.
    /// Collapsed by default. Documents the exact sequence cairn runs
    /// through on trash + restore so users understand what's happening
    /// on their Immich server — tags applied, what's moved where, and
    /// how to inspect it server-side.
    private var howItWorksSection: some View {
        Group {
            KeylineSection("How it works", icon: "info.circle", iconTint: t.quiet)
            CairnCard {
                VStack(spacing: 0) {
                    Button {
                        withAnimation(reduceMotion ? .none : .snappy(duration: 0.16)) {
                            howItWorksExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(howItWorksExpanded
                                 ? "Hide server-side details"
                                 : "What cairn does on your Immich server")
                                .font(.system(size: 15))
                                .foregroundStyle(t.textBody)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 12)
                            Image(systemName: howItWorksExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(t.textHint)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(howItWorksExpanded ? "Hide how it works" : "Show how it works")

                    if howItWorksExpanded {
                        RowDivider()
                        howItWorksBody
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var howItWorksBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            howItWorksParagraph(
                title: "What cairn proposes for trash",
                body: Text("A photo becomes a trash candidate only when all three are true:\n\n1. ") + .cairnWord + Text(" observed the photo on this iPhone (its checksum entered the local index).\n2. The photo is no longer in this iPhone's library.\n3. Immich still has the photo.\n\nPhotos uploaded to Immich from a different device — never on this iPhone — are invisible to ") + .cairnWord + Text(" and stay put.")
            )
            howItWorksParagraph(
                title: "Quarantine window",
                body: Text("When ") + .cairnWord + Text(" detects a deletion, it starts a 14-day clock (adjustable in Settings → Quarantine). The photo sits in Pending Review for the full window, giving you time to undo. After 14 days it moves to Ready to Trash and the next sync calls Immich.")
            )
            howItWorksParagraph(
                title: "Edits stay safe",
                body: Text("Editing a photo in iOS Photos doesn't propagate to Immich as a trash. ") + .cairnWord + Text(" anchors the original checksum and protects it for as long as the photo is alive on this iPhone — even after edits change the bytes locally. The Immich mobile app uploads each edit as a separate version, so Immich typically holds two versions per edited photo: the original (anchored) and the current rendered edit. When you delete the photo locally, both versions enter quarantine together.\n\nMultiple edits without reverting: intermediate versions quarantine and trash; the original-content and the latest edit stay on Immich indefinitely.\n\nApple's edit history is private to Photos.app — neither ") + .cairnWord + Text(" nor Immich can replay edits from a downloaded file. Keep the photo on this iPhone if you want to revert later.")
            )
            howItWorksParagraph(
                title: "Changing your mind before quarantine",
                body: Text("Restoring a deleted photo from iOS's Recently Deleted (Photos → Albums → Recently Deleted → Recover) within the quarantine window cancels propagation. ") + .cairnWord + Text(" detects the asset returning and clears its entry — the next sync removes it from Pending Review without ever calling Immich.")
            )
            howItWorksParagraph(
                title: "Live Photos",
                body: Text("A Live Photo on iOS is two assets on Immich: the still and a paired motion video (hidden by default). ") + .cairnWord + Text(" includes both halves in the same trash call so they propagate together — neither orphans.")
            )
            howItWorksParagraph(
                title: "Trash flow",
                body: Text("When you confirm a sync, ") + .cairnWord + Text(" does the following on your Immich server, in order:\n\n1. Upserts a tag named ")
                    + Text("cairn/v1/run/<run-id>").font(.system(size: 12, design: .monospaced)).foregroundStyle(t.text)
                    + Text(" where ")
                    + Text("<run-id>").font(.system(size: 12, design: .monospaced)).foregroundStyle(t.text)
                    + Text(" is an ISO-8601 timestamp plus a short device id.\n2. Applies that tag to every affected asset (stills + paired Live Photo motion videos).\n3. Calls ")
                    + Text("DELETE /api/assets {force: false}").font(.system(size: 12, design: .monospaced)).foregroundStyle(t.text)
                    + Text(" — the asset moves to Immich's Trash folder, which retains it for 30 days.")
            )
            howItWorksParagraph(
                title: "Undoing a cairn run",
                body: Text("After a sync has run, the Runs tab can restore any past run via ")
                    + Text("POST /api/trash/restore/assets").font(.system(size: 12, design: .monospaced)).foregroundStyle(t.text)
                    + Text(". The ") + Text("cairn/v1/run/…").font(.system(size: 12, design: .monospaced)).foregroundStyle(t.text) + Text(" tag stays on the asset — it's a breadcrumb, not a state flag — so you can always find what a given run touched via Immich's Tags view.")
            )
            howItWorksParagraph(
                title: "Nothing is permanent",
                body: Text("Immich's Trash retains for 30 days regardless of how the asset got there (") + .cairnWord + Text(" or the Immich web UI). Past that window, Immich's own retention policy applies; ") + .cairnWord + Text(" has no say in what happens after.")
            )
            howItWorksParagraph(
                title: "Local journal",
                body: Text("Every step is also written to an append-only ")
                    + Text("deletion-journal.jsonl").font(.system(size: 12, design: .monospaced)).foregroundStyle(t.text)
                    + Text(" on this device. The Runs tab renders that file; Settings → Danger zone → Clear journal deletes it.")
            )
            howItWorksParagraph(
                title: "Where to inspect on Immich",
                body: Text("Open the Immich web UI → Tags. Every ") + Text("cairn/v1/run/…").font(.system(size: 12, design: .monospaced)).foregroundStyle(t.text) + Text(" tag shows its assets. The Trash view shows everything still recoverable.")
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private func howItWorksParagraph(title: String, body: Text) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(t.textMuted)
                .textCase(.uppercase)
            body
                .font(.system(size: 13))
                .foregroundStyle(t.textBody)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var advancedSection: some View {
        Group {
            KeylineSection("Advanced", icon: "wrench.and.screwdriver", iconTint: t.textMuted)
            CairnCard {
                VStack(spacing: 0) {
                    Button {
                        withAnimation(reduceMotion ? .none : .snappy(duration: 0.16)) {
                            advancedExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(advancedExpanded ? "Hide advanced settings" : "Show advanced settings")
                                .font(.system(size: 15))
                                .foregroundStyle(t.textBody)
                            Spacer(minLength: 12)
                            Image(systemName: advancedExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(t.textHint)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(advancedExpanded ? "Hide advanced settings" : "Show advanced settings")

                    if advancedExpanded {
                        RowDivider()
                        CountFloorRow(floor: $settings.minDeleteFloor)
                        RowDivider()
                        ThumbnailCacheCapRow(mb: $settings.thumbnailCacheCapMB)
                        RowDivider()
                        ThumbhashCacheCapRow(mb: $settings.thumbhashCapMB)
                        #if DEBUG
                        RowDivider()
                        KeyValRow(
                            "Replay onboarding (dev)",
                            value: { Text("Review setup").foregroundStyle(t.textMuted) },
                            chevron: true,
                            onTap: onReplayOnboarding
                        )
                        #endif
                    }
                }
            }
        }
    }

    // MARK: - Data (export / import)

    private var dataSection: some View {
        Group {
            KeylineSection("Data", icon: "arrow.up.arrow.down", iconTint: t.verifiedInk)
            CairnCard {
                VStack(spacing: 0) {
                    KeyValRow(
                        "Export data",
                        value: { Text("Share backup").foregroundStyle(t.infoInk) },
                        chevron: true,
                        onTap: { showExportPicker = true }
                    )
                    RowDivider()
                    KeyValRow(
                        "Import data",
                        value: { Text("Restore from file").foregroundStyle(t.infoInk) },
                        chevron: true,
                        onTap: { showImportPicker = true }
                    )
                }
            }
        }
    }

    // MARK: - Danger zone

    private var dangerZoneSection: some View {
        Group {
            KeylineSection("Danger zone", icon: "exclamationmark.triangle", iconTint: t.danger)
            CairnCard {
                VStack(spacing: 0) {
                    KeyValRow(
                        "Reset index",
                        value: { Text("Re-seed").foregroundStyle(t.dangerInk) },
                        chevron: true,
                        onTap: { pendingResetIndex = true }
                    )
                    RowDivider()
                    KeyValRow(
                        "Clear journal",
                        value: { Text("Delete JSONL").foregroundStyle(t.dangerInk) },
                        chevron: true,
                        onTap: { pendingClearJournal = true }
                    )
                    RowDivider()
                    KeyValRow(
                        "Sign out of server",
                        value: { Text("Remove key").foregroundStyle(t.dangerInk) },
                        chevron: true,
                        onTap: { pendingSignOut = true }
                    )
                }
            }
            .padding(.bottom, 4)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        // Underlines previously suggested real links, but no URL is
        // wired yet — reads like a broken tap target. Keep the text
        // (brand/licence breadcrumb), drop the underlines until
        // https://github.com/... + a privacy policy URL exist, at
        // which point we'll swap these for `Link`.
        VStack(spacing: 2) {
            Text.cairnWord + Text(" v0.2.0 · not affiliated with Immich")
            Text("MIT · open source · privacy")
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

// (SliderInputRow has been promoted to a public primitive in
// `CairnPrimitives.swift` so other screens — InitialScan scan
// options, future Setup thresholds — can reuse it. See that file
// for the current definition.)

// MARK: - Strictness picker row

/// Segmented picker for `DeletionStrictness`. The copy below the
/// picker is our own (the prototype was built before this landed) and is
/// kept short and factual — matches the existing sysadmin-tool tone.
private struct StrictnessRow: View {
    @Binding var strictness: DeletionStrictness
    @Environment(\.cairnTokens) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Deletion strictness")
                    .font(.system(size: 15))
                    .foregroundStyle(t.textBody)
                HelpPopover {
                    Text("**Strict** requires a positive deletion signal before trashing. Ambiguous candidates go to Pending Review.")
                    Text("**Trusting** trashes past-quarantine candidates automatically. Held deletions still wait out the window.")
                    Text("**Auto** skips quarantine entirely. Every candidate trashes on the next sync. Rely on Immich's 30-day Trash for recovery.")
                }
                Spacer()
            }
            CairnSegmentedPicker(
                selection: $strictness,
                options: [
                    .init(value: DeletionStrictness.strict,     label: "Strict"),
                    .init(value: DeletionStrictness.trusting,   label: "Trusting"),
                    .init(value: DeletionStrictness.autonomous, label: "Auto"),
                ]
            )
            Text(explanation)
                .font(.system(size: 12))
                .foregroundStyle(strictness == .autonomous ? t.dangerInk : t.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private var explanation: String {
        switch strictness {
        case .strict:
            return "Past-quarantine candidates wait in pending review if there's no positive deletion signal."
        case .trusting:
            return "Past-quarantine candidates move to Immich's Trash automatically. Held deletions still wait out the quarantine window."
        case .autonomous:
            return "All candidates move to Immich's Trash on sync. No quarantine, no review. Immich keeps items in Trash for 30 days."
        }
    }
}

// MARK: - Quarantine window row

/// Slider for `CairnSettings.quarantineDays`. Thin wrapper over
/// `SliderInputRow` that adapts the `Int` binding to Double and formats
/// `0` as "Off" (the sentinel that collapses the held-by-quarantine
/// bucket entirely).
private struct QuarantineRow: View {
    @Binding var days: Int
    @Environment(\.cairnTokens) private var t

    private var doubleBinding: Binding<Double> {
        Binding(
            get: { Double(days) },
            set: { days = Int($0.rounded()) }
        )
    }

    private var summary: String {
        days == 0 ? "Off" : "\(days) day\(days == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Spacer(minLength: 0)
                HelpPopover {
                    Text("A photo you delete on iPhone won't move to Immich's Trash until this many days have passed — a grace window for accidental mass-offloads (iCloud sync hiccup, \"Remove from this iPhone\") to be caught.")
                    Text("Held photos show up in Pending Review with a countdown. Approve them early if you're sure, or exclude them if you want to keep the server copy.")
                    Text("Set to 0 to move to Trash as soon as a deletion is detected — no safety net.")
                }
                .padding(.trailing, 6)
            }
            .padding(.top, 10)
            .padding(.bottom, -4)

            SliderInputRow(
                label: "Quarantine window",
                sub: "Confirmed deletions wait this long before they're eligible to trash. Catches accidental mass-offloads.",
                value: doubleBinding,
                range: Double(CairnSettings.quarantineDaysRange.lowerBound)...Double(CairnSettings.quarantineDaysRange.upperBound),
                step: 1,
                unitSuffix: days == 1 ? " day" : " days",
                format: { $0 == 0 ? "Off" : String(format: "%.0f", $0) },
                parse: NumericInputParse.integer
            )
        }
    }
}

// MARK: - Count floor row

/// Minimum batch size required before the percent-threshold rail
/// engages. On a small library, 1% can round to 1–2 assets, which is
/// noise — this floor lets the user say "don't even apply the percent
/// check until a run would trash at least N assets."
private struct CountFloorRow: View {
    @Binding var floor: Int
    @Environment(\.cairnTokens) private var t

    private var doubleBinding: Binding<Double> {
        Binding(
            get: { Double(floor) },
            set: { floor = Int($0.rounded()) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Spacer(minLength: 0)
                HelpPopover {
                    Text("**Paired with Percent threshold.** The percent safety rail only engages once a run would move at least this many assets to Immich's Trash. Below the floor, the run proceeds without the percent check.")

                    Text("**Why it matters most on small libraries.**")
                        .fontWeight(.semibold)
                        .padding(.top, 2)
                    Text("On a 150-photo library with a 1% threshold, 1% is ≈ 1 photo. A floor of 1 means a run that moves 2 photos to Trash trips the rail — almost every legitimate deletion aborts. Raising the floor lets small real deletions through.")

                    Text("**Concrete scenarios** (assuming Percent = 1%)")
                        .fontWeight(.semibold)
                        .padding(.top, 2)
                    Text("• **150 photos, Floor = 1:** 2 photos to Trash (1.3%) → ABORT. Annoying.")
                    Text("• **150 photos, Floor = 5:** 4 photos to Trash → runs (floor not met). 10 photos (6.7%) → ABORT.")
                    Text("• **150 photos, Floor = 20:** 15 photos to Trash (10%) → runs. 25 (16.7%) → ABORT.")
                    Text("• **10,000 photos, Floor = 5:** 50 photos to Trash (0.5%) → runs. 150 (1.5%) → ABORT. (Floor is essentially moot here — percent alone guards you.)")

                    Text("**Rule of thumb.** Raise the floor for libraries under ~500 photos. Leave at 5 otherwise.")
                        .padding(.top, 2)
                }
                .padding(.trailing, 6)
            }
            .padding(.top, 10)
            .padding(.bottom, -4)

            SliderInputRow(
                label: "Count floor",
                sub: "Minimum run size before the percent threshold engages. Prevents noisy aborts on small libraries.",
                value: doubleBinding,
                range: 1...50,
                step: 1,
                unitSuffix: floor == 1 ? " asset" : " assets",
                format: { String(format: "%.0f", $0) },
                parse: NumericInputParse.integer
            )
        }
    }
}

// MARK: - Thumbnail cache cap row

private struct ThumbnailCacheCapRow: View {
    @Binding var mb: Int

    private var doubleBinding: Binding<Double> {
        Binding(
            get: { Double(mb) },
            set: { mb = Int($0.rounded()) }
        )
    }

    var body: some View {
        SliderInputRow(
            label: "Thumbnail cache cap",
            sub: "Max disk space for cached server thumbnails. Oldest entries evict first.",
            value: doubleBinding,
            range: Double(CairnSettings.thumbnailCacheCapMBRange.lowerBound)...Double(CairnSettings.thumbnailCacheCapMBRange.upperBound),
            step: 10,
            unitSuffix: " MB",
            format: { String(format: "%.0f", $0) },
            parse: NumericInputParse.integer
        )
    }
}

// MARK: - Thumbhash cache cap row

private struct ThumbhashCacheCapRow: View {
    @Binding var mb: Int

    private var doubleBinding: Binding<Double> {
        Binding(
            get: { Double(mb) },
            set: { mb = Int($0.rounded()) }
        )
    }

    var body: some View {
        SliderInputRow(
            label: "Thumbhash cache cap",
            sub: "Max disk space for thumbhash placeholders. Typically negligible.",
            value: doubleBinding,
            range: Double(CairnSettings.thumbhashCapMBRange.lowerBound)...Double(CairnSettings.thumbhashCapMBRange.upperBound),
            step: 1,
            unitSuffix: " MB",
            format: { String(format: "%.0f", $0) },
            parse: NumericInputParse.integer
        )
    }
}

// MARK: - iCloud download limit row

/// Per-asset cap on iCloud-only bytes the **foreground** scan will
/// download. Over-limit assets queue in `DeferredHashStore` and drain
/// in two paths: a small budget during each subsequent foreground scan,
/// or the whole queue during a `BGProcessingTask` slot (power + Wi-Fi,
/// unbounded). Wraps `SliderInputRow` with an `Int ↔ Double` adapter
/// since the slider primitive is Double-typed.
private struct ICloudDownloadLimitRow: View {
    @Binding var mb: Int
    @Environment(\.cairnTokens) private var t

    private var doubleBinding: Binding<Double> {
        Binding(
            get: { Double(mb) },
            set: { mb = Int($0.rounded()) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Spacer(minLength: 0)
                HelpPopover {
                    Text("**Foreground soft limit.** Assets larger than this skip the foreground pipeline and wait in the deferred-hashing queue for a later drain. Foreground sync also gives up on any single asset after 60 seconds (prefers to defer than stall).")

                    Text("**Where does the work go?**")
                        .fontWeight(.semibold)
                        .padding(.top, 2)
                    Text("• iOS background slot (plugged in + Wi-Fi + idle) → the queue drains with no soft limit and no timeout, so multi-GB videos can finish.")
                    Text("• Or tap **Hash now** below to drain immediately in foreground with the same unlimited-fetch semantics.")

                    Text("**Tuning**")
                        .fontWeight(.semibold)
                        .padding(.top, 2)
                    Text("• Lower → faster first sync, more items queued.")
                    Text("• Higher → more items hash upfront, slower syncs on slow networks.")
                    Text("• Use the **Never-touch ceiling** below for assets you never want cairn to try fetching at all.")
                }
                .padding(.trailing, 6)
            }
            .padding(.top, 10)
            .padding(.bottom, -4)

            SliderInputRow(
                label: "iCloud download limit",
                sub: "Foreground cap on per-asset iCloud downloads. Larger assets queue for background hashing instead of blocking the sync.",
                value: doubleBinding,
                range: Double(CairnSettings.iCloudDownloadLimitMBRange.lowerBound)...Double(CairnSettings.iCloudDownloadLimitMBRange.upperBound),
                step: 5,
                unitSuffix: " MB",
                format: { String(format: "%.0f", $0) },
                parse: NumericInputParse.integer
            )
        }
    }
}

// MARK: - Hard ceiling row

/// Hard never-touch ceiling. Assets whose iCloud download would exceed
/// this are **never hashed**, by any path — not foreground, not
/// background. Off by default (nil); the toggle enables the value field
/// below it.
///
/// Tradeoff surfaced in the help popover: excluded assets never enter
/// `everSeen`, so deletion propagation stops at them. That's the
/// intended semantic ("out of scope by user choice") but important to
/// make explicit — there's no other place this invariant shows up.
private struct HardCeilingRow: View {
    @Binding var mb: Int?
    @Environment(\.cairnTokens) private var t

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { mb != nil },
            set: { newValue in
                if newValue {
                    // Default to 1 GB when enabling — cleanly above
                    // the soft-limit default of 100 MB so the two
                    // thresholds don't collapse into each other.
                    mb = mb ?? 1024
                } else {
                    mb = nil
                }
            }
        )
    }

    private var doubleBinding: Binding<Double> {
        Binding(
            get: { Double(mb ?? CairnSettings.iCloudMaxEverBytesMBRange.lowerBound) },
            set: { mb = Int($0.rounded()) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Never-touch ceiling")
                    .font(.system(size: 15))
                    .foregroundStyle(t.textBody)
                HelpPopover {
                    Text("**Hard skip threshold.** Assets with an iCloud download above this are ignored entirely — never hashed, even in background slots.")
                    Text("Use for multi-GB archived videos you don't want to index. They stay on your server and your iPhone untouched.")
                    Text("Trade-off: ignored assets aren't tracked, so if you later delete them from iPhone, the server copy won't be trashed. That's usually the whole point — but worth knowing.")
                }
                Spacer(minLength: 0)
                Toggle("", isOn: isEnabled)
                    .labelsHidden()
                    .tint(t.text)
            }
            if mb != nil {
                Text("Assets whose iCloud fetch would exceed this are out-of-scope — never indexed, never proposed for deletion.")
                    .font(.system(size: 12))
                    .foregroundStyle(t.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Slider(
                    value: doubleBinding,
                    in: Double(CairnSettings.iCloudMaxEverBytesMBRange.lowerBound)...Double(CairnSettings.iCloudMaxEverBytesMBRange.upperBound),
                    step: 50
                )
                .tint(t.text)
                HStack {
                    Spacer()
                    EditableNumericField(
                        value: doubleBinding,
                        range: Double(CairnSettings.iCloudMaxEverBytesMBRange.lowerBound)...Double(CairnSettings.iCloudMaxEverBytesMBRange.upperBound),
                        step: 50,
                        unitSuffix: " MB",
                        format: { String(format: "%.0f", $0) },
                        parse: NumericInputParse.integer
                    )
                }
            } else {
                Text("Off. Every asset is eligible to hash, however large.")
                    .font(.system(size: 12))
                    .foregroundStyle(t.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

}

// MARK: - Backlog alert row

/// Threshold for the Status backlog-alert banner. Slider step is 5
/// so the user can sweep across 0→500 quickly; the `"Off"` label at
/// 0 makes the opt-out affordance explicit.
private struct BacklogAlertRow: View {
    @Binding var threshold: Int
    @Environment(\.cairnTokens) private var t

    private var doubleBinding: Binding<Double> {
        Binding(
            get: { Double(threshold) },
            set: { threshold = Int($0.rounded()) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Spacer(minLength: 0)
                HelpPopover {
                    Text("Status shows a bell-icon banner when the total pending deletions (eligible-to-trash + pending-review + quarantined) reach this count.")
                    Text("The pending-candidates card already shows the running count; this threshold just escalates to a louder alert for users who open cairn infrequently and might miss a growing backlog.")
                    Text("Set to 0 to disable entirely — the existing card is still visible, just no loud alert.")
                }
                .padding(.trailing, 6)
            }
            .padding(.top, 10)
            .padding(.bottom, -4)

            SliderInputRow(
                label: "Backlog alert",
                sub: "Show a Status banner when pending deletions reach this many items.",
                value: doubleBinding,
                range: Double(CairnSettings.deletionBacklogAlertThresholdRange.lowerBound)...Double(CairnSettings.deletionBacklogAlertThresholdRange.upperBound),
                step: 5,
                unitSuffix: threshold == 1 ? " item" : " items",
                format: { $0 == 0 ? "Off" : String(format: "%.0f", $0) },
                parse: NumericInputParse.integer
            )
        }
    }
}

// MARK: - Appearance override row

/// Three-way segmented picker for the system / light / dark color
/// scheme. Writes through to `CairnSettings.appearance`; the
/// app root translates that to `.preferredColorScheme`. Default is
/// "Auto" (follow iOS Settings).
private struct AppearanceRow: View {
    @Binding var appearance: AppearanceOverride
    @Environment(\.cairnTokens) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Color scheme")
                .font(.system(size: 15))
                .foregroundStyle(t.textBody)
            CairnSegmentedPicker(
                selection: $appearance,
                options: [
                    .init(value: AppearanceOverride.system, label: "Auto"),
                    .init(value: AppearanceOverride.light,  label: "Light"),
                    .init(value: AppearanceOverride.dark,   label: "Dark"),
                ]
            )
            Text(explanation)
                .font(.system(size: 12))
                .foregroundStyle(t.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private var explanation: String {
        switch appearance {
        case .system: return "Follows iOS Settings → Display & Brightness."
        case .light:  return "Always light, regardless of the system setting."
        case .dark:   return "Always dark, regardless of the system setting."
        }
    }
}

// MARK: - Deferred queue row

/// Row showing the current count of queued-for-later assets plus a
/// "Hash now" button that triggers a foreground drain. Empty state:
/// collapses to a muted "Everything indexed" line so the row doesn't
/// imply there's something wrong when the queue is clean.
private struct DeferredQueueRow: View {
    let summary: CairnAppModel.DeferredQueueSummary
    let isSyncing: Bool
    let syncProgress: (hashed: Int, total: Int)?
    let onHashNow: () -> Void
    @Environment(\.cairnTokens) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Deferred hashing")
                    .font(.system(size: 15))
                    .foregroundStyle(t.textBody)
                HelpPopover {
                    Text("Assets skipped by the foreground iCloud-download limit wait here until they can be hashed without blocking you.")

                    Text("**When does the queue drain?**")
                        .fontWeight(.semibold)
                        .padding(.top, 2)
                    Text("• **Background slot** — iOS grants time when the device is plugged in, on Wi-Fi, and idle (often overnight). No timeout in this mode; a 10 GB video can fetch over 15 minutes without getting clipped. iOS controls when it fires — you can't force it.")
                    Text("• **Hash now** — runs the same unlimited-fetch path in foreground, so you can force progress without waiting for iOS. PhotoKit has no partial-download resume, so keep the app open until it finishes (or tap Cancel to pause).")

                    Text("**Common flows**")
                        .fontWeight(.semibold)
                        .padding(.top, 2)
                    Text("• Plug in, connect to Wi-Fi, leave overnight → queue drains via the BG slot.")
                    Text("• \"I want it done now\" → open Settings, tap Hash now, keep the app open.")
                    Text("• \"I have a few 20 GB archive videos I never want indexed\" → turn on **Never-touch ceiling** above at a size that excludes them.")

                    Text("The hard ceiling applies to both paths above. Soft-limit changes apply on the next drain attempt (or tap **Rescan library** to re-evaluate immediately).")
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            if summary.count > 0 {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(summary.count) \(summary.count == 1 ? "asset" : "assets") queued")
                            .font(.system(size: 14).monospacedDigit())
                            .foregroundStyle(t.textBody)
                        if summary.totalKnownBytes > 0 {
                            Text("\(formatBytes(summary.totalKnownBytes)) to fetch")
                                .font(.system(size: 12))
                                .foregroundStyle(t.textMuted)
                        }
                    }
                    Spacer()
                    hashNowButton
                }
            } else {
                Text("Everything indexed. No assets queued for background hashing.")
                    .font(.system(size: 12))
                    .foregroundStyle(t.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    /// The "Hash now" CTA, adapted so a tap produces visible local
    /// feedback: while the drain runs, the button swaps to a spinner +
    /// "Hashing…" (or "Hashing N / M" when progress is known) and is
    /// disabled to prevent re-invocation. Settings has no other
    /// progress surface, so without this the user sees nothing change
    /// on-screen and assumes the tap missed.
    @ViewBuilder
    private var hashNowButton: some View {
        Button(action: onHashNow) {
            HStack(spacing: 6) {
                if isSyncing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(t.primaryInk)
                    Text(syncLabel)
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                } else {
                    Text("Hash now")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .foregroundStyle(t.primaryInk)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isSyncing ? t.primary.opacity(0.6) : t.primary)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(CairnPressStyle())
        .disabled(isSyncing)
    }

    private var syncLabel: String {
        if let progress = syncProgress, progress.total > 0 {
            return "Hashing \(progress.hashed) / \(progress.total)"
        }
        return "Hashing…"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        CairnTimeHelpers.formatBytes(bytes)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                .animation(reduceMotion ? .none : .easeInOut(duration: 0.16), value: revealed)
            if revealed {
                HStack(spacing: 5) {
                    Text("\u{26A0}").font(.system(size: 10))
                    Text("Hiding automatically in a few seconds. Keep it secret. Keep it safe.")
                        .font(.system(size: 11))
                }
                .foregroundStyle(t.dangerInk)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .onDisappear {
            // Force-hide on navigation away. Just cancelling the timer
            // (the previous behavior) left `revealed = true` stuck —
            // when the user came back, the key was still on display
            // with no auto-hide timer running. Navigation is a stronger
            // signal than the 8s timer; treat it as immediate hide.
            revealTask?.cancel()
            copyTask?.cancel()
            revealed = false
            copied = false
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
            onResetIndex: {},
            onClearJournal: {},
            onSignOut: {},
            onRescanLibrary: {}
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
                            mono: true
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
