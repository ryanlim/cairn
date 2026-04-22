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
    public let onRunFirstDryRun: @Sendable () async -> Void
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
        onRunFirstDryRun: @escaping @Sendable () async -> Void,
        onComplete: @escaping () -> Void,
        initialStep: Step = .welcome
    ) {
        self._serverUrl = serverUrl
        self._apiKey = apiKey
        self._settings = settings
        self.onVerifyServer = onVerifyServer
        self.onRequestPhotosAccess = onRequestPhotosAccess
        self.onRequestBackgroundRefresh = onRequestBackgroundRefresh
        self.onRunFirstDryRun = onRunFirstDryRun
        self.onComplete = onComplete
        self.initialStep = initialStep
    }

    // MARK: - Internal state

    @Environment(\.cairnTokens) private var t
    @State private var step: Step = .welcome

    // Server step
    @State private var verifying: Bool = false
    @State private var verifyResult: ServerVerifyResult? = nil

    // Photos / background steps — record outcome so the user can see
    // they completed (or skipped) the step before continuing.
    @State private var photosGranted: Bool = false
    @State private var photosRequesting: Bool = false
    @State private var backgroundGranted: Bool = false
    @State private var backgroundRequesting: Bool = false

    // First-run step
    @State private var runningFirstSync: Bool = false

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
            footerNav
        }
        .background(t.bg)
        .onAppear { step = initialStep }
    }

    // MARK: - Brand + stepper

    private var brandHeader: some View {
        HStack(spacing: 10) {
            CairnMark(size: 28, crowned: true)
            Text("cairn")
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(t.text)
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
                    .animation(.easeInOut(duration: 0.2), value: step)
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
            // Lockup: the brief calls for `CairnMark(size: 64, crowned: true)`
            // since there's no separate `CairnLockup` Swift component.
            HStack(spacing: 14) {
                CairnMark(size: 64, crowned: true)
                Text("cairn")
                    .font(.system(size: 40, weight: .semibold))
                    .tracking(-0.8)
                    .foregroundStyle(t.text)
            }
            .padding(.bottom, 24)

            // Pitch — verbatim from the brief; this is the elevator
            // sentence used elsewhere in product surfaces too.
            Text("cairn cleans up your Immich server when you delete photos on your iPhone.")
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
            stepHeadline("Point cairn at your Immich.")
            stepBlurb("Photos never leave your iPhone or your Immich server. cairn only sends trash requests, signed with your API key.")

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
                        .onChange(of: serverUrl) { _, _ in verifyResult = nil }
                }
            }
            .padding(.horizontal, -20) // CairnCard adds its own 16 inset; counter our 20.
            .padding(.bottom, 16)

            fieldLabel("API key")
            CairnCard {
                HStack(spacing: 0) {
                    Image(systemName: "key")
                        .font(.system(size: 14))
                        .foregroundStyle(t.textMuted)
                        .padding(.leading, 14)
                    SecureField("paste key from Immich account settings", text: $apiKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(t.textBody)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                        .autocorrectionDisabled(true)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .onChange(of: apiKey) { _, _ in verifyResult = nil }
                }
            }
            .padding(.horizontal, -20)
            .padding(.bottom, 10)

            // Scopes hint — verbatim copy + monospace token list from
            // `screens/setup.jsx` step 0.
            (Text("Scopes required: ")
                + monoCode("asset.read") + Text(", ")
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
            stepBlurb("cairn needs to enumerate your whole library to know what's no longer there. It only reads content identifiers — never photo contents — and never transmits anything outside your devices.")

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
                        Text("Limited access won't work: cairn must distinguish photos you deleted from photos it hasn't indexed yet.")
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
            stepHeadline("Let cairn check in periodically.")
            // Tone is taken from the plan doc's framing of background
            // refresh as load-bearing-but-skippable safety scaffolding.
            stepBlurb("cairn uses Background App Refresh to scan your Recently Deleted album on a schedule, so it sees deletions even if you haven't opened the app for a while. You can skip this — cairn still works in the foreground.")

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
                        Text("iOS decides exactly when. cairn never auto-trashes — every scheduled run is preview-only.")
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
            stepBlurb("Defaults are conservative. If any single run would trash more than the threshold, cairn stops and asks. Trash is never permanent — Immich keeps deleted assets for 30 days.")

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
                        formatted: String(format: "%.1f%%", settings.maxDeletePercent),
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
                        formatted: "\(settings.minDeleteFloor)",
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

    private func sliderRow(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double.Stride,
        formatted: String,
        sub: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(label.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(t.textMuted)
                Spacer()
                Text(formatted)
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .tracking(-0.4)
                    .foregroundStyle(t.text)
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
            stepHeadline("Pick how strict cairn is.")
            // Onboarding seed copy — verbatim from
            // immich-ios-deletion-sync-plan.md → "Confirmed-deletion
            // signal (Wave 4) → User-facing messaging → Onboarding".
            // Designer-approved per the brief.
            stepBlurb("cairn watches your Photos library and your Recently Deleted album. When you delete a photo, cairn confirms it via Recently Deleted before trashing the matching photo on your Immich server. This is the most reliable signal we have, but it has a 30-day window — if you don't open cairn for a month, it falls back to a more conservative inference. You can pick how strict cairn is in Settings.")

            // Segmented strict/trusting picker.
            Picker("Strictness", selection: Binding(
                get: { settings.deletionStrictness },
                set: { settings.deletionStrictness = $0 }
            )) {
                Text("Strict").tag(DeletionStrictness.strict)
                Text("Trusting").tag(DeletionStrictness.trusting)
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 16)

            // Mode tooltip — switches between the two seed copies from
            // the same plan-doc section ("Strict mode setting tooltip"
            // / "Trusting mode setting tooltip").
            CairnCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text(settings.deletionStrictness == .strict ? "Strict mode" : "Trusting mode")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(t.text)
                    Text(settings.deletionStrictness == .strict
                         ? "cairn only trashes server photos that we positively saw in your Recently Deleted album. Anything else gets held for your review. Use this if you want maximum safety, especially with iCloud Photo Library or iCloud-Optimized Storage."
                         : "cairn trashes any server photo that's no longer on your device, even if we didn't see it in Recently Deleted. Faster, but vulnerable to iCloud sync hiccups and library restores.")
                        .font(.system(size: 13))
                        .foregroundStyle(t.textBody)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, -20)
            .padding(.bottom, 12)

            // Subtle "you can change this later" — explicitly in the
            // plan-doc seed copy ("You can pick how strict cairn is in
            // Settings"). Restating it here under the picker reduces
            // commitment anxiety.
            Text("You can change this any time in Settings.")
                .font(.system(size: 12))
                .foregroundStyle(t.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Step: First dry-run

    private var firstRunStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Headline — verbatim from `screens/setup.jsx` step 3.
            stepHeadline("First run is always a dry-run.")
            stepBlurb("cairn will scan your library, index every asset, and show exactly what it would move to Immich trash. Nothing happens on the server until you confirm a second time.")

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

            // Verbatim from HANDOFF.md "Keep these copies verbatim".
            Callout(.info, icon: "eye") {
                Text("Every scheduled run is preview-only. You confirm each trash manually.")
            }
            .padding(.bottom, 16)

            primaryButton(
                title: runningFirstSync ? "Starting…" : "Run first sync (dry-run)",
                tone: .primary,
                disabled: runningFirstSync,
                action: runFirstDryRun
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func runFirstDryRun() {
        runningFirstSync = true
        Task {
            await onRunFirstDryRun()
            await MainActor.run {
                self.runningFirstSync = false
                self.onComplete()
            }
        }
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
        withAnimation(.easeInOut(duration: 0.18)) { step = next }
    }

    private func goBack() {
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        withAnimation(.easeInOut(duration: 0.18)) { step = prev }
    }

    // MARK: - Shared step chrome

    private func stepHeadline(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 26, weight: .semibold))
            .tracking(-0.5)
            .foregroundStyle(t.text)
            .lineSpacing(2)
            .padding(.bottom, 8)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func stepBlurb(_ text: String) -> some View {
        Text(text)
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
            onRunFirstDryRun: { },
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
