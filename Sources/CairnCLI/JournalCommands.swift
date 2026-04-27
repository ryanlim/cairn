import ArgumentParser
import Foundation
import CairnCore

/// `cairn journal` — inspect the local append-only deletion journal.
///
/// The journal (`deletion-journal.jsonl` by default, one JSON object per line)
/// is written by every trash and restore run. Unlike `cairn history`, it
/// lives entirely on disk — no API calls, no `tag.read` required — and it
/// preserves events the server can't (e.g. `runAborted` when safety rails
/// stop a run before any DELETE fires).
struct Journal: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "journal",
        abstract: "Inspect the local deletion journal.",
        subcommands: [JournalList.self, JournalShow.self],
        defaultSubcommand: JournalList.self
    )
}

/// Options shared by every `journal` subcommand.
struct JournalOptions: ParsableArguments {
    @Option(name: .long, help: "Path to the deletion journal (JSONL).")
    var journal: String = "deletion-journal.jsonl"
}

// MARK: - journal list

/// `cairn journal list` — one-line-per-run summary, most recent first.
///
/// Runs each journal entry through `JournalReader.summarize`, which derives a
/// status + counts from the event sequence (e.g. a `trashSucceeded` after a
/// `runStarted` → `.trashed`; a `runStarted` with no terminal event →
/// `.inProgress`).
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

/// `cairn journal show` — pretty-print every event for one run.
///
/// Omit `--run-id` (or pass `--last`) to show the most recent run. Each
/// event type has a dedicated pretty-printer in `describe(_:)`.
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

    /// UTC `HH:mm:ss` formatter for the per-event timestamp column. UTC so
    /// output is stable across machines in different time zones (journal
    /// files are portable).
    private func timeFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }

    /// Render one journal event as `(kind, detail)`. `detail` may contain
    /// newlines; `run()` indents continuation lines under the detail column.
    private func describe(_ event: JournalEntry.Event) -> (String, String) {
        switch event {
        case .runStarted(let dry, let cands, let purview):
            return ("runStarted", "candidates=\(cands) purview=\(purview) dry-run=\(dry)")
        case .planningTrash(let targets):
            let lines = targets.prefix(10).map { "\($0.assetId)  ck=\($0.checksum)\($0.livePhotoVideoId.map { "  live-video=\($0)" } ?? "")" }
            let extra = targets.count > 10 ? "\n… and \(targets.count - 10) more" : ""
            return ("planningTrash", "\(targets.count) target(s)\n\(lines.joined(separator: "\n"))\(extra)")
        case .tagApplied(let tagId, let value, let ids, let durationMs):
            let dur = durationMs.map { "  dur=\($0)ms" } ?? ""
            return ("tagApplied", "\(value)\ntag=\(tagId)  \(ids.count) asset(s)\(dur)")
        case .trashSucceeded(let ids, let durationMs):
            let dur = durationMs.map { "  dur=\($0)ms" } ?? ""
            return ("trashSucceeded", "\(ids.count) asset(s)\(dur)")
        case .trashFailed(let ids, let msg, let httpStatus):
            let http = httpStatus.map { "  http=\($0)" } ?? ""
            return ("trashFailed", "\(ids.count) asset(s)\(http)\nerror: \(msg)")
        case .runCompleted(let deleted):
            return ("runCompleted", "deletedCount=\(deleted)")
        case .runAborted(let reason):
            return ("runAborted", reason)
        case .restoreStarted(let from, let ids):
            return ("restoreStarted", "\(ids.count) asset(s)  fromRun=\(from)")
        case .restoreSucceeded(let from, let ids, let durationMs):
            let dur = durationMs.map { "  dur=\($0)ms" } ?? ""
            return ("restoreSucceeded", "\(ids.count) asset(s)  fromRun=\(from)\(dur)")
        case .restoreFailed(let from, let ids, let msg, let httpStatus):
            let http = httpStatus.map { "  http=\($0)" } ?? ""
            return ("restoreFailed", "\(ids.count) asset(s)  fromRun=\(from)\(http)\nerror: \(msg)")
        case .assetsExcluded(let cks, let from):
            let context = from.map { "  fromRun=\($0)" } ?? "  ad-hoc"
            return ("assetsExcluded", "\(cks.count) checksum(s)\(context)")
        case .pendingReview(let assetIds, let cks):
            return ("pendingReview", "\(assetIds.count) asset(s) held for manual approval (strict-mode); \(cks.count) checksum(s)")
        case .syncCompleted(let indexed, let candidates, let pending, let large, let largeBytes, let timeout, let elapsedMs):
            var parts = ["indexed=\(indexed)", "candidates=\(candidates)"]
            if pending > 0 { parts.append("pendingReview=\(pending)") }
            if large > 0 {
                if largeBytes > 0 {
                    let mb = Double(largeBytes) / (1024 * 1024)
                    let sizeStr = mb >= 1024
                        ? String(format: "%.1fGB", mb / 1024)
                        : String(format: "%.1fMB", mb)
                    parts.append("deferredLarge=\(large) (\(sizeStr))")
                } else {
                    parts.append("deferredLarge=\(large)")
                }
            }
            if timeout > 0 { parts.append("deferredTimeout=\(timeout)") }
            parts.append(String(format: "elapsed=%.2fs", Double(elapsedMs) / 1000))
            return ("syncCompleted", parts.joined(separator: " "))
        }
    }
}
