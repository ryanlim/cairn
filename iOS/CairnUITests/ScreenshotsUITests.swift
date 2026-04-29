import XCTest

/// Drives the app through its screenshot-worthy states for the
/// `scripts/capture-screenshots.sh` pipeline (or `make screenshots`,
/// which delegates there).
///
/// Each test launches the app with `-CAIRN_SCREENSHOT_MODE 1` so
/// `AppDependencies.bootstrap()` swaps real wiring (Keychain, PhotoKit,
/// SwiftData) for `CairnFixtures` data — screenshots are fully
/// deterministic and require no Immich server, no Photos permission,
/// no indexing pass.
///
/// **Light + Dark pairs.** Each capturable state has two test methods,
/// one light-mode and one dark-mode. Dark mode is activated by the
/// `-CAIRN_SCREENSHOT_DARK 1` launch arg, which sets
/// `CairnSettings.appearance = .dark` during fixture seeding;
/// `CairnAppRoot` reads that value at the root and applies
/// `.preferredColorScheme(.dark)`. Same rendering path as the user's
/// Settings → Color scheme choice.
///
/// Each state gets its own launch. Cheaper than engineering
/// flake-resistant navigation across tabs + sub-routes: launch is
/// ~2s, readiness wait is ~2s, so ten tests (five states × two
/// appearances) finish in ~50s per device.
@MainActor
final class ScreenshotsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Light mode

    func testStatusScreenshotLight() throws {
        capture(.status, name: "01-Status-Light", darkMode: false)
    }

    func testPendingReviewScreenshotLight() throws {
        capture(.pendingReview, name: "02-PendingReview-Light", darkMode: false)
    }

    func testRunsScreenshotLight() throws {
        capture(.runs, name: "03-Runs-Light", darkMode: false)
    }

    func testSettingsScreenshotLight() throws {
        capture(.settings, name: "04-Settings-Light", darkMode: false)
    }

    func testOnboardingScreenshotLight() throws {
        capture(.onboarding, name: "05-Setup-Welcome-Light", darkMode: false)
    }

    func testStatusJournalScreenshotLight() throws {
        capture(.statusJournal, name: "06-StatusJournal-Light", darkMode: false)
    }

    // MARK: - Dark mode

    func testStatusScreenshotDark() throws {
        capture(.status, name: "01-Status-Dark", darkMode: true)
    }

    func testPendingReviewScreenshotDark() throws {
        capture(.pendingReview, name: "02-PendingReview-Dark", darkMode: true)
    }

    func testRunsScreenshotDark() throws {
        capture(.runs, name: "03-Runs-Dark", darkMode: true)
    }

    func testSettingsScreenshotDark() throws {
        capture(.settings, name: "04-Settings-Dark", darkMode: true)
    }

    func testOnboardingScreenshotDark() throws {
        capture(.onboarding, name: "05-Setup-Welcome-Dark", darkMode: true)
    }

    func testStatusJournalScreenshotDark() throws {
        capture(.statusJournal, name: "06-StatusJournal-Dark", darkMode: true)
    }

    // MARK: - Demo walkthrough (light only)
    //
    // Six stages of the trash/restore flow on a 25-photo limited-scope
    // album, captured for the Reddit/marketing demo recording. Each
    // launches the app with `-CAIRN_DEMO_STAGE N` so
    // `seedFromFixtures` poses the model state for that stage; the
    // test then navigates to the right tab and snapshots. Light mode
    // only — these are for embedded demo media, not the App Store
    // gallery, so the dark pair would just double the capture time.

    func testDemo01InitialStatus() throws {
        captureDemo(stage: 0, screen: .status, name: "demo-01-Status-Initial")
    }

    func testDemo02StatusAfterDelete() throws {
        captureDemo(stage: 1, screen: .status, name: "demo-02-Status-AfterDelete")
    }

    func testDemo03PendingReview() throws {
        captureDemo(stage: 2, screen: .pendingReview, name: "demo-03-PendingReview")
    }

    func testDemo04StatusAfterApprove() throws {
        captureDemo(stage: 3, screen: .status, name: "demo-04-Status-AfterApprove")
    }

    func testDemo05RunsAfterApprove() throws {
        captureDemo(stage: 4, screen: .runs, name: "demo-05-Runs-AfterApprove")
    }

    func testDemo06StatusAfterRestore() throws {
        captureDemo(stage: 5, screen: .status, name: "demo-06-Status-AfterRestore")
    }

    // MARK: - State enum + dispatch

    private enum State {
        case status, pendingReview, runs, settings, onboarding, statusJournal
    }

    private func capture(_ state: State, name: String, darkMode: Bool) {
        let app = launchFixtureApp(onboarding: state == .onboarding, darkMode: darkMode)
        switch state {
        case .onboarding:
            _ = app.firstMatch.waitForExistence(timeout: 5)
        case .status:
            waitForMainTabs(app)
        case .pendingReview:
            waitForMainTabs(app)
            // Target by accessibility identifier rather than display
            // copy — the entry-point button has been renamed multiple
            // times ("Pending review: N" → "N in quarantine") and the
            // test was breaking on every rename. The identifier
            // `status.openPendingReview` is set on the quarantine line
            // in StatusScreen and is the contract this test relies on.
            let callout = app.buttons["status.openPendingReview"]
            XCTAssertTrue(callout.waitForExistence(timeout: 3), "Pending-review entry not found on Status")
            callout.tap()
            _ = app.staticTexts["Pending review"].waitForExistence(timeout: 3)
        case .runs:
            waitForMainTabs(app)
            app.buttons["Runs"].tap()
            _ = app.staticTexts.firstMatch.waitForExistence(timeout: 3)
        case .settings:
            waitForMainTabs(app)
            app.buttons["Settings"].tap()
            _ = app.staticTexts["Settings"].waitForExistence(timeout: 3)
        case .statusJournal:
            waitForMainTabs(app)
            // Scroll the Status screen until the journal section
            // header is in view. The card sits at the bottom of a
            // long scroll (wordmark → banners → syncCard → Library →
            // Recent runs → Latest journal), well below the 6.9"
            // viewport, so the default Status snapshot misses it.
            // This shot specifically frames the journal so the new
            // banding/separators/hero work shows up in App Store
            // marketing.
            scrollUntilVisible(app, label: "Latest journal", maxSwipes: 6)
        }
        snapshot(name)
    }

    /// Demo-specific capture. Mirrors `capture(_:name:darkMode:)` but
    /// passes the demo-stage launch arg and only navigates among the
    /// three screens used in the walkthrough (Status, PendingReview,
    /// Runs).
    private func captureDemo(stage: Int, screen: State, name: String) {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments += [
            "-CAIRN_SCREENSHOT_MODE", "1",
            "-CAIRN_DEMO_STAGE", String(stage),
        ]
        app.launch()

        switch screen {
        case .status:
            waitForMainTabs(app)
        case .pendingReview:
            waitForMainTabs(app)
            let callout = app.buttons["status.openPendingReview"]
            XCTAssertTrue(callout.waitForExistence(timeout: 3), "Pending-review entry not found on Status (demo stage \(stage))")
            callout.tap()
            _ = app.staticTexts["Pending review"].waitForExistence(timeout: 3)
        case .runs:
            waitForMainTabs(app)
            app.buttons["Runs"].tap()
            _ = app.staticTexts.firstMatch.waitForExistence(timeout: 3)
        case .settings, .onboarding, .statusJournal:
            // Not used by the demo. Keep the switch exhaustive.
            waitForMainTabs(app)
        }
        snapshot(name)
    }

    // MARK: - Helpers

    /// Launch the app with the screenshot-mode launch args. Pass
    /// `onboarding: true` to land on the Setup wizard instead of the
    /// main tabs. Pass `darkMode: true` to force
    /// `CairnSettings.appearance = .dark` during fixture seeding.
    private func launchFixtureApp(onboarding: Bool, darkMode: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments += ["-CAIRN_SCREENSHOT_MODE", "1"]
        if onboarding {
            app.launchArguments += ["-CAIRN_SCREENSHOT_ONBOARDING", "1"]
        }
        if darkMode {
            app.launchArguments += ["-CAIRN_SCREENSHOT_DARK", "1"]
        }
        app.launch()
        return app
    }

    /// Block until the main tab bar is rendered. The Runs tab button
    /// is the most reliable readiness marker — it exists as soon as
    /// `CairnAppRoot.mainTabs` renders and has a stable accessibility
    /// label regardless of which tab is active.
    private func waitForMainTabs(_ app: XCUIApplication) {
        XCTAssertTrue(
            app.buttons["Runs"].waitForExistence(timeout: 15),
            "Main tab bar failed to render within 15s"
        )
    }

    /// Swipe up the active scroll view until a static text matching
    /// `label` becomes hittable. Used by the journal-focused Status
    /// screenshot to bring the bottom-of-Status journal card into
    /// the viewport. `maxSwipes` is a safety bound — typical Status
    /// content reaches the journal in 2-3 swipes; six is generous.
    private func scrollUntilVisible(
        _ app: XCUIApplication,
        label: String,
        maxSwipes: Int = 6
    ) {
        let target = app.staticTexts[label]
        for _ in 0..<maxSwipes {
            if target.exists && target.isHittable { return }
            app.swipeUp()
        }
        // Best-effort — if the label still isn't hittable we still
        // snapshot whatever frame we ended on. Better than throwing
        // and producing no shot at all.
    }
}
