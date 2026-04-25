import SwiftUI
import CairnCore

/// First-launch onboarding wizard. Mirrors the prototype's
/// `screens/setup.jsx` and adds a strictness step that the prototype
/// pre-dates.
///
/// Why a wizard rather than a single scrolling form: each step asks the
/// user for a *decision* (server identity, OS permissions, safety
/// posture) and we want them to land on each one with full attention.
/// The prototype's pattern — top progress dots, big primary CTA,
/// optional Back — is reproduced here so onboarding feels of-a-piece
/// with the rest of the app.
///
/// Step order:
///   1. Welcome — wordmark + one-sentence pitch (host-owned closure
///      gates the only real action: "Continue").
///   2. Server — URL + API key text fields, with a Verify button that
///      hits a host-supplied closure (real iOS impl should call
///      `ImmichClient.listAllAssets()` and surface its `.count`; the
///      mock returns `1,204` per the prototype).
///   3. Photos permission — explainer + "Grant Full access" button.
///      The closure-based seam keeps `PHPhotoLibrary` out of this view
///      so the package builds on macOS.
///   4. Background refresh — explainer + "Allow" button. Skippable.
///   5. Safety thresholds — sliders for percent + count floor, seeded
///      from `CairnSettings.defaults`.
///   6. Strictness — segmented `.strict` vs `.trusting`, copy seeded
///      from the plan doc's "Confirmed-deletion signal (Wave 4) →
///      User-facing messaging" section. This step exists *because* the
///      strictness model is load-bearing for safety; it deserves a
///      dedicated wizard step rather than being buried in Settings.
///   7. First dry-run — "Every scheduled run is preview-only…" copy
///      from HANDOFF.md, plus the CTA that hands off to the host.
///
/// Microcopy is verbatim from `screens/setup.jsx`, HANDOFF.md, and the
/// plan doc — do not paraphrase without designer review. Source files
/// are cited inline at each copy site.
public struct SetupScreen: View {

    // MARK: - Step model

    /// The seven onboarding steps. Order matches `body`'s switch and
    /// the progress-dots row at the top of the screen.
    public enum Step: Int, CaseIterable, Sendable {
        case welcome
        case server
        case photos
        case background
        case thresholds
        case strictness
        case firstRun

        var label: String {
            switch self {
            case .welcome:    return "Welcome"
            case .server:     return "Server"
            case .photos:     return "Photos"
            case .background: return "Background"
            case .thresholds: return "Safety"
            case .strictness: return "Strictness"
            case .firstRun:   return "First run"
            }
        }
    }

    /// Result of a server-verify probe. Host computes this off the wire
    /// (real impl: `ImmichClient.listAllAssets().count`); the screen
    /// only renders it.
    public struct ServerVerifyResult: Sendable {
        public let success: Bool
        public let assetCount: Int?
        public let errorMessage: String?

        public init(success: Bool, assetCount: Int?, errorMessage: String?) {
            self.success = success
            self.assetCount = assetCount
            self.errorMessage = errorMessage
        }
    }

    // MARK: - Inputs

    @Binding public var serverUrl: String
    @Binding public var apiKey: String
    @Binding public var settings: CairnSettings

    public let onVerifyServer: @Sendable (String, String) async -> ServerVerifyResult
    public let onRequestPhotosAccess: @Sendable () async -> Bool
    public let onRequestBackgroundRefresh: @Sendable () async -> Bool
    public let onComplete: () -> Void

    /// The step the wizard should open on. Defaults to `.welcome`;
    /// previews override it to render mid-flow steps.
    public let initialStep: Step

    public init(
        serverUrl: Binding<String>,
        apiKey: Binding<String>,
        settings: Binding<CairnSettings>,
        onVerifyServer: @escaping @Sendable (String, String) async -> ServerVerifyResult,
        onRequestPhotosAccess: @escaping @Sendable () async -> Bool,
        onRequestBackgroundRefresh: @escaping @Sendable () async -> Bool,
        onComplete: @escaping () -> Void,
        initialStep: Step = .welcome
    ) {
        self._serverUrl = serverUrl
        self._apiKey = apiKey
        self._settings = settings
        self.onVerifyServer = onVerifyServer
        self.onRequestPhotosAccess = onRequestPhotosAccess
        self.onRequestBackgroundRefresh = onRequestBackgroundRefresh
        self.onComplete = onComplete
        self.initialStep = initialStep
    }

