import ArgumentParser
import Foundation
import CairnCore

struct Journal: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "journal",
        abstract: "Inspect the local deletion journal.",
        subcommands: [JournalList.self, JournalShow.self],
        defaultSubcommand: JournalList.self
    )
}

struct JournalOptions: ParsableArguments {
    @Option(name: .long, help: "Path to the deletion journal (JSONL).")
    var journal: String = "deletion-journal.jsonl"
}

// MARK: - journal list

struct JournalList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "One line per run, most recent first."
    )

    @OptionGroup var opts: JournalOptions

    func run() async throws {
        let journal = DeletionJournal(path: URL(fileURLWithPath: opts.journal))
        let all = try await journal.readAll()
        let summaries = JournalReader.summarize(all)
        if summaries.isEmpty {
            print("no runs in \(opts.journal)")
            return
        }
        print("\(summaries.count) run(s) in \(opts.journal):")
        print("")
        let fmt = ISO8601DateFormatter()
        for s in summaries {
            let stamp = fmt.string(from: s.firstTimestamp)
            let status = s.status.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)
            let count: String = switch s.status {
                case .restored: "\(s.restoredCount) restored (was \(s.trashedCount))"
                case .trashed: "\(s.trashedCount) trashed"
                case .trashFailed: "trash failed"
                case .restoreFailed: "restore failed (was \(s.trashedCount))"
                case .dryRun: "no mutation"
                case .aborted: "safety-rail abort"
                case .inProgress: "interrupted"
            }
            print("  \(stamp)  \(status)  \(count)")
            print("                            \(s.runId)")
        }
    }
}

// MARK: - journal show

struct JournalShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Pretty-print every event for a given run."
    )

    @OptionGroup var opts: JournalOptions

    @Option(name: .long, help: "The run to inspect. Omit to show the most recent run.")
    var runId: String?

    @Flag(name: .long, help: "Alias for omitting --run-id — explicit for scripting.")
    var last: Bool = false

    func run() async throws {
        let journal = DeletionJournal(path: URL(fileURLWithPath: opts.journal))
        let all = try await journal.readAll()
        guard let targetRunId = runId ?? JournalReader.mostRecentRunId(in: all) else {
            print("no runs in \(opts.journal)")
            return
        }
        _ = last // accepted for explicitness; selection logic is the same

        let entries = JournalReader.entries(for: targetRunId, in: all)
        if entries.isEmpty {
            throw RuntimeError("run '\(targetRunId)' not found in journal at \(opts.journal)")
        }

        print("run \(targetRunId)")
        let fmt = timeFormatter()
        for entry in entries {
            let stamp = fmt.string(from: entry.timestamp)
            let (kind, detail) = describe(entry.event)
            let kindField = kind.padding(toLength: 18, withPad: " ", startingAt: 0)
            if detail.isEmpty {
                print("  \(stamp)  \(kindField)")
            } else {
                // Split detail on \n to indent continuation lines under the detail column.
                let lines = detail.components(separatedBy: "\n")
                print("  \(stamp)  \(kindField)  \(lines[0])")
                for cont in lines.dropFirst() {
                    print("                               \(cont)")
                }
            }
        }
    }

    private func timeFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }

    private func describe(_ event: JournalEntry.Event) -> (String, String) {
        switch event {
        case .runStarted(let dry, let cands, let purview):
            return ("runStarted", "candidates=\(cands) purview=\(purview) dry-run=\(dry)")
        case .planningTrash(let targets):
            let lines = targets.prefix(10).map { "\($0.assetId)  ck=\($0.checksum)\($0.livePhotoVideoId.map { "  live-video=\($0)" } ?? "")" }
            let extra = targets.count > 10 ? "\n… and \(targets.count - 10) more" : ""
            return ("planningTrash", "\(targets.count) target(s)\n\(lines.joined(separator: "\n"))\(extra)")
        case .tagApplied(let tagId, let value, let ids):
            return ("tagApplied", "\(value)\ntag=\(tagId)  \(ids.count) asset(s)")
        case .trashSucceeded(let ids):
            return ("trashSucceeded", "\(ids.count) asset(s)")
        case .trashFailed(let ids, let msg):
            return ("trashFailed", "\(ids.count) asset(s)\nerror: \(msg)")
        case .runCompleted(let deleted):
            return ("runCompleted", "deletedCount=\(deleted)")
        case .runAborted(let reason):
            return ("runAborted", reason)
        case .restoreStarted(let from, let ids):
            return ("restoreStarted", "\(ids.count) asset(s)  fromRun=\(from)")
        case .restoreSucceeded(let from, let ids):
            return ("restoreSucceeded", "\(ids.count) asset(s)  fromRun=\(from)")
        case .restoreFailed(let from, let ids, let msg):
            return ("restoreFailed", "\(ids.count) asset(s)  fromRun=\(from)\nerror: \(msg)")
        case .assetsExcluded(let cks, let from):
            let context = from.map { "  fromRun=\($0)" } ?? "  ad-hoc"
            return ("assetsExcluded", "\(cks.count) checksum(s)\(context)")
        case .pendingReview(let assetIds, let cks):
            return ("pendingReview", "\(assetIds.count) asset(s) held for manual approval (strict-mode); \(cks.count) checksum(s)")
        }
    }
}
