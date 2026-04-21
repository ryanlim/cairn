import ArgumentParser
import Foundation
import CairnCore

struct History: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "Server-side view of every cairn run, reconstructed from breadcrumb tags on Immich. Works without the local journal.",
        subcommands: [HistoryList.self, HistoryShow.self],
        defaultSubcommand: HistoryList.self
    )
}

struct HistoryGlobals: ParsableArguments {
    @OptionGroup var globals: GlobalOptions
}

// MARK: - history list

struct HistoryList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List every cairn run the server knows about (one line per v1/run/* tag, most recent first)."
    )

    @OptionGroup var options: HistoryGlobals

    @Flag(name: .long, help: "Query each tag's member count and current trashed/restored breakdown. Slower (one round-trip per run).")
    var detailed: Bool = false

    func run() async throws {
        let client = try loadClient(options.globals)
        let tags: [ImmichTag]
        do {
            tags = try await client.listTags()
        } catch let err as ImmichClientError {
            if case .httpStatus(401, _) = err {
                throw RuntimeError("listing tags requires `tag.read` on the API key — add it in Immich account settings")
            }
            throw err
        }

        struct Run: Sendable {
            let tag: ImmichTag
            let runId: String
        }
        let runs: [Run] = tags.compactMap { tag in
            guard let runId = TagSchema.runId(fromTagValue: tag.value) else { return nil }
            return Run(tag: tag, runId: runId)
        }
        .sorted { ($0.tag.createdAt ?? .distantPast) > ($1.tag.createdAt ?? .distantPast) }

        if runs.isEmpty {
            print("no cairn runs found on server (expected tags matching \(TagSchema.runsPrefix)*)")
            return
        }

        print("\(runs.count) run(s) on server:")
        print("")
        let fmt = ISO8601DateFormatter()
        for r in runs {
            let stamp = r.tag.createdAt.map { fmt.string(from: $0) } ?? "(no timestamp)"
            if detailed {
                let members = try await client.assetsForTag(tagId: r.tag.id, includeTrashed: true)
                let trashed = members.filter { $0.isTrashed }.count
                let live = members.count - trashed
                print("  \(stamp)  \(r.runId)")
                print("                            \(members.count) tagged  (trashed: \(trashed), back in timeline: \(live))")
            } else {
                print("  \(stamp)  \(r.runId)")
            }
        }
        if !detailed {
            print("")
            print("(pass --detailed to include per-run member counts)")
        }
    }
}

// MARK: - history show

struct HistoryShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show every asset attached to a given run's tag, with current trashed/restored state."
    )

    @OptionGroup var options: HistoryGlobals

    @Option(name: .long, help: "Run ID to inspect. The tag value on the server is cairn/v1/run/<this>.")
    var runId: String

    func run() async throws {
        let client = try loadClient(options.globals)
        let tags: [ImmichTag]
        do {
            tags = try await client.listTags()
        } catch let err as ImmichClientError {
            if case .httpStatus(401, _) = err {
                throw RuntimeError("listing tags requires `tag.read` on the API key — add it in Immich account settings")
            }
            throw err
        }

        let wantValue = TagSchema.runTagValue(runId: runId)
        guard let tag = tags.first(where: { $0.value == wantValue }) else {
            throw RuntimeError("no server tag matches \(wantValue) — is the run-id correct?")
        }

        let members = try await client.assetsForTag(tagId: tag.id, includeTrashed: true)
        print("run:  \(runId)")
        print("tag:  \(tag.value)  (id: \(tag.id))")
        print("total tagged assets: \(members.count)")
        let trashed = members.filter { $0.isTrashed }
        let live = members.filter { !$0.isTrashed }
        print("  still trashed:     \(trashed.count)")
        print("  back in timeline:  \(live.count)")
        if !members.isEmpty {
            print("")
            print("assets:")
            for asset in members.prefix(30) {
                let state = asset.isTrashed ? "trashed " : "restored"
                let live = asset.livePhotoVideoId.map { " live-video=\($0)" } ?? ""
                print("  [\(state)]  \(asset.id)  ck=\(asset.checksum)\(live)")
            }
            if members.count > 30 {
                print("  … and \(members.count - 30) more")
            }
        }
    }
}
