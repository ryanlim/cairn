import SwiftUI
import BackgroundTasks
import CairnCore
import CairnIOSCore

/// The cairn iOS app entry point.
///
/// Deliberately thin — almost everything ships in the `CairnIOSCore` package
/// and is exercised via `#Preview` blocks during development. This file owns
/// only what genuinely requires an app target: scene management,
/// `BGTaskScheduler.register(...)`, and the `task`/`onChange` hooks that
/// drive `AppDependencies`.
///
/// To add a feature or screen, edit `CairnIOSCore` (preview-driven). To
/// change background refresh scheduling or wire a new orchestrator action,
/// edit here and `AppDependencies`.
@main
struct CairnApp: App {

    /// Single source of truth for the wired-together app state. Owns every
    /// store actor, the `ImmichClient`, and the `CairnAppActions` bundle.
    @State private var dependencies = AppDependencies()

    /// `BGAppRefreshTask` identifier for the short incremental-reconciliation
    /// slot (~30s budget). Fires often, opportunistically; replays
    /// `PHPhotoLibrary.fetchPersistentChanges` since the last saved token.
    /// Must match the value declared in Info.plist's
    /// `BGTaskSchedulerPermittedIdentifiers` or `BGTaskScheduler.register`
    /// traps at launch.
    static let backgroundRefreshIdentifier = "app.cairn.refresh"

    /// `BGProcessingTask` identifier for the long initial-hash-continuation
    /// slot (several minutes). iOS schedules this when the device is
    /// charging + idle + on Wi-Fi (overnight, typically). The handler
    /// hashes what it can, re-schedules itself if work remains, and
    /// checkpoints via the expiration handler. Submitted only while
    /// `hasCompletedInitialScan == false` — after that,
    /// `backgroundRefreshIdentifier` is enough.
    static let backgroundHashIdentifier = "app.cairn.hash"

    init() {
        // Register the bundled Fira Code variable font before any
        // `View` evaluates, so `Font.cairnMono(...)` resolves to the
        // real font rather than silently falling back to SF Mono on
        // first render. Registration is idempotent; safe to call
        // every launch.
        CairnFonts.registerBundledFonts()
        registerBackgroundTasks()
    }

