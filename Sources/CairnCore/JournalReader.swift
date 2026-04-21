import Foundation

/// A one-line-per-run summary of what happened during a cairn run. Built from
/// the journal, stable across machines (the journal is the source of truth for
/// anything that happened *on this device*). Powers `cairn journal list` in
/// the CLI and will back the iOS history/undo UI in Phase 2.
public struct RunSummary: Sendable, Equatable {
    public let runId: String
    public let firstTimestamp: Date
    public let lastTimestamp: Date
    public let status: Status
    public let trashedCount: Int
    public let restoredCount: Int

    public enum Status: String, Sendable, Equatable {
        /// The trashed assets for this run have been put back.
        case restored
        /// Assets were successfully trashed and not yet restored.
        case trashed
        /// A trash call errored out partway. Journal records which assets were in the batch.
        case trashFailed = "trash-failed"
        /// A restore call errored out. Likely a server problem; retry should be safe.
        case restoreFailed = "restore-failed"
        /// A dry-run: no server mutation occurred.
        case dryRun = "dry-run"
        /// Safety rail tripped before any mutation.
        case aborted
        /// Started but no terminal event written — interrupted, crashed, or actively running.
        case inProgress = "in-progress"
    }
}

public enum JournalReader {

    /// Entries whose runId matches. Order preserved.
    public static func entries(for runId: String, in entries: [JournalEntry]) -> [JournalEntry] {
        entries.filter { $0.runId == runId }
    }

    /// Group the full journal into one RunSummary per distinct runId. Ordered
    /// by lastTimestamp descending — most recent run first.
    public static func summarize(_ entries: [JournalEntry]) -> [RunSummary] {
        var byRun: [String: [JournalEntry]] = [:]
        for entry in entries {
            byRun[entry.runId, default: []].append(entry)
        }
        return byRun.values
            .map(Self.summarizeRun)
            .sorted { $0.lastTimestamp > $1.lastTimestamp }
    }

    /// Run ID of the most-recently-touched run, or nil if the journal is empty.
    public static func mostRecentRunId(in entries: [JournalEntry]) -> String? {
        summarize(entries).first?.runId
    }

    private static func summarizeRun(_ entries: [JournalEntry]) -> RunSummary {
        precondition(!entries.isEmpty)
        let sorted = entries.sorted { $0.timestamp < $1.timestamp }
        let runId = sorted[0].runId

        var trashedCount = 0
        var restoredCount = 0
        var sawTrashSucceeded = false
        var sawTrashFailed = false
        var sawRestoreSucceeded = false
        var sawRestoreFailed = false
        var sawAborted = false
        var sawRunStarted = false
        var sawRunCompleted = false
        var dryRun = false

        for entry in sorted {
            switch entry.event {
            case .runStarted(let isDry, _, _):
                sawRunStarted = true
                dryRun = isDry
            case .runCompleted:
                sawRunCompleted = true
            case .runAborted:
                sawAborted = true
            case .trashSucceeded(let ids):
                sawTrashSucceeded = true
                trashedCount = ids.count
            case .trashFailed:
                sawTrashFailed = true
            case .restoreSucceeded(_, let ids):
                sawRestoreSucceeded = true
                restoredCount = ids.count
            case .restoreFailed:
                sawRestoreFailed = true
            case .planningTrash, .tagApplied, .restoreStarted:
                break
            }
        }

        let status: RunSummary.Status = {
            if sawAborted { return .aborted }
            if sawRestoreFailed { return .restoreFailed }
            if sawRestoreSucceeded { return .restored }
            if sawTrashFailed && !sawTrashSucceeded { return .trashFailed }
            if sawTrashSucceeded { return .trashed }
            if dryRun && sawRunCompleted { return .dryRun }
            if sawRunStarted && !sawRunCompleted { return .inProgress }
            return .inProgress
        }()

        return RunSummary(
            runId: runId,
            firstTimestamp: sorted.first!.timestamp,
            lastTimestamp: sorted.last!.timestamp,
            status: status,
            trashedCount: trashedCount,
            restoredCount: restoredCount
        )
    }
}
