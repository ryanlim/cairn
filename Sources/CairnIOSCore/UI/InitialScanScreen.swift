import SwiftUI
import CairnCore

/// First-run indexing screen. Takes over the main window while the
/// initial full-library hash runs — that work populates
/// `LocalHashStore` with every asset's SHA1 and saves a
/// `PHPersistentChangeToken` baseline. Without that baseline, cairn
/// can't detect user deletions, so there's nothing useful to render on
/// the main tabs until the baseline lands.
///
/// Why its own screen (rather than a banner on Status):
///  - On large libraries the initial scan takes minutes to tens of
///    minutes. A banner-sized affordance buried in a scroll view makes
///    that feel incidental; dedicating the whole window makes the
///    magnitude visible and discourages the user from tapping around.
///  - Sets honest expectations about iOS foreground-only work:
///    "backgrounding pauses the scan" is core info that gets lost in a
///    secondary UI.
///  - Gives cancellation + resume a prominent home. Users expect to
///    be able to bail out of a multi-minute operation.
public struct InitialScanScreen: View {
    public let total: Int
    public let hashed: Int
    /// Assets with actual checksums in the store. Differs from `hashed`
    /// when assets are deferred (too large for foreground download) or
    /// skipped (above hard ceiling).
    public let indexed: Int
    /// Actual count of items in the deferred queue (will retry later).
    /// The gap `hashed - indexed - deferredQueueCount` = permanently
    /// skipped (above hard ceiling).
    public let deferredQueueCount: Int
    public let isActive: Bool
    public let startedAt: Date?
    /// When non-nil, the scan is *paused*: elapsed is this frozen value
    /// rather than a live `now - startedAt` computation. See
    /// `CairnAppModel.pausedSyncElapsedSeconds`.
    public let pausedElapsed: TimeInterval?
    @Binding public var settings: CairnSettings
    public let onStart: () -> Void
    public let onCancel: () -> Void
    public let onStartOver: () -> Void
    public let onDismiss: () -> Void

    @Environment(\.cairnTokens) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var optionsExpanded: Bool = false

    public init(
        total: Int,
        hashed: Int,
        indexed: Int = 0,
        deferredQueueCount: Int = 0,
        isActive: Bool,
        startedAt: Date?,
        pausedElapsed: TimeInterval? = nil,
        settings: Binding<CairnSettings> = .constant(.defaults),
        onStart: @escaping () -> Void = {},
        onCancel: @escaping () -> Void = {},
        onStartOver: @escaping () -> Void = {},
        onDismiss: @escaping () -> Void = {}
    ) {
        self.total = total
        self.hashed = hashed
        self.indexed = indexed
        self.deferredQueueCount = deferredQueueCount
        self.isActive = isActive
        self.startedAt = startedAt
        self.pausedElapsed = pausedElapsed
        self._settings = settings
        self.onStart = onStart
        self.onCancel = onCancel
        self.onStartOver = onStartOver
        self.onDismiss = onDismiss
    }

    // MARK: - Derived state

