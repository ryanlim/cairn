import SwiftUI
import BackgroundTasks
import CairnCore
import CairnIOSCore
import os

/// Logger for background-task lifecycle: registration, submit
/// (success/failure), fire, completion. Stream this in Console.app
/// (subsystem `app.cairn.ios`, category `bgtask`) on a tethered device
/// to verify scheduling is happening end-to-end. `BGTaskScheduler.submit`
/// is `try?`d in handlers, so logging is the only signal that a
/// submission failed (typically rate-limit, missing entitlement, or
/// the system already throttling this app).
/// Internal so `AppDependencies` can write to the same stream when
/// the user manually triggers the BG-refresh path from Settings →
/// Advanced (DEBUG-only "Fire BG refresh now"). Same subsystem +
/// category as the task-handler-driven logs so a single
/// `idevicesyslog -m "[cairn.bgtask]"` filter shows everything.
let bgLog = Logger(subsystem: "app.cairn.ios", category: "bgtask")

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
            .background(
                ScenePhaseBridge(onChange: handleScenePhaseChange)
            )
    }

    /// Reacts to scene-phase transitions. Called from `ScenePhaseBridge`
    /// (which observes `@Environment(\.scenePhase)` directly) rather
    /// than from `.onChange(of: ScenePhaseObserver.shared.phase)` — that
    /// older approach silently broke because `.onChange` doesn't
    /// subscribe to `ObservableObject` updates; it just diffs values on
    /// parent body re-renders, which the singleton write didn't trigger.
    private func handleScenePhaseChange(_ oldPhase: ScenePhase, _ newPhase: ScenePhase) {
        if newPhase == .background {
            Self.scheduleNextBackgroundRefresh()
            // Always submit a BGProcessingTask too, not just when
            // there's pending initial-scan/hash work. iOS only fires
            // these on charging+idle (typically overnight), and the
            // multi-minute budget is exactly what cairn needs to scan
            // for new deletions on a fresh BG slot. Without
            // resubmission, the chain dies once initial scan
            // completes and the user loses the overnight catch-up.
            Self.scheduleInitialHashContinuation()
        } else if newPhase == .active && oldPhase == .background {
            Task { await dependencies.checkServerHealth() }
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
        // Three crash iterations got us here. Builds 41/42/44 all
        // crashed with EXC_BREAKPOINT brk 1 in libdispatch's
        // _dispatch_assert_queue_fail, called from
        // libswift_Concurrency at Task-spawn time, called from the
        // closure stored by BGTaskScheduler. Theory we ruled out:
        // capturing @MainActor `self` was the problem (build 44 used
        // static handlers; still crashed). Real diagnosis: the
        // closure literal inside this method inherits @MainActor
        // isolation because the enclosing type (App-conforming
        // CairnApp) is implicitly @MainActor. When iOS invokes that
        // closure on its internal off-main queue, Swift's runtime
        // asserts the closure's declared MainActor isolation
        // synchronously and crashes before our `Task { @MainActor }`
        // wrapping has any chance to hop.
        //
        // Final fix: pass `using: .main` so BGTaskScheduler invokes
        // the launch handler ON the main queue. Once we're on main,
        // `MainActor.assumeIsolated` is the runtime-cheap way to
        // bridge to @MainActor static methods synchronously without
        // spawning a Task.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundRefreshIdentifier,
            using: .main
        ) { task in
            let bgTask = task as! BGAppRefreshTask
            MainActor.assumeIsolated {
                CairnApp.handleBackgroundRefresh(task: bgTask)
            }
        }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundHashIdentifier,
            using: .main
        ) { task in
            let bgTask = task as! BGProcessingTask
            MainActor.assumeIsolated {
                CairnApp.handleBackgroundHash(task: bgTask)
            }
        }
        bgLog.info("[cairn.bgtask] registered handlers for refresh + hash")
    }

    /// Run the incremental reconciliation from a `BGAppRefreshTask` slot.
    ///
    /// Re-schedules the next refresh first (so we stay in the rotation
    /// regardless of outcome), then runs `runScheduledScan` under a child
    /// `Task` that the expiration handler can cancel. iOS gives us ~30s; a
    /// missed deadline marks the run failed and may reduce future
    /// scheduling priority.
    @MainActor
    private static func handleBackgroundRefresh(task: BGAppRefreshTask) {
        bgLog.info("[cairn.bgtask] refresh fired")
        scheduleNextBackgroundRefresh()

        guard let dependencies = AppDependencies.shared else {
            bgLog.error("[cairn.bgtask] refresh: AppDependencies.shared not set yet, completing as failed")
            task.setTaskCompleted(success: false)
            return
        }

        let work = Task { @MainActor in
            do {
                // Route through requestSync so the journal records a
                // syncStarted(trigger:) + syncCompleted pair just like
                // a foreground sync would. runScheduledScan alone runs
                // the reconciler but skips the journal writes the
                // Status tab depends on.
                try await dependencies.model.actions.requestSync(.scheduledBackground)
                bgLog.info("[cairn.bgtask] refresh completed successfully")
                task.setTaskCompleted(success: true)
            } catch {
                bgLog.error("[cairn.bgtask] refresh failed: \(String(describing: error), privacy: .public)")
                task.setTaskCompleted(success: false)
            }
        }
        task.expirationHandler = {
            bgLog.error("[cairn.bgtask] refresh expired before completion")
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
    @MainActor
    private static func handleBackgroundHash(task: BGProcessingTask) {
        bgLog.info("[cairn.bgtask] hash fired")
        guard let dependencies = AppDependencies.shared else {
            bgLog.error("[cairn.bgtask] hash: AppDependencies.shared not set yet, completing as failed")
            task.setTaskCompleted(success: false)
            return
        }
        let work = Task { @MainActor in
            do {
                // Route the scan part through requestSync so the
                // journal records the BG trigger; then drain the
                // deferred-hash queue separately (which is BG-only
                // unlimited-throughput work, not a "sync" semantically).
                try await dependencies.model.actions.requestSync(.scheduledHashContinuation)
                try await dependencies.drainDeferredQueueOnly()
                bgLog.info("[cairn.bgtask] hash completed successfully")
                task.setTaskCompleted(success: true)
            } catch is CancellationError {
                // iOS expired us; resume picks up next time.
                bgLog.notice("[cairn.bgtask] hash cancelled by expiration handler")
                task.setTaskCompleted(success: false)
            } catch {
                bgLog.error("[cairn.bgtask] hash failed: \(String(describing: error), privacy: .public)")
                task.setTaskCompleted(success: false)
            }
            // Keep the chain alive while work remains. Done after
            // setTaskCompleted to avoid racing with the system's
            // bookkeeping for this slot.
            let needsMore = !dependencies.model.hasCompletedInitialScan
                || dependencies.model.deferredQueue.count > 0
            if needsMore {
                scheduleInitialHashContinuation()
            }
        }
        task.expirationHandler = {
            bgLog.error("[cairn.bgtask] hash expired before completion")
            work.cancel()
        }
    }

    /// Submit the next `BGAppRefreshTaskRequest` with no earliest-begin
    /// hint — iOS treats `nil` as "fire whenever you have a slot."
    /// We deliberately don't set a minimum delay because for cairn's
    /// take→quickly-delete catch case, any slot iOS is willing to give
    /// is better than waiting an artificial 5-minute floor. The
    /// scheduler still throttles based on app engagement, device
    /// state, etc. — we just stop adding our own restriction on top.
    private static func scheduleNextBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundRefreshIdentifier)
        do {
            try BGTaskScheduler.shared.submit(request)
            bgLog.info("[cairn.bgtask] scheduled next refresh (no earliest-begin floor)")
        } catch {
            bgLog.error("[cairn.bgtask] refresh submit failed: \(String(describing: error), privacy: .public)")
        }
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
    private static func scheduleInitialHashContinuation() {
        let request = BGProcessingTaskRequest(identifier: Self.backgroundHashIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
            bgLog.info("[cairn.bgtask] scheduled hash continuation")
        } catch {
            bgLog.error("[cairn.bgtask] hash submit failed: \(String(describing: error), privacy: .public)")
        }
    }
}

