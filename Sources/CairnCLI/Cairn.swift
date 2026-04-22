import ArgumentParser
import Foundation
import CairnCore

@main
struct Cairn: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cairn",
        abstract: "Reconcile a local-photo set against an Immich server, trashing assets that have left the local set.",
        subcommands: [Verify.self, DryRun.self, Trash.self, Restore.self, Journal.self, History.self, DumpServerChecksums.self, Diagnose.self],
        defaultSubcommand: DryRun.self
    )
}

/// Shared options applied to every subcommand.
struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Path to a .env file with IMMICH_URL and IMMICH_API_KEY (default: ./.env in current directory).")
    var envFile: String = ".env"
}

func loadClient(_ opts: GlobalOptions) throws -> ImmichClient {
    EnvFileLoader.load(fromPath: opts.envFile)
    let secrets = EnvSecretStore()
    return ImmichClient(baseURL: try secrets.serverURL(), apiKey: try secrets.apiKey())
}

// MARK: - verify

struct Verify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Confirm connectivity and that the API key is valid by listing assets."
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let client = try loadClient(globals)
        let assets = try await client.listAllAssets()
        print("connectivity + auth OK; API key sees \(assets.count) asset(s) for this user.")
    }
}

// MARK: - dump-server-checksums

struct DumpServerChecksums: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dump-server-checksums",
        abstract: "Write all server-side asset checksums (one base64 SHA1 per line) to a file. Useful for simulating an iPhone library during algorithm validation."
    )

    @OptionGroup var globals: GlobalOptions

    @Option(name: .long, help: "Output file path.")
    var output: String

    @Flag(name: .long, help: "Include trashed assets too (off by default).")
    var includeTrashed: Bool = false

    func run() async throws {
        let client = try loadClient(globals)
        let assets = try await client.listAllAssets(includeTrashed: includeTrashed)
        let lines = assets.map(\.checksum.base64).sorted().joined(separator: "\n") + "\n"
        try lines.write(toFile: output, atomically: true, encoding: .utf8)
        print("wrote \(assets.count) checksum(s) to \(output)")
    }
}

// MARK: - dry-run