    #if DEBUG
    /// True when launched with `-CAIRN_RENDER_WORDMARK`. Routes the scene
    /// to `WordmarkExportView`, which writes a rendered PNG to Documents
    /// and idles. Consumed by `make export-wordmark`. Production builds
    /// strip `#if DEBUG` so this can never return true in shipping code.
    private var isWordmarkExportMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-CAIRN_RENDER_WORDMARK")
    }
    #endif

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if isWordmarkExportMode {
                WordmarkExportView()
            } else {
                mainContent
            }
            #else
            mainContent
            #endif
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        CairnAppRoot(model: dependencies.model)
            // Thread the thumbnail loader through the environment so
            // any `ImmichAssetThumb` in the tree can fetch bytes
            // keyed on their assetId. `nil` pre-onboarding; the
            // `@Observable` property triggers a re-eval of this
            // body when bootstrap completes, at which point the
            // concrete loader flows through.
            .environment(\.immichThumbnailLoader, dependencies.thumbnailLoader)
            .environment(\.thumbnailStore, dependencies.thumbnailStore)
            .task {
                await dependencies.bootstrap()
            }
            .onChange(of: ScenePhaseObserver.shared.phase) { oldPhase, newPhase in
                if newPhase == .background {
                    scheduleNextBackgroundRefresh()
                    if !dependencies.model.hasCompletedInitialScan
                        || dependencies.model.deferredQueue.count > 0 {
                        scheduleInitialHashContinuation()
                    }
                } else if newPhase == .active && oldPhase == .background {
                    Task { await dependencies.checkServerHealth() }
                }
            }
    }

    // MARK: - Background tasks

    /// Register handlers for both background task identifiers.
    ///
    /// Must run before the App's body is evaluated (i.e. in `init`) —
    /// `BGTaskScheduler` traps if a task fires without a registered
    /// handler. Both `forTaskWithIdentifier` strings must also appear in
    /// Info.plist under `BGTaskSchedulerPermittedIdentifiers`.
    ///
    /// - `refresh` (BGAppRefreshTask) — ~30 seconds, incremental
    ///   reconciliation. Fires opportunistically, often.
    /// - `hash` (BGProcessingTask) — several minutes, initial-hash
    ///   continuation. Fires rarely — typically when the device is
    ///   charging and idle (overnight). Re-submitted from the handler
    ///   until `hasCompletedInitialScan == true`.
    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundRefreshIdentifier,
            using: nil
        ) { task in
            handleBackgroundRefresh(task: task as! BGAppRefreshTask)
        }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundHashIdentifier,
            using: nil
        ) { task in
            handleBackgroundHash(task: task as! BGProcessingTask)
        }
    }

    /// Run the incremental reconciliation from a `BGAppRefreshTask` slot.
    ///
    /// Re-schedules the next refresh first (so we stay in the rotation
    /// regardless of outcome), then runs `runScheduledScan` under a child
    /// `Task` that the expiration handler can cancel. iOS gives us ~30s; a
    /// missed deadline marks the run failed and may reduce future
    /// scheduling priority.
    private func handleBackgroundRefresh(task: BGAppRefreshTask) {
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

    /// Run the reconciler (plus deferred-hash drain) from a
    /// `BGProcessingTask` slot.
    ///
    /// More budget than `handleBackgroundRefresh` (several minutes vs ~30s),
    /// but iOS can still expire at any point. `LocalHashStore` persists
    /// each asset's checksum inline, so cooperative cancellation via the
    /// expiration handler is safe — the next slot resumes rather than
    /// restarts. If the initial scan is still incomplete, re-schedules
    /// another continuation before returning, keeping the chain alive.
    private func handleBackgroundHash(task: BGProcessingTask) {
        let work = Task {
            do {
                // `runBackgroundDrain` does the incremental/full scan
                // AND drains the deferred-hash queue with the soft
                // limit disabled. This is the slot where large iCloud
                // videos we skipped in foreground finally hash —
                // device is plugged in + on Wi-Fi (per the request's
                // `requiresNetworkConnectivity`), which is the only
                // context it's OK to download multi-GB content from.
                try await dependencies.runBackgroundDrain()
                task.setTaskCompleted(success: true)
            } catch is CancellationError {
                // iOS expired us; resume picks up next time.
                task.setTaskCompleted(success: false)
            } catch {
                task.setTaskCompleted(success: false)
            }
            // Keep the chain alive while work remains. Done after
            // setTaskCompleted to avoid racing with the system's
            // bookkeeping for this slot.
            let needsMore = await !dependencies.model.hasCompletedInitialScan
                || dependencies.model.deferredQueue.count > 0
            if needsMore {
                scheduleInitialHashContinuation()
            }
        }
        task.expirationHandler = {
            work.cancel()
        }
    }

    /// Submit the next `BGAppRefreshTaskRequest` with a ~4h earliest-begin
    /// hint. iOS treats the date as "no earlier than" and ultimately
    /// schedules at its discretion based on user habits.
    private func scheduleNextBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundRefreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Submit a `BGProcessingTaskRequest` for long-running initial-hash work.
    ///
    /// iOS picks the timing — typically when the device is charging, idle,
    /// and on Wi-Fi. Called on every backgrounding event while the initial
    /// scan is incomplete, so an overnight charge can chew through hundreds
    /// or thousands of assets while the user sleeps.
    ///
    /// `requiresNetworkConnectivity = true` because iCloud-optimized photos
    /// need a network fetch to hash. `requiresExternalPower` stays at its
    /// default `false` so iOS has flexibility; in practice BGProcessingTask
    /// rarely runs off-power anyway.
    private func scheduleInitialHashContinuation() {
        let request = BGProcessingTaskRequest(identifier: Self.backgroundHashIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// Scene-phase bridge for the App.
///
/// `@Environment(\.scenePhase)` on the App's body forces every sub-tree to
/// re-resolve whenever the phase changes. Publishing through this singleton
/// lets only the one `onChange` listener at the root react.
@MainActor
final class ScenePhaseObserver: ObservableObject {
    static let shared = ScenePhaseObserver()
    @Published var phase: ScenePhase = .active
    private init() {}
}

#if DEBUG
/// Renders the hero wordmark once and writes it to Documents as PNG,
/// then idles. Consumed by the `make export-wordmark` flow, which
/// pulls the PNG out of the sim's app container via
/// `xcrun simctl get_app_container`.
///
/// Rendered at 3× scale — crisp on retina, still compact enough for a
/// README banner (~1200px wide). Content-fits the bounding box so the
/// PNG has no whitespace beyond ~8pt of breathing room.
private struct WordmarkExportView: View {
    @State private var exportedPath: String?

    private let size: CGFloat = 120   // the "size" parameter on CairnWordmark

    var body: some View {
        VStack {
            // Visible wordmark so you can tell the sim is in the right
            // mode. Path shows below once the PNG has been written.
            CairnWordmark(size: size, variant: .hero, style: .iconPrefix)
                .padding(24)

            if let path = exportedPath {
                Text("Exported:\n\(path)")
                    .font(.system(size: 10, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .task { @MainActor in
            exportedPath = Self.render(size: size)
        }
    }

    /// Render `CairnWordmark` via `ImageRenderer` at 3× native scale
    /// and write the PNG to the app's Documents directory. Returns
    /// the on-device path (for the on-screen label + Console).
    @MainActor
    private static func render(size: CGFloat) -> String? {
        let wordmark = CairnWordmark(size: size, variant: .hero, style: .iconPrefix)
            .padding(8)     // small breathing room around the glyph lockup
            .fixedSize()
            .cairnTheme()   // ensures tokens resolve outside the normal app tree

        let renderer = ImageRenderer(content: wordmark)
        renderer.scale = 3.0   // retina — 3× pixel density
        renderer.isOpaque = false

        guard let uiImage = renderer.uiImage,
              let png = uiImage.pngData() else {
            print("[cairn.wordmark-export] ImageRenderer produced no image")
            return nil
        }

        let dest = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "cairn-wordmark.png")

        do {
            try png.write(to: dest, options: .atomic)
            print("[cairn.wordmark-export] wrote \(png.count) bytes to \(dest.path)")
            return dest.path
        } catch {
            print("[cairn.wordmark-export] write failed: \(error)")
            return nil
        }
    }
}
#endif