/// Scene-phase bridge for the App.
///
/// `@Environment(\.scenePhase)` on the App's body forces every sub-tree to
/// re-resolve whenever the phase changes. Publishing through this singleton
/// lets only the one `onChange` listener at the root react.
///
/// Writes flow in via `ScenePhaseBridge` — a hidden `.background` view that
/// reads `@Environment(\.scenePhase)` and forwards each transition to this
/// singleton. Without that bridge nothing updates `phase`, so background
/// scheduling silently stops working.
@MainActor
final class ScenePhaseObserver: ObservableObject {
    static let shared = ScenePhaseObserver()
    @Published var phase: ScenePhase = .active
    private init() {}
}

/// Hidden view that observes `@Environment(\.scenePhase)` and forwards
/// each transition both to the singleton (for anyone else who wants to
/// read it) and to a callback supplied by `CairnApp` so the App's
/// non-View context can react. Placed inside `mainContent` via
/// `.background(ScenePhaseBridge(...))` so the environment is resolved
/// against the active scene. Renders nothing.
private struct ScenePhaseBridge: View {
    @Environment(\.scenePhase) private var scenePhase
    let onChange: (ScenePhase, ScenePhase) -> Void

    var body: some View {
        Color.clear
            .onChange(of: scenePhase) { oldPhase, newPhase in
                ScenePhaseObserver.shared.phase = newPhase
                onChange(oldPhase, newPhase)
            }
            .onAppear {
                ScenePhaseObserver.shared.phase = scenePhase
            }
    }
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