struct DryRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dry-run",
        abstract: "Compute a reconciliation diff without trashing anything."
    )

    @OptionGroup var globals: GlobalOptions

    @Option(
        name: .long,
        help: "Path to a file with one base64 SHA1 checksum per line representing the photos currently on the device."
    )
    var localChecksumsFile: String

    @Option(
        name: .long,
        help: "Path to the persistent ever-seen checksum store (JSON). Created if absent."
    )
    var everSeenStore: String = "ever-seen.json"

    @Option(name: .long, help: "Abort if more than this percent (0–100) of in-purview assets would be deleted. Default: 1 (one percent).")
    var maxDeletePercent: Double = 1.0

    @Option(name: .long, help: "Threshold-percent abort fires only above this absolute candidate count. Lets small libraries delete a few photos at a time without spurious aborts.")
    var minDeleteCountForThreshold: Int = 5

    @Option(name: .long, help: "Path to the persistent exclusion store (JSON). Checksums in this file are protected from trashing on every run.")
    var exclusionsStore: String = "exclusions.json"

    @Option(name: .long, help: "Path to the persistent confirmed-deleted store (JSON). Wave 4: append-only set of checksums positively observed in iOS Recently Deleted.")
    var confirmedDeletedStore: String = "confirmed-deleted.json"

    @Option(name: .long, help: "Optional file of base64 SHA1 checksums representing assets currently in iOS Recently Deleted. Unioned into the confirmed-deleted store on this run.")
    var recentlyDeletedChecksumsFile: String?

    @Option(name: .long, help: "Deletion strictness: strict (only confirmed-deleted candidates trash; rest go to pending review) or trusting (any diff candidate eligible). Default: strict.")
    var strictness: DeletionStrictness = .strict

    func run() async throws {
        let client = try loadClient(globals)
        let photos = ChecksumFilePhotoEnumerator(
            filePath: localChecksumsFile,
            recentlyDeletedFilePath: recentlyDeletedChecksumsFile
        )
        let store = JSONFileEverSeenStore(filePath: everSeenStore)
        let exclusions = JSONFileExclusionStore(filePath: exclusionsStore)
        let confirmed = JSONFileConfirmedDeletedStore(filePath: confirmedDeletedStore)

        let local = try await photos.currentChecksums()
        let confirmedBefore = try await confirmed.snapshot()
        // Refresh confirmed-deleted with anything currently in Recently Deleted.
        let recentlyDeleted = try await photos.recentlyDeletedChecksums()
        let newlyConfirmed = recentlyDeleted.subtracting(confirmedBefore)
        if !newlyConfirmed.isEmpty {
            try await confirmed.union(newlyConfirmed)
        }

        let everSeenBefore = try await store.snapshot()
        let excludedSet = Set(try await exclusions.snapshot().keys)
        let confirmedSet = try await confirmed.snapshot()
        let isFirstRun = everSeenBefore.isEmpty

        print("local checksums: \(local.count)")
        print("ever-seen (before): \(everSeenBefore.count)\(isFirstRun ? "  [first run]" : "")")
        if !excludedSet.isEmpty { print("excluded checksums: \(excludedSet.count)") }
        print("confirmed-deleted: \(confirmedSet.count)\(newlyConfirmed.isEmpty ? "" : "  (+\(newlyConfirmed.count) from this scan)")")
        print("strictness: \(strictness.rawValue)")
        print("fetching server assets…")

        let allServer = try await client.listAllAssets()
        print("server assets (excluding trashed): \(allServer.count)")

        let result = ReconciliationEngine.compute(.init(
            serverAssets: allServer,
            currentLocalChecksums: local,
            everSeenChecksums: everSeenBefore,
            excludedChecksums: excludedSet,
            confirmedDeletedChecksums: confirmedSet,
            strictness: strictness
        ))

        print("newly-observed local checksums (would be added to ever-seen): \(result.newlyObservedChecksums.count)")
        print("server assets in purview (in ever-seen): \(result.assetsInEverSeen)")
        if result.excludedCandidateCount > 0 {
            print("excluded by allowlist (would-be candidates skipped): \(result.excludedCandidateCount)")
        }
        print("delete candidates: \(result.deleteCandidates.count)")
        if !result.pendingReviewCandidates.isEmpty {
            print("pending review (strict-mode holdback, not yet confirmed deleted): \(result.pendingReviewCandidates.count)")
        }

        let safety = SafetyRails.evaluate(
            reconciliation: result,
            totalServerAssets: allServer.count,
            currentLocalCount: local.count,
            isFirstRun: isFirstRun,
            isDryRun: true,
            config: .init(
                maxDeletePercent: maxDeletePercent / 100.0,
                minDeleteCountForThreshold: minDeleteCountForThreshold
            )
        )

        switch safety {
        case .proceed:
            print("safety: PROCEED (dry-run, nothing deleted)")
        case .abort(let reason):
            print("safety: ABORT — \(reason)")
        }

        if !result.deleteCandidates.isEmpty {
            print("\nfirst up to 20 confirmed-deletion candidates:")
            for asset in result.deleteCandidates.prefix(20) {
                let live = asset.livePhotoVideoId.map { " (livePhotoVideo: \($0))" } ?? ""
                print("  \(asset.id)  \(asset.checksum)\(live)")
            }
        }
        if !result.pendingReviewCandidates.isEmpty {
            print("\nfirst up to 20 pending-review candidates (would need manual approval in strict mode):")
            for asset in result.pendingReviewCandidates.prefix(20) {
                let live = asset.livePhotoVideoId.map { " (livePhotoVideo: \($0))" } ?? ""
                print("  \(asset.id)  \(asset.checksum)\(live)")
            }
        }

        // Persist the updated ever-seen set even on dry-run; it's only the deletion that
        // we're suppressing. This makes repeated dry-runs converge correctly.
        try await store.union(local)
        let everSeenAfter = try await store.snapshot()
        print("ever-seen (after): \(everSeenAfter.count)  → \(everSeenStore)")
        let confirmedAfter = try await confirmed.snapshot()
        print("confirmed-deleted (after): \(confirmedAfter.count)  → \(confirmedDeletedStore)")
    }
}

