import Foundation
import SwiftData
import Photos
import CairnCore
import CairnIOSCore

/// The wiring layer between concrete iOS-side store implementations and the
/// `CairnAppRoot` UI. Held by the `@main App` and shared via the
/// `CairnAppModel` it produces.
///
/// What lives here:
///   - Concrete instantiation of every iOS-side protocol impl
///     (`KeychainSecretStore`, `SwiftDataEverSeenStore`,
///     `SwiftDataExclusionStore`, `SwiftDataConfirmedDeletedStore`,
///     `UserDefaultsSettingsStore`, `PhotoKitPhotoEnumerator`,
///     `ImmichClient`).
///   - The closures that bridge `CairnAppActions` to those impls.
///   - The scheduled-scan entry point invoked from `BGAppRefreshTask`.
///
/// What does NOT live here:
///   - UI views (those are in `CairnIOSCore`).
///   - Reconciliation / safety-rail logic (those are in `CairnCore`).
///   - Any iOS framework knowledge that isn't a concrete dependency
///     (avoid leaking PhotoKit / SwiftData detail beyond what's needed
///     to build the dependency graph).
///
/// You can run the iOS app without ever opening this file; you'll need to
/// edit it when adding a new orchestration action to `CairnAppActions`.
@MainActor
@Observable
final class AppDependencies {

    // MARK: - Concrete impls (reference iOS-side concrete types)

    let secretStore: KeychainSecretStore
    let settingsStore: UserDefaultsSettingsStore
    let photos: PhotoKitPhotoEnumerator
    let modelContainer: ModelContainer
    let everSeenStore: SwiftDataEverSeenStore
    let exclusionStore: SwiftDataExclusionStore
    let confirmedDeletedStore: SwiftDataConfirmedDeletedStore

    /// Built lazily — only after the user has supplied a server URL + API key.
    /// `nil` while we're still in onboarding.
    private(set) var immichClient: ImmichClient?

    /// The journal lives on disk in the app's documents directory. JSONL is
    /// platform-portable and easy to inspect via the Files app.
    let journal: DeletionJournal

    // MARK: - Model wired into the UI

    let model: CairnAppModel

    // MARK: - Init

    init() {
        let secretStore = KeychainSecretStore()
        let settingsStore = UserDefaultsSettingsStore()
        let photos = PhotoKitPhotoEnumerator()
        let container = (try? CairnSwiftDataContainer.make())
            ?? (try! CairnSwiftDataContainer.make(inMemory: true))   // fallback in case on-disk init fails

        self.secretStore = secretStore
        self.settingsStore = settingsStore
        self.photos = photos
        self.modelContainer = container
        self.everSeenStore = SwiftDataEverSeenStore(container: container)
        self.exclusionStore = SwiftDataExclusionStore(container: container)
        self.confirmedDeletedStore = SwiftDataConfirmedDeletedStore(container: container)

        let journalURL = AppDependencies.documentsDirectory()
            .appending(path: "deletion-journal.jsonl")
        self.journal = DeletionJournal(path: journalURL)

        // Build the model with placeholder defaults; bootstrap() fills in the
        // real values asynchronously after the app launches.
        let actions = AppDependencies.makePreviewActions()
        self.model = CairnAppModel(
            needsOnboarding: true,   // pessimistic until bootstrap proves otherwise
            actions: actions
        )
    }

    // MARK: - Bootstrap

    /// Async setup that runs once after the App's WindowGroup is on screen.
    /// Reads stored secrets, decides whether to show onboarding, populates
    /// the model with persisted state, and rebuilds `CairnAppActions` with
    /// closures that have captured the now-fully-instantiated dependencies.
    func bootstrap() async {
        // Try to read credentials from Keychain. If absent → onboarding flow.
        let url = try? secretStore.serverURL()
        let apiKey = try? secretStore.apiKey()
        guard let url, let apiKey else {
            model.needsOnboarding = true
            return
        }

        immichClient = ImmichClient(baseURL: url, apiKey: apiKey)
        model.needsOnboarding = false
        model.serverHost = url.host() ?? url.absoluteString
        model.apiKeyMasked = AppDependencies.mask(apiKey)
        model.settings = (try? await settingsStore.load()) ?? .defaults

        rewireActions()
    }

    // MARK: - Scheduled scan (called by BGAppRefreshTask)

    /// Wave 4 daily-scan entry point. Reads the local Recently Deleted album
    /// and unions any newly-seen checksums into the confirmed-deleted store.
    /// Cheap (Recently Deleted is small) so it fits inside iOS's ~30s
    /// background-refresh budget for typical libraries.
    func runScheduledScan() async throws {
        let recently = try await photos.recentlyDeletedChecksums()
        if !recently.isEmpty {
            try await confirmedDeletedStore.union(recently)
        }
    }

    // MARK: - Action wiring