    /// Fraction complete in `0...1`. Clamped against `total == 0`
    /// (which happens briefly before the fetch enumerates).
    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1.0, Double(hashed) / Double(total))
    }

    /// Elapsed = frozen paused value when paused, else live
    /// `now - startedAt`. When both are nil, returns nil (no scan
    /// has run yet this session).
    private var elapsed: TimeInterval? {
        if let pausedElapsed { return pausedElapsed }
        guard let startedAt else { return nil }
        return Date().timeIntervalSince(startedAt)
    }

    /// True when the scan has run and been interrupted — progress is
    /// frozen at the last known values. Drives the paused CTA layout.
    private var isPaused: Bool {
        !isActive && hashed > 0
    }

    /// Linear ETA — assumes remaining assets take the same average time
    /// as the assets already hashed. For iCloud-optimized libraries
    /// this underestimates early on (iCloud downloads vs locally-cached
    /// hash have very different rates) but stabilizes as the sample
    /// grows. Good enough to set expectations.
    private var etaSeconds: TimeInterval? {
        guard let elapsed, hashed > 0, total > hashed else { return nil }
        let perAsset = elapsed / Double(hashed)
        return perAsset * Double(total - hashed)
    }

    // MARK: - Body

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 40)
                heroMark
                headline
                subtext
                progressCard
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                expectationsCallout
                scanOptionsCard
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                controls
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                dismissButton
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
            }
        }
        .background(t.bg)
        // Keyboard dismissal: drag the scroll to interactively
        // pull the numpad away, or tap empty chrome.
        .scrollDismissesKeyboard(.interactively)
        .cairnDismissKeyboardOnBackgroundTap()
    }

    private var heroMark: some View {
        // Rich multi-color rendering — this screen is a gaze-dwell
        // surface and wants the detailed art rather than the small
        // theme-responsive variant used in nav chrome.
        CairnHeroMark(size: 72)
            .padding(.bottom, 20)
    }

    private var headline: some View {
        Text("Indexing your library")
            .font(.system(size: 26, weight: .semibold))
            .tracking(-0.5)
            .foregroundStyle(t.text)
            .padding(.bottom, 8)
    }

    private var hasCache: Bool { hashed > 0 && !isActive }

    private var subtext: some View {
        Group {
            if hasCache {
                (Text.cairnWord + Text(" found \(hashed.formatted(.number)) cached hashes from a previous run. Tap resume to pick up where you left off."))
            } else {
                (Text.cairnWord + Text(" hashes every photo once so it can tell a deletion apart from a sync hiccup. This only happens on first run."))
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(t.textMuted)
        .multilineTextAlignment(.center)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 40)
        .padding(.bottom, 28)
    }

    private var progressCard: some View {
        CairnCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(hashed.formatted(.number)) / \(total.formatted(.number))")
                        .font(.system(size: 28, weight: .semibold).monospacedDigit())
                        .foregroundStyle(t.text)
                    Text("processed")
                        .font(.system(size: 14))
                        .foregroundStyle(t.textMuted)
                    Spacer()
                    Text(String(format: "%.0f%%", fraction * 100))
                        .font(.system(size: 13, design: .monospaced).monospacedDigit())
                        .foregroundStyle(t.textMuted)
                }
                ProgressBar(fraction: fraction, tone: .pending)
                ProcessingBreakdown(indexed: indexed, deferredQueueCount: deferredQueueCount, processed: hashed)
                timingStrip
            }
            .padding(18)
        }
    }

    /// Two-column stats strip under the progress bar.
    @ViewBuilder
    private var timingStrip: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ELAPSED")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(t.textHint)
                Text(elapsed.map(Self.formatDuration) ?? "—")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(t.textBody)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("REMAINING")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(t.textHint)
                Text(etaSeconds.map(Self.formatDuration) ?? "—")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(t.textBody)
            }
            Spacer()
        }
    }

    /// Foreground-only warning. iOS suspends apps within ~5s of being
    /// backgrounded, so a 10-minute hash only progresses while the user
    /// has cairn open. Saying so up-front is less annoying than silently
    /// pausing.
    private var expectationsCallout: some View {
        Callout(.info, icon: "clock.arrow.circlepath") {
            (Text("The scan runs fastest with the app open. iOS pauses the work when you background it; ") + .cairnWord + Text(" resumes where it left off when you return — nothing re-hashes."))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Scan options

    /// Scan-relevant settings surfaced here so the user can tune before
    /// they commit to hashing thousands of photos — especially users
    /// with large iCloud-archived videos who'd otherwise discover the
    /// knob only after waiting for the first pass to defer them.
    /// Collapsed by default so the primary CTA stays the focus.
    private var scanOptionsCard: some View {
        CairnCard {
            VStack(spacing: 0) {
                Button {
                    withAnimation(reduceMotion ? .none : .snappy(duration: 0.16)) {
                        optionsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(t.textMuted)
                        Text("Scan options")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(t.textBody)
                        Spacer(minLength: 12)
                        Image(systemName: optionsExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(t.textHint)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(optionsExpanded ? "Collapse scan options" : "Expand scan options")

                if optionsExpanded {
                    RowDivider()
                    iCloudLimitRow
                    RowDivider()
                    InitialScanHardCeilingRow(mb: $settings.iCloudMaxEverBytesMB)
                }
            }
        }
    }

    /// Compact iCloud-download-limit slider. Uses the shared
    /// `SliderInputRow` primitive with the `.compact` style so the
    /// scan-options card stays dense. Int ↔ Double adapter inline
    /// because the setting is an Int but the primitive is Double-
    /// typed (matches slider semantics).
    private var iCloudLimitRow: some View {
        let binding = Binding<Double>(
            get: { Double(settings.iCloudDownloadLimitMB) },
            set: { settings.iCloudDownloadLimitMB = Int($0.rounded()) }
        )
        return SliderInputRow(
            label: "iCloud download limit",
            sub: "Larger assets queue for background hashing instead of blocking the initial scan.",
            value: binding,
            range: Double(CairnSettings.iCloudDownloadLimitMBRange.lowerBound)...Double(CairnSettings.iCloudDownloadLimitMBRange.upperBound),
            step: 5,
            unitSuffix: " MB",
            format: { String(format: "%.0f", $0) },
            parse: NumericInputParse.integer,
            style: .compact
        )
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        if isActive {
            cancelButton
        } else if isPaused {
            VStack(spacing: 10) {
                startButton
                startOverButton
            }
        } else {
            startButton
        }
    }

    private var startButton: some View {
        Button(action: onStart) {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text(hashed > 0 ? "Resume indexing" : "Start indexing")
                    .font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(t.primaryInk)
            .background(t.primary)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(CairnPressStyle())
    }

    private var cancelButton: some View {
        Button(action: onCancel) {
            Text("Stop indexing")
                .font(.system(size: 14, weight: .semibold))
                .tracking(0.66)
                .foregroundStyle(t.dangerInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(t.divider, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(CairnPressStyle())
        .accessibilityLabel("Stop indexing")
    }

    /// Secondary "Start over" CTA visible only while paused. Distinct
    /// from Resume: wipes the partial hash cache so the next scan
    /// really begins from zero. Uses a quieter outline style so
    /// Resume stays the primary action.
    private var startOverButton: some View {
        Button(action: onStartOver) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .semibold))
                Text("Start over")
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(t.textMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(t.divider, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(CairnPressStyle())
    }

    /// Tertiary "leave this screen" affordance. Always available
    /// regardless of scan state — users shouldn't feel locked to
    /// the progress view. Hashing is driven by a Task that isn't
    /// tied to this view's lifetime, so dismissing to main tabs
    /// leaves the scan running; the sync card's progress bar on
    /// Status picks up the same `syncProgress`, and the "Initial
    /// scan pending" banner routes back here when the user wants
    /// to check in.
    ///
    /// Copy adapts:
    ///   - fresh / pre-start → "Skip for now"
    ///   - active or paused → "Continue in app" (scan keeps going)
    @ViewBuilder
    private var dismissButton: some View {
        let label = (isActive || isPaused) ? "Continue in app" : "Skip for now"
        Button(action: onDismiss) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(t.textHint)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Format helpers

    /// Short duration ("1 min 23 sec", "12 sec", "2 hr 4 min"). We
    /// deliberately skip `DateComponentsFormatter` — its `.short` output
    /// ("1m, 23s") doesn't match the rest of the app's prose style.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return "\(h) hr \(m) min"
        } else if m > 0 {
            return "\(m) min \(s) sec"
        } else {
            return "\(s) sec"
        }
    }
}

// MARK: - Scan-option rows (local to this screen)

/// Compact variant of the hard-ceiling toggle + slider.
private struct InitialScanHardCeilingRow: View {
    @Binding var mb: Int?
    @Environment(\.cairnTokens) private var t

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { mb != nil },
            set: { newValue in mb = newValue ? (mb ?? 1024) : nil }
        )
    }

    private var doubleBinding: Binding<Double> {
        Binding(
            get: { Double(mb ?? CairnSettings.iCloudMaxEverBytesMBRange.lowerBound) },
            set: { mb = Int($0.rounded()) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Never-touch ceiling")
                    .font(.system(size: 14))
                    .foregroundStyle(t.textBody)
                Spacer()
                Toggle("", isOn: isEnabled)
                    .labelsHidden()
                    .tint(t.text)
            }
            if mb != nil {
                Slider(
                    value: doubleBinding,
                    in: Double(CairnSettings.iCloudMaxEverBytesMBRange.lowerBound)...Double(CairnSettings.iCloudMaxEverBytesMBRange.upperBound),
                    step: 50
                )
                .tint(t.text)
                HStack {
                    Text("Assets above this stay out of scope — ideal for multi-GB archived video.")
                        .font(.system(size: 11))
                        .foregroundStyle(t.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
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
                Text("Off. Every asset is eligible, however large.")
                    .font(.system(size: 11))
                    .foregroundStyle(t.textMuted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: - Preview

#if DEBUG
private struct InitialScanPreviewHost: View {
    @State var settings: CairnSettings = .defaults
    let total: Int
    let hashed: Int
    let isActive: Bool
    let startedAt: Date?
    let pausedElapsed: TimeInterval?

    var body: some View {
        InitialScanScreen(
            total: total,
            hashed: hashed,
            isActive: isActive,
            startedAt: startedAt,
            pausedElapsed: pausedElapsed,
            settings: $settings
        )
        .cairnTheme()
    }
}

#Preview("InitialScan — active mid-run") {
    InitialScanPreviewHost(
        total: 4_218, hashed: 1_245, isActive: true,
        startedAt: Date(timeIntervalSinceNow: -180), pausedElapsed: nil
    )
}

#Preview("InitialScan — paused (resumable)") {
    InitialScanPreviewHost(
        total: 4_218, hashed: 1_245, isActive: false,
        startedAt: nil, pausedElapsed: 180
    )
}

#Preview("InitialScan — fresh (nothing hashed)") {
    InitialScanPreviewHost(
        total: 0, hashed: 0, isActive: false,
        startedAt: nil, pausedElapsed: nil
    )
}

#Preview("InitialScan — dark") {
    InitialScanPreviewHost(
        total: 4_218, hashed: 1_245, isActive: true,
        startedAt: Date(timeIntervalSinceNow: -180), pausedElapsed: nil
    )
    .preferredColorScheme(.dark)
}
#endif