extension DeletionStrictness: ExpressibleByArgument {}

// MARK: - trash (the destructive path)

struct Trash: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trash",
        abstract: "Reconcile and TRASH (force=false) eligible server assets. Tags each batch with a per-run breadcrumb tag and writes a deletion-journal entry for every step."
    )

    @OptionGroup var globals: GlobalOptions

    @Option(name: .long, help: "Path to a file with one base64 SHA1 checksum per line representing the photos currently on the device.")
    var localChecksumsFile: String

    @Option(name: .long, help: "Path to the persistent ever-seen checksum store (JSON). Created if absent.")
    var everSeenStore: String = "ever-seen.json"

    @Option(name: .long, help: "Path to the append-only deletion journal (JSONL).")
    var journal: String = "deletion-journal.jsonl"

    @Option(name: .long, help: "Abort if more than this percent (0–100) of in-purview assets would be deleted. Default: 1.")
    var maxDeletePercent: Double = 1.0

    @Option(name: .long, help: "Threshold-percent abort fires only above this absolute candidate count.")
    var minDeleteCountForThreshold: Int = 5

    @Flag(name: .long, help: "Skip interactive confirmation. Required for non-interactive use; otherwise the command pauses for a y/N prompt before deleting.")
    var yes: Bool = false

    @Option(name: .long, help: "Override the run ID (default: timestamped UUID). Useful for resuming or for deterministic tests.")
    var runId: String?

    @Option(name: .long, help: "Path to the persistent exclusion store (JSON). Checksums in this file are protected from trashing on every run.")
    var exclusionsStore: String = "exclusions.json"

    @Option(name: .long, help: "Path to the persistent confirmed-deleted store (JSON). Wave 4: append-only set of checksums positively observed in iOS Recently Deleted.")
    var confirmedDeletedStore: String = "confirmed-deleted.json"

    @Option(name: .long, help: "Optional file of base64 SHA1 checksums representing assets currently in iOS Recently Deleted. Unioned into the confirmed-deleted store on this run.")
    var recentlyDeletedChecksumsFile: String?

    @Option(name: .long, help: "Deletion strictness: strict (only confirmed-deleted candidates trash; rest go to pending review) or trusting (any diff candidate eligible). Default: strict.")
    var strictness: DeletionStrictness = .strict

    func run() async throws {
        let client = try loadClient(globals)
        let photos = ChecksumFilePhotoEnumerator(
            filePath: localChecksumsFile,
            recentlyDeletedFilePath: recentlyDeletedChecksumsFile
        )
        let store = JSONFileEverSeenStore(filePath: everSeenStore)
        let exclusions = JSONFileExclusionStore(filePath: exclusionsStore)
        let confirmed = JSONFileConfirmedDeletedStore(filePath: confirmedDeletedStore)

        let local = try await photos.currentChecksums()
        let confirmedBefore = try await confirmed.snapshot()
        let recentlyDeleted = try await photos.recentlyDeletedChecksums()
        let newlyConfirmed = recentlyDeleted.subtracting(confirmedBefore)
        if !newlyConfirmed.isEmpty {
            try await confirmed.union(newlyConfirmed)
        }

        let everSeenBefore = try await store.snapshot()
        let excludedSet = Set(try await exclusions.snapshot().keys)
        let confirmedSet = try await confirmed.snapshot()
        let isFirstRun = everSeenBefore.isEmpty

        if isFirstRun {
            throw RuntimeError("first run on a fresh ever-seen store must use `dry-run`, not `trash`. After dry-run seeds ever-seen, you can switch to trash.")
        }

        print("local checksums: \(local.count)")
        print("ever-seen (before): \(everSeenBefore.count)")
        if !excludedSet.isEmpty { print("excluded checksums: \(excludedSet.count)") }
        print("confirmed-deleted: \(confirmedSet.count)\(newlyConfirmed.isEmpty ? "" : "  (+\(newlyConfirmed.count) from this scan)")")
        print("strictness: \(strictness.rawValue)")
        print("fetching server assets…")
        let allServer = try await client.listAllAssets()
        print("server assets (excluding trashed): \(allServer.count)")

        let recon = ReconciliationEngine.compute(.init(
            serverAssets: allServer,
            currentLocalChecksums: local,
            everSeenChecksums: everSeenBefore,
            excludedChecksums: excludedSet,
            confirmedDeletedChecksums: confirmedSet,
            strictness: strictness
        ))
        if recon.excludedCandidateCount > 0 {
            print("excluded by allowlist (would-be candidates skipped): \(recon.excludedCandidateCount)")
        }
        print("delete candidates: \(recon.deleteCandidates.count)")
        if !recon.pendingReviewCandidates.isEmpty {
            print("pending review (strict-mode holdback, not yet confirmed deleted): \(recon.pendingReviewCandidates.count)")
        }

        let safety = SafetyRails.evaluate(
            reconciliation: recon,
            totalServerAssets: allServer.count,
            currentLocalCount: local.count,
            isFirstRun: isFirstRun,
            isDryRun: false,
            config: .init(
                maxDeletePercent: maxDeletePercent / 100.0,
                minDeleteCountForThreshold: minDeleteCountForThreshold
            )
        )

        switch safety {
        case .proceed:
            break
        case .abort(let reason):
            print("safety: ABORT — \(reason)")
            throw ExitCode.failure
        }

        let resolvedRunId = runId ?? "\(ISO8601DateFormatter().string(from: Date()))-\(UUID().uuidString.prefix(8))"
        let journalActor = DeletionJournal(path: URL(fileURLWithPath: journal))

        // Journal pending-review holdback even if we have nothing to trash —
        // the user / iOS app needs to know these assets are awaiting approval.
        if !recon.pendingReviewCandidates.isEmpty {
            try await journalActor.append(.init(
                runId: resolvedRunId,
                event: .pendingReview(
                    assetIds: recon.pendingReviewCandidates.map(\.id),
                    checksums: recon.pendingReviewCandidates.map(\.checksum.base64)
                )
            ))
            print("\njournaled pending-review event for \(recon.pendingReviewCandidates.count) asset(s) under run-id \(resolvedRunId).")
        }

        if recon.deleteCandidates.isEmpty {
            if recon.pendingReviewCandidates.isEmpty {
                print("nothing to do.")
            } else {
                print("nothing eligible to trash (pending-review only). Approve via the iOS app or rerun with --strictness trusting.")
            }
            return
        }

        print("\nfirst up to 20 candidates:")
        for asset in recon.deleteCandidates.prefix(20) {
            let live = asset.livePhotoVideoId.map { " (livePhotoVideo: \($0))" } ?? ""
            print("  \(asset.id)  \(asset.checksum)\(live)")
        }
        if recon.deleteCandidates.count > 20 {
            print("  … and \(recon.deleteCandidates.count - 20) more")
        }

        if !yes {
            print("\nrun-id: \(resolvedRunId)")
            print("breadcrumb tag will be: \(TagSchema.runTagValue(runId: resolvedRunId))")
            print("journal: \(journal)")
            // First confirm: intent.
            print("\nMove \(recon.deleteCandidates.count) assets to trash? [y/N] ", terminator: "")
            let first = readLine() ?? ""
            if first.lowercased() != "y" && first.lowercased() != "yes" {
                print("aborted by user.")
                throw ExitCode.failure
            }
            // Second confirm: dangerous-action acknowledgement, mirrors the iOS
            // "Yes, trash N" rust-banner pattern. Two-confirm is design-mandated
            // for live trash (see HANDOFF.md "Two-confirm trash path").
            print("Yes, trash \(recon.deleteCandidates.count). They'll be recoverable in Immich trash for 30 days. [y/N] ", terminator: "")
            let second = readLine() ?? ""
            if second.lowercased() != "y" && second.lowercased() != "yes" {
                print("aborted by user.")
                throw ExitCode.failure
            }
        }

        let orchestrator = TrashOrchestrator(writer: client, journal: journalActor)
        let summary = try await orchestrator.run(
            runId: resolvedRunId,
            candidates: recon.deleteCandidates,
            assetsInPurview: recon.assetsInEverSeen,
            dryRun: false
        )

        print("\ntrashed \(summary.trashedAssetIds.count) asset id(s).")
        if let tag = summary.breadcrumbTag {
            print("breadcrumb tag in Immich: \(tag.value) (id: \(tag.id))")
        }
        print("journal: \(journal)")

        try await store.union(local)
        let everSeenAfter = try await store.snapshot()
        print("ever-seen (after): \(everSeenAfter.count)  → \(everSeenStore)")
    }
}

