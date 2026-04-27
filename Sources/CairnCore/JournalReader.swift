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
    /// Milliseconds between `firstTimestamp` and `lastTimestamp`.
    public let durationMs: Int
    /// Short human-readable summary derived from the run's events. Powers the
    /// CLI `journal list` notes column and the iOS History screen.
    public let notes: String

    public init(
        runId: String,
        firstTimestamp: Date,
        lastTimestamp: Date,
        status: Status,
        trashedCount: Int,
        restoredCount: Int,
        durationMs: Int,
        notes: String
    ) {
        self.runId = runId
        self.firstTimestamp = firstTimestamp
        self.lastTimestamp = lastTimestamp
        self.status = status
        self.trashedCount = trashedCount
        self.restoredCount = restoredCount
        self.durationMs = durationMs
        self.notes = notes
    }

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

    /// Provenance for one previously-trashed checksum: which run sent it
    /// to Immich's trash and when. Returned by
    /// `recentlyTrashedChecksums` so callers can label or deep-link the
    /// source run when surfacing the "you restored this; restore it on
    /// Immich too" warning.
    ///
    /// Not persisted — derived from the journal each sync, so no Codable
    /// conformance is needed.
    public struct TrashedRecord: Sendable, Equatable {
        public let runId: String
        public let trashedAt: Date

        public init(runId: String, trashedAt: Date) {
            self.runId = runId
            self.trashedAt = trashedAt
        }
    }

    /// Entries whose runId matches. Order preserved.
    public static func entries(for runId: String, in entries: [JournalEntry]) -> [JournalEntry] {
        entries.filter { $0.runId == runId }
    }

    /// Map of checksum → (runId, trashedAt) for every checksum recorded
    /// as successfully trashed in the last `withinDays` days.
    ///
    /// Walks the journal, pairing each `.trashSucceeded(assetIds:)` with
    /// the matching `.planningTrash(targets:)` events for the same runId
    /// to recover the per-asset checksum (the `.trashSucceeded` payload
    /// is asset IDs only). Older runs lose to newer ones if the same
    /// checksum was trashed twice — the most recent record wins, since
    /// that's the one whose 30-day clock is currently ticking on Immich.
    ///
    /// `withinDays` defaults to 30 to match Immich's hard-delete window.
    /// After the server actually purges the asset, the warning is moot
    /// (the photo is gone server-side; nothing the user can do).
    public static func recentlyTrashedChecksums(
        in entries: [JournalEntry],
        withinDays days: Int = 30,
        now: Date = Date()
    ) -> [Checksum: TrashedRecord] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)

        // Build runId → [assetId: checksum] from `.planningTrash` events.
        // A run can have multiple planningTrash entries (rare but
        // possible if the host appended in batches); merge them.
        var planByRun: [String: [String: String]] = [:]
        for entry in entries {
            if case .planningTrash(let targets) = entry.event {
                var existing = planByRun[entry.runId] ?? [:]
                for target in targets {
                    existing[target.assetId] = target.checksum
                }
                planByRun[entry.runId] = existing
            }
        }

        // Walk `.trashSucceeded` events in chronological order so
        // newer-wins falls out naturally — later iterations overwrite
        // any earlier record for the same checksum.
        let sorted = entries.sorted { $0.timestamp < $1.timestamp }
        var out: [Checksum: TrashedRecord] = [:]
        for entry in sorted {
            guard case .trashSucceeded(let assetIds, _) = entry.event else { continue }
            guard entry.timestamp >= cutoff else { continue }
            guard let plan = planByRun[entry.runId] else { continue }
            let record = TrashedRecord(runId: entry.runId, trashedAt: entry.timestamp)
            for assetId in assetIds {
                guard let raw = plan[assetId] else { continue }
                out[Checksum(base64: raw)] = record
            }
        }
        return out
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
        var firstRunStartedCandidateCount: Int? = nil
        var firstAbortReason: String? = nil
        var firstTrashFailedMessage: String? = nil
        var firstRestoreFailedMessage: String? = nil
        var livePhotoVideoPairCount = 0

        // Per-phase timestamps. Capturing these lets `durationMs`
        // reflect the *most recent* phase only, not the full journal
        // span. Without this, a run that was trashed and then
        // restored N seconds later would report duration = N (the
        // idle gap between phases) — misleading as "how long the
        // run's work took."
        var runStartedAt: Date?
        var runCompletedAt: Date?
        var runAbortedAt: Date?
        var restoreStartedAt: Date?
        var restoreEndedAt: Date?     // either restoreSucceeded or restoreFailed
        var trashEndedAt: Date?       // either trashSucceeded or trashFailed (fallback if runCompleted missing)

        for entry in sorted {
            switch entry.event {
            case .runStarted(let isDry, let candidateCount, _):
                sawRunStarted = true
                dryRun = isDry
                if firstRunStartedCandidateCount == nil {
                    firstRunStartedCandidateCount = candidateCount
                }
                if runStartedAt == nil { runStartedAt = entry.timestamp }
            case .runCompleted:
                sawRunCompleted = true
                runCompletedAt = entry.timestamp
            case .runAborted(let reason):
                sawAborted = true
                if firstAbortReason == nil {
                    firstAbortReason = reason
                }
                runAbortedAt = entry.timestamp
            case .trashSucceeded(let ids, _):
                sawTrashSucceeded = true
                trashedCount = ids.count
                trashEndedAt = entry.timestamp
            case .trashFailed(_, let message, _):
                sawTrashFailed = true
                if firstTrashFailedMessage == nil {
                    firstTrashFailedMessage = message
                }
                trashEndedAt = entry.timestamp
            case .restoreStarted:
                if restoreStartedAt == nil { restoreStartedAt = entry.timestamp }
            case .restoreSucceeded(_, let ids, _):
                sawRestoreSucceeded = true
                restoredCount = ids.count
                restoreEndedAt = entry.timestamp
            case .restoreFailed(_, _, let message, _):
                sawRestoreFailed = true
                if firstRestoreFailedMessage == nil {
                    firstRestoreFailedMessage = message
                }
                restoreEndedAt = entry.timestamp
            case .planningTrash(let targets):
                for target in targets where target.livePhotoVideoId != nil {
                    livePhotoVideoPairCount += 1
                }
            case .tagApplied, .assetsExcluded, .pendingReview:
                break
            case .syncCompleted:
                // Reconciliation summary — not a trash run, not a
                // restore. Doesn't affect any of the fields we compute
                // for `RunSummary`; the Status-screen tail picks these
                // up separately via `JournalTailEntry.from(_:)`.
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

        // Duration reflects the phase corresponding to the run's
        // *current* status — not the full span from first journal
        // event to last. See the comment on the per-phase timestamps
        // above for the rationale.
        let durationMs: Int = {
            func diff(_ start: Date?, _ end: Date?) -> Int {
                guard let s = start, let e = end else { return 0 }
                return Int((e.timeIntervalSince(s) * 1000).rounded())
            }
            switch status {
            case .restored, .restoreFailed:
                return diff(restoreStartedAt, restoreEndedAt)
            case .trashed, .trashFailed, .dryRun:
                return diff(runStartedAt, runCompletedAt ?? trashEndedAt)
            case .aborted:
                return diff(runStartedAt, runAbortedAt)
            case .inProgress:
                // No completion yet — fall back to the current
                // elapsed from start, which matches the old
                // behavior for partial runs.
                return diff(runStartedAt, sorted.last?.timestamp)
            }
        }()

        let firstTimestamp = sorted.first!.timestamp
        let lastTimestamp = sorted.last!.timestamp

        let notes = buildNotes(
            status: status,
            trashedCount: trashedCount,
            restoredCount: restoredCount,
            livePhotoVideoPairCount: livePhotoVideoPairCount,
            firstRunStartedCandidateCount: firstRunStartedCandidateCount,
            firstAbortReason: firstAbortReason,
            firstTrashFailedMessage: firstTrashFailedMessage,
            firstRestoreFailedMessage: firstRestoreFailedMessage,
            sawRunStarted: sawRunStarted
        )

        return RunSummary(
            runId: runId,
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp,
            status: status,
            trashedCount: trashedCount,
            restoredCount: restoredCount,
            durationMs: durationMs,
            notes: notes
        )
    }

    private static func buildNotes(
        status: RunSummary.Status,
        trashedCount: Int,
        restoredCount: Int,
        livePhotoVideoPairCount: Int,
        firstRunStartedCandidateCount: Int?,
        firstAbortReason: String?,
        firstTrashFailedMessage: String?,
        firstRestoreFailedMessage: String?,
        sawRunStarted: Bool
    ) -> String {
        let separator = " · "
        switch status {
        case .trashed:
            var fragments = ["\(trashedCount) trashed"]
            if livePhotoVideoPairCount > 0 {
                fragments.append("\(livePhotoVideoPairCount) live-photo videos included")
            }
            return fragments.joined(separator: separator).lowercased()
        case .restored:
            return "\(restoredCount) restored from this run".lowercased()
        case .trashFailed:
            var fragments = ["trash failed"]
            if let msg = firstTrashFailedMessage, !msg.isEmpty {
                fragments.append(truncateFailureMessage(msg))
            }
            return fragments.joined(separator: separator).lowercased()
        case .restoreFailed:
            var fragments = ["restore failed"]
            if let msg = firstRestoreFailedMessage, !msg.isEmpty {
                fragments.append(truncateFailureMessage(msg))
            }
            return fragments.joined(separator: separator).lowercased()
        case .dryRun:
            let n = firstRunStartedCandidateCount ?? 0
            if n == 0 {
                return "dry-run · no candidates"
            } else {
                return "dry-run · \(n) candidates"
            }
        case .aborted:
            let reason = firstAbortReason ?? ""
            return "aborted · \(reason)".lowercased()
        case .inProgress:
            if sawRunStarted, let n = firstRunStartedCandidateCount {
                return "in-progress · \(n) candidates"
            }
            return "in-progress"
        }
    }

    /// Truncate a failure message to the first sentence (text before first ".")
    /// or the first 60 characters, whichever comes first.
    private static func truncateFailureMessage(_ message: String) -> String {
        let sixtyLimit = message.prefix(60)
        if let dotIndex = sixtyLimit.firstIndex(of: ".") {
            return String(sixtyLimit[..<dotIndex])
        }
        return String(sixtyLimit)
    }
}