    // MARK: - Internal state

    @Environment(\.cairnTokens) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step = .welcome

    // Server step
    @State private var verifying: Bool = false
    @State private var verifyResult: ServerVerifyResult? = nil
    @FocusState private var serverUrlFocused: Bool
    /// Guard so we only clear the pre-filled default URL on the *first*
    /// focus — subsequent focus/unfocus cycles (e.g. dismissing the
    /// keyboard and tapping back) leave the user's typed input alone.
    @State private var serverUrlWasCleared: Bool = false

    // Photos / background steps — record outcome so the user can see
    // they completed (or skipped) the step before continuing.
    @State private var photosGranted: Bool = false
    @State private var photosRequesting: Bool = false
    @State private var backgroundGranted: Bool = false
    @State private var backgroundRequesting: Bool = false

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            brandHeader
            stepper
            ScrollView {
                stepContent
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
            }
            // Keyboard dismissal: drag the scroll interactively,
            // or tap empty chrome outside the focused field.
            .scrollDismissesKeyboard(.interactively)
            .cairnDismissKeyboardOnBackgroundTap()
            footerNav
        }
        .background(t.bg)
        .onAppear { step = initialStep }
    }

    // MARK: - Brand + stepper

    private var brandHeader: some View {
        HStack(spacing: 0) {
            CairnWordmark(size: 22, variant: .adaptive)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 60)
        .padding(.bottom, 18)
    }

    private var stepper: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? t.text.opacity(0.85) : t.divider)
                    .frame(height: 3)
                    .frame(maxWidth: .infinity)
                    .animation(reduceMotion ? .none : .easeInOut(duration: 0.2), value: step)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 22)
    }

    // MARK: - Step routing

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:    welcomeStep
        case .server:     serverStep
        case .photos:     photosStep
        case .background: backgroundStep
        case .thresholds: thresholdsStep
        case .strictness: strictnessStep
        case .firstRun:   firstRunStep
        }
    }

    // MARK: - Step: Welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Lockup: onboarding welcome is the single most gaze-dwelled
            // surface in the app, so it uses the detailed multi-color
            // hero art rather than the smaller theme-responsive mark
            // used in nav chrome.
            CairnWordmark(size: 40, variant: .hero)
            .padding(.bottom, 24)

            // Pitch — verbatim from the brief; this is the elevator
            // sentence used elsewhere in product surfaces too.
            (Text.cairnWord + Text(" cleans up your Immich server when you delete photos on your iPhone."))
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(t.text)
                .lineSpacing(2)
                .padding(.bottom, 14)

            // Privacy reassurance — verbatim from `screens/setup.jsx`
            // step 0 and HANDOFF.md "Keep these copies verbatim".
            Text("Photos never leave your iPhone or your Immich server.")
                .font(.system(size: 14))
                .foregroundStyle(t.textMuted)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Step: Server

    private var serverStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Headline + intro — verbatim from `screens/setup.jsx` step 0.
            stepHeadline(Text("Point ") + .cairnWord + Text(" at your Immich server."))
            stepBlurb(Text("Photos never leave your iPhone or your Immich server. ") + .cairnWord + Text(" only sends trash requests, signed with your API key."))

            fieldLabel("Server URL")
            CairnCard {
                HStack(spacing: 0) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 14))
                        .foregroundStyle(t.textMuted)
                        .padding(.leading, 14)
                    TextField("https://immich.home.arpa", text: $serverUrl)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(t.textBody)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                        .autocorrectionDisabled(true)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .focused($serverUrlFocused)
                        .onChange(of: serverUrlFocused) { _, nowFocused in
                            // First-focus clear: the field ships pre-filled
                            // with a scaffold URL so unused surfaces (the
                            // Status subhead) have something to render.
                            // When the user actually taps in, wipe so they
                            // don't have to select-all-and-delete before
                            // typing their real URL. Guarded so they can
                            // unfocus and refocus without losing their own
                            // in-progress input.
                            if nowFocused && !serverUrlWasCleared {
                                serverUrlWasCleared = true
                                serverUrl = ""
                            }
                        }
                        .onChange(of: serverUrl) { _, _ in verifyResult = nil }
                }
            }
            .padding(.horizontal, -20) // CairnCard adds its own 16 inset; counter our 20.
            .padding(.bottom, 16)

            fieldLabel("API key")
            CairnCard {
                ApiKeyInput(
                    text: $apiKey,
                    placeholder: "paste key from Immich account settings",
                    onChange: { verifyResult = nil }
                )
            }
            .padding(.horizontal, -20)
            .padding(.bottom, 10)

            // Scopes hint — verbatim copy + monospace token list from
            // `screens/setup.jsx` step 0.
            (Text("Scopes required: ")
                + monoCode("asset.read") + Text(", ")
                + monoCode("asset.view") + Text(", ")
                + monoCode("asset.download") + Text(", ")
                + monoCode("asset.delete") + Text(", ")
                + monoCode("tag.create") + Text(", ")
                + monoCode("tag.asset") + Text(", ")
                + monoCode("tag.read") + Text("."))
                .font(.system(size: 12))
                .foregroundStyle(t.textMuted)
                .lineSpacing(3)
                .padding(.bottom, 18)
                .fixedSize(horizontal: false, vertical: true)

            verifyArea
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func monoCode(_ s: String) -> Text {
        Text(s).font(.system(size: 11.5, design: .monospaced))
    }

    @ViewBuilder
    private var verifyArea: some View {
        if let result = verifyResult, result.success {
            // Success callout — phrasing mirrors `screens/setup.jsx`
            // ("1,204 assets visible to this key").
            Callout(.verified, icon: "checkmark.circle") {
                let count = result.assetCount.map { $0.formatted(.number) } ?? "0"
                (Text("Connected. ").fontWeight(.semibold)
                    + Text("\(count) assets visible to this key."))
            }
        } else if let result = verifyResult, !result.success {
            Callout(.danger, icon: "exclamationmark.triangle") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Couldn't connect.").fontWeight(.semibold)
                    Text(result.errorMessage ?? "Check the URL and API key, then try again.")
                        .opacity(0.88)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            primaryButton(
                title: verifying ? "Verifying…" : "Verify connection",
                tone: .secondary,
                disabled: verifying || serverUrl.isEmpty || apiKey.isEmpty,
                action: runVerify
            )
        }
    }

    private func runVerify() {
        verifying = true
        let url = serverUrl
        let key = apiKey
        Task {
            let result = await onVerifyServer(url, key)
            await MainActor.run {
                self.verifyResult = result
                self.verifying = false
            }
        }
    }

    // MARK: - Step: Photos

    private var photosStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Headline + body — verbatim from `screens/setup.jsx` step 1.
            stepHeadline("Grant full Photos access.")
            stepBlurb(Text.cairnWord + Text(" needs to enumerate your whole library to know what's no longer there. It reads each photo once to compute a SHA1 fingerprint — the same identifier Immich uses. Bytes are hashed in memory and discarded; only the fingerprints leave your iPhone, and only to your own Immich server."))

            CairnCard {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 18))
                        .foregroundStyle(t.textBody)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Full library access")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(t.textBody)
                        // Verbatim from `screens/setup.jsx` step 1.
                        (Text("Limited access won't work: ") + .cairnWord + Text(" must distinguish photos you deleted from photos it hasn't indexed yet."))
                            .font(.system(size: 12.5))
                            .foregroundStyle(t.textMuted)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
            }
            .padding(.horizontal, -20)
            .padding(.bottom, 16)

            if photosGranted {
                Callout(.verified, icon: "checkmark.circle") {
                    Text("Full access granted.").fontWeight(.semibold)
                }
            } else {
                primaryButton(
                    title: photosRequesting ? "Requesting…" : "Allow Full Access",
                    tone: .primary,
                    disabled: photosRequesting,
                    action: requestPhotos
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func requestPhotos() {
        photosRequesting = true
        Task {
            let granted = await onRequestPhotosAccess()
            await MainActor.run {
                self.photosGranted = granted
                self.photosRequesting = false
            }
        }
    }

    // MARK: - Step: Background

    private var backgroundStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepHeadline(Text("Let ") + .cairnWord + Text(" check in periodically."))
            // Tone is taken from the plan doc's framing of background
            // refresh as load-bearing-but-skippable safety scaffolding.
            stepBlurb(Text.cairnWord + Text(" uses Background App Refresh to pick up deletions while the app is closed. You can skip this — ") + .cairnWord + Text(" still works in the foreground."))

            CairnCard {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 18))
                        .foregroundStyle(t.textBody)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Background App Refresh")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(t.textBody)
                        (Text("iOS decides exactly when. ") + .cairnWord + Text(" never moves anything to Trash automatically — every scheduled run is preview-only."))
                            .font(.system(size: 12.5))
                            .foregroundStyle(t.textMuted)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
            }
            .padding(.horizontal, -20)
            .padding(.bottom, 16)

            if backgroundGranted {
                Callout(.verified, icon: "checkmark.circle") {
                    Text("Background refresh enabled.").fontWeight(.semibold)
                }
            } else {
                VStack(spacing: 10) {
                    primaryButton(
                        title: backgroundRequesting ? "Requesting…" : "Allow",
                        tone: .primary,
                        disabled: backgroundRequesting,
                        action: requestBackground
                    )
                    quietButton(title: "Skip for now") {
                        advance()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func requestBackground() {
        backgroundRequesting = true
        Task {
            let granted = await onRequestBackgroundRefresh()
            await MainActor.run {
                self.backgroundGranted = granted
                self.backgroundRequesting = false
            }
        }
    }

    // MARK: - Step: Thresholds

    private var thresholdsStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepHeadline("Set safety thresholds.")
            // Verbatim from `screens/setup.jsx` step 2.
            stepBlurb(Text("Defaults are conservative. A run that would move more than the threshold to Immich's Trash stops and asks first. Nothing's permanent — Immich keeps deleted assets for 30 days."))

            CairnCard {
                VStack(spacing: 0) {
                    sliderRow(
                        label: "Percent cap",
                        value: Binding(
                            get: { settings.maxDeletePercent },
                            set: { settings.maxDeletePercent = $0 }
                        ),
                        range: 0.1 ... 10.0,
                        step: 0.1,
                        unitSuffix: "%",
                        format: { String(format: "%.1f", $0) },
                        parse: NumericInputParse.decimal,
                        sub: "of matched assets"
                    )
                    RowDivider()
                    sliderRow(
                        label: "Count floor",
                        value: Binding(
                            get: { Double(settings.minDeleteFloor) },
                            set: { settings.minDeleteFloor = Int($0.rounded()) }
                        ),
                        range: 1 ... 50,
                        step: 1,
                        unitSuffix: "",
                        format: { String(format: "%.0f", $0) },
                        parse: NumericInputParse.integer,
                        sub: "minimum candidates before the cap kicks in"
                    )
                }
                .padding(.vertical, 4)
            }
            .padding(.horizontal, -20)
            .padding(.bottom, 12)

            quietButton(title: "Reset to defaults") {
                settings.maxDeletePercent = CairnSettings.defaults.maxDeletePercent
                settings.minDeleteFloor = CairnSettings.defaults.minDeleteFloor
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Onboarding slider row. Retains the larger display-size number
    /// for emphasis (this is the user's first exposure to these
    /// values) but the number doubles as an editable field via the
    /// reusable `EditableNumericField` — so power users can type the
    /// exact value they want without scrubbing. Falls back to a plain
    /// label when `unitSuffix` / `format` / `parse` aren't supplied
    /// (legacy call sites).
    private func sliderRow(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        unitSuffix: String,
        format: @escaping (Double) -> String,
        parse: @escaping (String) -> Double?,
        sub: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(label.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(t.textMuted)
                Spacer()
                EditableNumericField(
                    value: value,
                    range: range,
                    step: step,
                    unitSuffix: unitSuffix,
                    format: format,
                    parse: parse
                )
            }
            Slider(value: value, in: range, step: step)
                .tint(t.primary)
            Text(sub)
                .font(.system(size: 12))
                .foregroundStyle(t.textMuted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Step: Strictness

    private var strictnessStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepHeadline(Text("Pick how strict ") + .cairnWord + Text(" is."))
            // Post-Wave-4 copy: the original plan-doc seed referenced
            // "Recently Deleted album" as the positive signal, but
            // Wave 4 pivoted to `PHPhotoLibrary.fetchPersistentChanges`
            // (iOS fires `deletedLocalIdentifiers` at soft-delete
            // time). Copy reframed around "iOS confirms a deletion"
            // — same strict/trusting split, accurate mechanism.
            stepBlurb(Text.cairnWord + Text(" watches your Photos library and sees deletions as they happen. When iOS confirms a photo was deleted on this device, ") + .cairnWord + Text(" moves the matching photo to Immich's Trash. If ") + .cairnWord + Text(" ever misses a deletion event — the app didn't run for weeks, for example — it falls back to a more conservative inference."))

            // Radio list inlines each mode's explanation with the
            // option itself — the strict/trusting choice is load-
            // bearing in onboarding, and a separate tooltip card
            // below the picker disrupted the left-to-right-then-down
            // reading flow.
            CairnRadioList(
                selection: Binding(
                    get: { settings.deletionStrictness },
                    set: { settings.deletionStrictness = $0 }
                ),
                options: [
                    .init(
                        value: DeletionStrictness.strict,
                        title: "Strict",
                        subtitle: "Only move a server photo to Immich's Trash when iOS directly confirmed it was deleted on this device. Anything else gets held for your review. Recommended with iCloud Photo Library and iCloud-Optimized Storage."
                    ),
                    .init(
                        value: DeletionStrictness.trusting,
                        title: "Trusting",
                        subtitle: "Move any server photo to Immich's Trash when it's no longer on your device, even if iOS didn't directly confirm the deletion. Faster, but can accidentally send photos to Trash during iCloud sync hiccups or library restores."
                    ),
                ]
            )
            .padding(.bottom, 12)

            Text("You can change this any time in Settings.")
                .font(.system(size: 12))
                .foregroundStyle(t.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Step: First scan

    private var firstRunStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Post-CLI copy rewrite: the original headline said "First
            // run is always a dry-run," but the orchestrator's real
            // `dryRun` flag is never set from iOS — every interactive
            // run calls `TrashOrchestrator.run(dryRun: false)`. The
            // safety comes from the sheet + explicit confirm, not
            // from the orchestrator. Reframe around that mechanism.
            stepHeadline("You'll see the list before anything syncs.")
            stepBlurb(Text.cairnWord + Text(" scans your library, indexes every asset, and shows exactly what would move to Immich's Trash. Nothing happens on the server until you confirm."))

            // The "what happens next" card — preserves the prototype's
            // 4-step preview so the user knows the shape of the work.
            CairnCard {
                VStack(spacing: 0) {
                    HStack {
                        Text("WHAT HAPPENS NEXT")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.9)
                            .foregroundStyle(t.textMuted)
                        Spacer()
                        Text("~40s")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(t.textHint)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 6)

                    ForEach(Array([
                        "Hash on-device photos (lazy, cached)",
                        "Pull server asset checksums",
                        "Compute diff",
                        "Show preview → you confirm",
                    ].enumerated()), id: \.offset) { idx, line in
                        HStack(alignment: .top, spacing: 10) {
                            ZStack {
                                Circle().fill(t.surfaceAlt).frame(width: 20, height: 20)
                                Text("\(idx + 1)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(t.textBody)
                            }
                            Text(line)
                                .font(.system(size: 13))
                                .foregroundStyle(t.textBody)
                                .padding(.top, 2)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        if idx < 3 {
                            RowDivider()
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .padding(.horizontal, -20)
            .padding(.bottom, 14)

            Callout(.info, icon: "eye") {
                Text("Every scheduled run is preview-only. You confirm before anything moves to Trash.")
            }
            .padding(.bottom, 16)

            primaryButton(
                title: "Finish setup",
                tone: .primary,
                disabled: false,
                action: onComplete
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer nav

    private var footerNav: some View {
        HStack(spacing: 10) {
            if step != .welcome {
                quietButton(title: "Back") { goBack() }
                    .frame(maxWidth: .infinity)
            }
            if step != .firstRun {
                primaryButton(
                    title: "Continue",
                    tone: .primary,
                    disabled: !canAdvance,
                    action: advance
                )
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 24)
        .background(
            Rectangle()
                .fill(t.divider)
                .frame(height: 0.5),
            alignment: .top
        )
    }

    /// Per-step gating for the "Continue" button. Steps with intra-step
    /// state (server fields not yet verified) gate Continue here; steps
    /// that own their own confirmation (Photos, Background) pass-through
    /// so the user can still advance after granting or skipping.
    private var canAdvance: Bool {
        switch step {
        case .welcome:    return true
        case .server:     return verifyResult?.success == true
        case .photos:     return photosGranted
        case .background: return true   // optional; quiet "Skip for now" also advances
        case .thresholds: return true
        case .strictness: return true
        case .firstRun:   return true   // not shown — firstRun has its own CTA
        }
    }

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else {
            onComplete()
            return
        }
        withAnimation(reduceMotion ? .none : .easeInOut(duration: 0.18)) { step = next }
    }

    private func goBack() {
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        withAnimation(reduceMotion ? .none : .easeInOut(duration: 0.18)) { step = prev }
    }

    // MARK: - Shared step chrome

    private func stepHeadline(_ text: String) -> some View { stepHeadline(Text(text)) }
    private func stepBlurb(_ text: String) -> some View { stepBlurb(Text(text)) }

    private func stepHeadline(_ text: Text) -> some View {
        text
            .font(.system(size: 26, weight: .semibold))
            .tracking(-0.5)
            .foregroundStyle(t.text)
            .lineSpacing(2)
            .padding(.bottom, 8)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func stepBlurb(_ text: Text) -> some View {
        text
            .font(.system(size: 14))
            .foregroundStyle(t.textMuted)
            .lineSpacing(3)
            .padding(.bottom, 22)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(t.textMuted)
            .padding(.bottom, 6)
    }

    // MARK: - Buttons

    private enum ButtonTone { case primary, secondary }

    private func primaryButton(
        title: String,
        tone: ButtonTone,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: { if !disabled { action() } }) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(foreground(for: tone, disabled: disabled))
                .background(background(for: tone, disabled: disabled))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func quietButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(t.textBody)
                .background(t.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func foreground(for tone: ButtonTone, disabled: Bool) -> Color {
        if disabled { return t.textMuted }
        switch tone {
        case .primary:   return t.primaryInk
        case .secondary: return t.textBody
        }
    }

    private func background(for tone: ButtonTone, disabled: Bool) -> Color {
        if disabled { return t.surfaceAlt }
        switch tone {
        case .primary:   return t.primary
        case .secondary: return t.surfaceAlt
        }
    }
}

// MARK: - Preview

#if DEBUG
/// Wrapper view that owns `@State` so previews can wire bindings into
/// `SetupScreen`. Without this, previews can't supply `Binding`s.
private struct SetupPreviewHarness: View {
    let initialStep: SetupScreen.Step
    let preVerified: Bool
    @State private var serverUrl: String = "https://immich.home.arpa"
    @State private var apiKey: String = "demo-api-key-placeholder"
    @State private var settings: CairnSettings = .defaults

    var body: some View {
        SetupScreen(
            serverUrl: $serverUrl,
            apiKey: $apiKey,
            settings: $settings,
            onVerifyServer: { _, _ in
                .init(success: true, assetCount: 1_204, errorMessage: nil)
            },
            onRequestPhotosAccess: { true },
            onRequestBackgroundRefresh: { true },
            onComplete: { },
            initialStep: initialStep
        )
        .cairnTheme()
    }
}

#Preview("Setup — welcome") {
    SetupPreviewHarness(initialStep: .welcome, preVerified: false)
}

#Preview("Setup — server") {
    SetupPreviewHarness(initialStep: .server, preVerified: false)
}

#Preview("Setup — photos") {
    SetupPreviewHarness(initialStep: .photos, preVerified: true)
}

#Preview("Setup — thresholds") {
    SetupPreviewHarness(initialStep: .thresholds, preVerified: true)
}

#Preview("Setup — strictness") {
    SetupPreviewHarness(initialStep: .strictness, preVerified: true)
}

#Preview("Setup — first dry-run") {
    SetupPreviewHarness(initialStep: .firstRun, preVerified: true)
}

#Preview("Setup — strictness (dark)") {
    SetupPreviewHarness(initialStep: .strictness, preVerified: true)
        .preferredColorScheme(.dark)
}
#endif