// MARK: - restore (undo a trash run)

struct Restore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Restore assets trashed by a prior run. By default restores the whole run; pass --asset-id (repeatable) to restore a subset."
    )

    @OptionGroup var globals: GlobalOptions

    @Option(name: .long, help: "The trash run ID to undo. Check the journal or the breadcrumb tag on Immich (cairn/v1/run/<run_id>) to find it.")
    var runId: String

    @Option(name: .long, parsing: .singleValue, help: "Asset ID within the run to restore. Repeat for multiple. If absent, the whole run is restored. Live Photo halves auto-expand — passing a still also restores its motion video.")
    var assetId: [String] = []

    @Option(name: .long, help: "ICU regex matched against each asset's originalFileName; only matching assets are restored. Requires `tag.read` on the API key. Mutually exclusive with --asset-id.")
    var fileNameMatches: String?

    @Option(name: .long, help: "Path to the deletion journal (JSONL).")
    var journal: String = "deletion-journal.jsonl"

    @Flag(name: .long, help: "Skip interactive confirmation.")
    var yes: Bool = false

    func run() async throws {
        let client = try loadClient(globals)
        let journalActor = DeletionJournal(path: URL(fileURLWithPath: journal))

        let entries = try await journalActor.readAll()
        let forRun = entries.filter { $0.runId == runId }
        if forRun.isEmpty {
            throw RuntimeError("run '\(runId)' not found in journal at \(journal)")
        }
        var trashedIds: [String] = []
        var planningTargets: [JournalEntry.TrashTarget] = []
        for entry in forRun {
            if case .trashSucceeded(let ids) = entry.event { trashedIds = ids }
            if case .planningTrash(let targets) = entry.event { planningTargets = targets }
        }
        if trashedIds.isEmpty {
            throw RuntimeError("run '\(runId)' has no trashSucceeded event — nothing to restore")
        }

        if fileNameMatches != nil && !assetId.isEmpty {
            throw RuntimeError("--file-name-matches and --asset-id can't be combined; use one or the other")
        }

        let assetIdsOverride: Set<String>?
        let previewIds: [String]

        if let pattern = fileNameMatches {
            let regex: NSRegularExpression
            do {
                regex = try NSRegularExpression(pattern: pattern)
            } catch {
                throw RuntimeError("invalid regex '\(pattern)': \(error)")
            }
            let wantValue = TagSchema.runTagValue(runId: runId)
            let tags: [ImmichTag]
            do {
                tags = try await client.listTags()
            } catch let err as ImmichClientError {
                if case .httpStatus(401, _) = err {
                    throw RuntimeError("--file-name-matches requires `tag.read` on the API key; add it in Immich account settings")
                }
                throw err
            }
            guard let tag = tags.first(where: { $0.value == wantValue }) else {
                throw RuntimeError("no server tag matches \(wantValue); --file-name-matches requires the server-side tag to still exist")
            }
            let members = try await client.assetsForTag(tagId: tag.id, includeTrashed: true)
            let matched = members.filter { asset in
                guard let name = asset.originalFileName else { return false }
                return regex.firstMatch(in: name, range: NSRange(location: 0, length: name.utf16.count)) != nil
            }
            if matched.isEmpty {
                throw RuntimeError("no assets in run '\(runId)' matched filename regex '\(pattern)'")
            }
            print("filename regex '\(pattern)' matched \(matched.count) of \(members.count) assets in the run:")
            for a in matched.prefix(10) {
                print("  \(a.id)  \(a.originalFileName ?? "(no filename)")")
            }
            if matched.count > 10 { print("  … and \(matched.count - 10) more") }

            let expanded = RestoreOrchestrator.expandLivePhotoPairs(
                Set(matched.map(\.id)),
                from: members
            )
            assetIdsOverride = expanded
            previewIds = expanded.sorted()
        } else if !assetId.isEmpty {
            let override = Set(assetId)
            let unknown = override.subtracting(trashedIds)
            if !unknown.isEmpty {
                throw RuntimeError("asset id(s) not in run '\(runId)': \(unknown.sorted().joined(separator: ", "))")
            }
            let expanded = RestoreOrchestrator.expandLivePhotoPairs(override, from: planningTargets)
            assetIdsOverride = expanded
            previewIds = expanded.sorted()
        } else {
            assetIdsOverride = nil
            previewIds = trashedIds
        }

        print("run: \(runId)")
        if !assetId.isEmpty {
            print("partial restore: \(assetId.count) requested, \(previewIds.count) total after Live Photo expansion")
        }
        print("would restore \(previewIds.count) asset id(s):")
        for id in previewIds.prefix(20) { print("  \(id)") }
        if previewIds.count > 20 { print("  … and \(previewIds.count - 20) more") }

        if !yes {
            print("\nproceed with restore? [y/N] ", terminator: "")
            let answer = readLine() ?? ""
            if answer.lowercased() != "y" && answer.lowercased() != "yes" {
                print("aborted by user.")
                throw ExitCode.failure
            }
        }

        let orch = RestoreOrchestrator(writer: client, journal: journalActor)
        let summary = try await orch.restore(fromRunId: runId, assetIds: assetIdsOverride)
        print("\nrestored \(summary.restoredAssetIds.count) asset id(s).")
        print("journal: \(journal)")
    }
}

