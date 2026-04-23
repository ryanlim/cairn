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

    // MARK: - State enum + dispatch

    private enum State {
        case status, pendingReview, runs, settings, onboarding
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
            let callout = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Pending review")
            ).firstMatch
            XCTAssertTrue(callout.waitForExistence(timeout: 3), "Pending-review callout not found")
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
}