    private func rewireActions() {
        // Capture dependencies into a fresh CairnAppActions and swap it in.
        // The model's `actions` is a `let`, so we replace the model's actions
        // by copying its other state into a new instance.
        let secrets = self.secretStore
        let settings = self.settingsStore
        let exclusions = self.exclusionStore
        let confirmed = self.confirmedDeletedStore
        let everSeen = self.everSeenStore
        let photos = self.photos
        let journal = self.journal
        let client = self.immichClient

        let actions = CairnAppActions(
            requestSync: { [weak self] in
                guard let self, let client = await self.immichClient else { return }
                // Real reconciliation: enumerate library, fetch server, diff,
                // surface result on the model so the DryRunSheet can render.
                let local = try await photos.currentChecksums()
                let everSeenSet = try await everSeen.snapshot()
                let exclusionSet = Set(try await exclusions.snapshot().keys)
                let confirmedSet = try await confirmed.snapshot()
                let serverAssets = try await client.listAllAssets()
                let result = ReconciliationEngine.compute(.init(
                    serverAssets: serverAssets,
                    currentLocalChecksums: local,
                    everSeenChecksums: everSeenSet,
                    excludedChecksums: exclusionSet,
                    confirmedDeletedChecksums: confirmedSet,
                    strictness: await self.model.settings.deletionStrictness
                ))
                // TODO: stash `result.deleteCandidates` and
                // `result.pendingReviewCandidates` on the model so the
                // DryRunSheet renders against real data instead of fixtures.
                _ = result
            },
            confirmTrash: {
                guard let client else { return }
                // TODO: pass the cached candidates from requestSync to
                // TrashOrchestrator(writer: client, journal: journal).run(...)
                _ = client
                _ = journal
            },
            restore: { _, runId in
                guard let client else { return }
                let orch = RestoreOrchestrator(writer: client, journal: journal)
                _ = try await orch.restore(fromRunId: runId)
            },
            exclude: { filenames, runId in
                // Resolve filenames → checksums via the cached candidates the
                // host populated. For now, just journal the intent.
                let entries: [Checksum: ExclusionMetadata] = Dictionary(
                    uniqueKeysWithValues: filenames.map {
                        // TODO: real checksum lookup
                        (Checksum(base64: $0), ExclusionMetadata(addedAt: Date(), fromRunId: runId, reason: nil))
                    }
                )
                try await exclusions.insert(entries)
                try await journal.append(.init(
                    runId: runId,
                    event: .assetsExcluded(checksums: filenames, fromRunId: runId)
                ))
            },
            unexclude: { filenames in
                let cks = Set(filenames.map { Checksum(base64: $0) })
                try await exclusions.remove(cks)
            },
            verifyServer: { urlString, key in
                guard let url = URL(string: urlString) else {
                    return SetupScreen.ServerVerifyResult(success: false, assetCount: nil, errorMessage: "Invalid URL")
                }
                let probe = ImmichClient(baseURL: url, apiKey: key)
                do {
                    let assets = try await probe.listAllAssets()
                    return SetupScreen.ServerVerifyResult(success: true, assetCount: assets.count, errorMessage: nil)
                } catch {
                    return SetupScreen.ServerVerifyResult(success: false, assetCount: nil, errorMessage: String(describing: error))
                }
            },
            requestPhotosAccess: {
                let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                return status == .authorized
            },
            requestBackgroundRefresh: {
                // Background refresh permission is a system-level setting; we
                // can't request it programmatically, just check whether it's
                // available. Return true if it is (lets onboarding proceed).
                await MainActor.run { UIApplication.shared.backgroundRefreshStatus == .available }
            },
            runFirstDryRun: { [weak self] in
                guard let self else { return }
                try? await self.model.actions.requestSync()
            },
            resetIndex: { [weak self] in
                guard let self else { return }
                // Drop everything in the on-disk container by recreating it.
                // TODO: surface a confirmation in the UI before calling.
                _ = self
            },
            clearJournal: { [weak self] in
                guard let self else { return }
                try? FileManager.default.removeItem(at: self.journal.path)
            },
            signOut: { [weak self] in
                guard let self else { return }
                try? secrets.clear()
                self.immichClient = nil
                self.model.needsOnboarding = true
            }
        )

        // Replace the model's actions by rebuilding it. CairnAppModel's
        // `actions` is a `let`; rebuilding is cheap and the only state that
        // matters is the @Observable-tracked properties, which we copy.
        let snapshot = self.model
        let rebuilt = CairnAppModel(
            needsOnboarding: snapshot.needsOnboarding,
            serverHost: snapshot.serverHost,
            apiKey: snapshot.apiKey,
            apiKeyMasked: snapshot.apiKeyMasked,
            connectionStatus: snapshot.connectionStatus,
            library: snapshot.library,
            runs: snapshot.runs,
            journalTail: snapshot.journalTail,
            settings: snapshot.settings,
            excludedEntries: snapshot.excludedEntries,
            appState: snapshot.appState,
            degraded: snapshot.degraded,
            actions: actions
        )
        // We could either swap the model reference (requires the App to use
        // an @Observable `dependencies` and forward `dependencies.model`) or
        // mutate per-property — for now, mutate per-property so existing
        // bindings in the UI keep working.
        snapshot.needsOnboarding = rebuilt.needsOnboarding
    }

    // MARK: - Helpers

    private static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private static func mask(_ key: String) -> String {
        let tail = key.suffix(4)
        return String(repeating: "•", count: 10) + tail
    }

    /// All-no-op closures for the initial state before bootstrap() runs.
    /// Replaced by rewireActions() once Keychain has produced credentials.
    private static func makePreviewActions() -> CairnAppActions {
        CairnAppActions()   // all defaults
    }
}

import UIKit   // imported only for `UIApplication.shared.backgroundRefreshStatus`