// MARK: - diagnose (observability only — no mutation)

struct Diagnose: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diagnose",
        abstract: "Inspect server-side asset state across visibility classes; surface integrity issues (e.g. orphan motion videos)."
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let client = try loadClient(globals)

        // `locked` requires an elevated-permissions auth flow (PIN/session upgrade) that
        // our API-key auth doesn't have; it would 401 the whole diagnose. Skip it.
        let visibilities: [AssetVisibility] = [.timeline, .archive, .hidden]
        var perClass: [(AssetVisibility, [ServerAsset])] = []
        for visibility in visibilities {
            let assets = try await client.listAllAssets(visibility: visibility)
            perClass.append((visibility, assets))
        }

        print("=== visibility classes ===")
        for (vis, assets) in perClass {
            print("  \(vis.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(assets.count)")
        }
        let total = perClass.reduce(0) { $0 + $1.1.count }
        print("  -----")
        print("  total      \(total)")

        // Integrity: every motion video referenced by a still should exist; every
        // hidden video should be referenced by at least one still.
        let timelineAssets = perClass.first { $0.0 == .timeline }?.1 ?? []
        let hiddenAssets = perClass.first { $0.0 == .hidden }?.1 ?? []
        let hiddenIds = Set(hiddenAssets.map(\.id))
        let referencedVideoIds = Set(timelineAssets.compactMap(\.livePhotoVideoId))

        let danglingReferences = referencedVideoIds.subtracting(hiddenIds)
        let orphanedHidden = hiddenIds.subtracting(referencedVideoIds)

        print("")
        print("=== Live Photo integrity ===")
        print("  stills referencing a motion video: \(referencedVideoIds.count)")
        print("  hidden assets in total:           \(hiddenIds.count)")
        if danglingReferences.isEmpty {
            print("  dangling livePhotoVideoId references: 0")
        } else {
            print("  dangling livePhotoVideoId references: \(danglingReferences.count) — stills point at video UUIDs not present in hidden set")
            for id in danglingReferences.sorted().prefix(10) { print("    \(id)") }
        }
        if orphanedHidden.isEmpty {
            print("  orphaned hidden assets:               0")
        } else {
            print("  orphaned hidden assets:               \(orphanedHidden.count) — hidden assets with no still pointing to them")
            for id in orphanedHidden.sorted().prefix(10) { print("    \(id)") }
        }
    }
}
