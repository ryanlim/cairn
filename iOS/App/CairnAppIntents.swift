import AppIntents
import Foundation

/// Triggers a cairn sync from the Shortcuts app or a Personal
/// Automation. The intent's `perform()` reaches into the running
/// `AppDependencies.shared` and invokes the same `requestSync` action
/// the in-app "Sync" button uses.
///
/// Target audience: users who self-host Immich and want deterministic
/// "sync after I take photos" behavior to close the gap iOS's
/// black-box background scheduling leaves. Set up via Shortcuts app:
/// New Personal Automation → trigger (e.g. "When App Camera is
/// closed") → action "Sync deletions to Immich" → Done.
///
/// `openAppWhenRun = false` because cairn's sync is headless: it
/// doesn't need any UI to run. iOS will launch cairn into the
/// background, run the perform() body, and let it return. The user
/// stays in whichever app they were using (or the Shortcuts UI).
struct RunCairnSyncIntent: AppIntent {

    // `static let` (not var) so Swift's strict concurrency checker
    // accepts the immutable shared state without a `nonisolated(unsafe)`
    // override. AppIntent metadata is conventionally let in current SDKs.
    //
    // Title includes "cairn" so the shortcut is recognizable in
    // Spotlight, the Shortcuts gallery, and the action picker — where
    // the app icon alone (small) isn't always enough context for a
    // less-common app. "cairn" is rendered lowercase per the brand
    // style guide.
    static let title: LocalizedStringResource = "Sync deletions with cairn"
    static let description = IntentDescription(
        "Has cairn check the Photos library for new deletions and propagate them to your Immich server's trash."
    )

    /// Don't bounce the user out of their current app. cairn's sync
    /// runs headless and reports a result string Shortcuts can display.
    static let openAppWhenRun: Bool = false
    /// Discoverable as an explicit Shortcuts action. Donations let
    /// iOS surface "Suggested Shortcuts" if the user runs this often.
    static let isDiscoverable: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let dependencies = AppDependencies.shared else {
            return .result(dialog: "cairn isn't ready yet. Open the app once, then try again.")
        }
        do {
            try await dependencies.model.actions.requestSync()
            let candidateCount = (dependencies.model.reconciliation?.deleteCandidates.count ?? 0)
                + (dependencies.model.reconciliation?.pendingReviewCandidates.count ?? 0)
            if candidateCount == 0 {
                return .result(dialog: "cairn synced. No new deletions to propagate.")
            } else {
                return .result(dialog: "cairn found \(candidateCount) candidate\(candidateCount == 1 ? "" : "s") in review. Open cairn to confirm.")
            }
        } catch {
            return .result(dialog: "cairn sync failed: \(error.localizedDescription)")
        }
    }
}

/// Surfaces the intent in the system-wide Shortcuts UI and makes the
/// phrases available for "Hey Siri, sync cairn" voice invocation.
/// `\(.applicationName)` resolves to "cairn" at runtime (App Store
/// display name), so iOS users see "Sync cairn" / "Run cairn sync."
struct CairnAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunCairnSyncIntent(),
            phrases: [
                "Sync \(.applicationName)",
                "Run \(.applicationName) sync",
                "Check \(.applicationName)"
            ],
            shortTitle: "cairn sync",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}
