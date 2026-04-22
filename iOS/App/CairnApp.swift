import SwiftUI
import BackgroundTasks
import CairnCore
import CairnIOSCore

/// The cairn iOS app entry point.
///
/// Deliberately thin — almost everything ships in the `CairnIOSCore` package
/// and is exercised via `#Preview` blocks during development. This file only
/// owns the things that genuinely require an app target: scene management,
/// `BGTaskScheduler.register(...)`, the bridge from concrete iOS-side store
/// implementations into a `CairnAppActions` bundle.
///
/// To add features, edit `CairnIOSCore` (preview-driven). To change how
/// background refresh is scheduled, ship a new screen, or wire a new
/// orchestrator action, edit here.
@main
struct CairnApp: App {

    /// Single source of truth for the wired-together app state.
    @State private var dependencies = AppDependencies()

    /// Background refresh task identifier — must match the value declared in
    /// Info.plist's `BGTaskSchedulerPermittedIdentifiers`.
    static let backgroundRefreshIdentifier = "app.cairn.refresh"

    init() {
        registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            CairnAppRoot(model: dependencies.model)
                .task {
                    await dependencies.bootstrap()
                }
                .onChange(of: ScenePhaseObserver.shared.phase) { _, newPhase in
                    if newPhase == .background {
                        scheduleNextBackgroundRefresh()
                    }
                }
        }
    }

    // MARK: - Background tasks

    /// Registers the background refresh task identifier so iOS knows we're a
    /// candidate for being woken up. Must be called before the App's body
    /// is evaluated for the first time (i.e. in `init`).
    ///
    /// The handler runs reconciliation in `.strict` mode and exits cleanly
    /// when iOS expires the task. Real production scheduling cadence is
    /// "iOS decides" — we just give it a hint via `earliestBeginDate`.
    private func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundRefreshIdentifier,
            using: nil
        ) { task in
            handleBackgroundRefresh(task: task as! BGAppRefreshTask)
        }
    }

    private func handleBackgroundRefresh(task: BGAppRefreshTask) {
        // Always re-schedule first so we stay in the rotation regardless of
        // outcome. iOS gives us ~30s; if we miss the deadline the system
        // marks this run as failed and may reduce future scheduling priority.
        scheduleNextBackgroundRefresh()

        let work = Task {
            do {
                try await dependencies.runScheduledScan()
                task.setTaskCompleted(success: true)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }
        task.expirationHandler = {
            work.cancel()
        }
    }

    private func scheduleNextBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundRefreshIdentifier)
        // ~4h hint per the plan doc. iOS treats this as "no earlier than"
        // and ultimately schedules at its discretion based on user habits.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// Tiny observer so the App can react to scene phase changes without
/// polluting the body with a `@Environment(\.scenePhase)` access (which
/// would force every sub-tree to re-resolve when phase changes).
@MainActor
final class ScenePhaseObserver: ObservableObject {
    static let shared = ScenePhaseObserver()
    @Published var phase: ScenePhase = .active
    private init() {}
}
