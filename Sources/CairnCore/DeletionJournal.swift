import Foundation

/// Append-only forensic log of every destructive action the app takes (or attempts).
/// One JSON object per line (JSONL). Never mutated after write.
///
/// The journal is written *before* each destructive call and *after* its outcome,
/// so a partial failure can always be reconstructed from disk. Pair with
/// the per-run breadcrumb tag on the server side: the journal answers
/// "what did we do?" and the tag answers "where did it land?".
public actor DeletionJournal {
    public let path: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// Latches on first `readAll` that finds undecodable rows so we
    /// don't spam the console with the same "skipped N rows" line
    /// on every subsequent read (it's the same rows each time —
    /// printing once per actor lifetime is enough context, and the
    /// user's action item is "Clear journal" regardless).
    private var hasWarnedAboutSkippedRows = false

    public init(path: URL) {
        self.path = path
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    /// Write one entry to the end of the file. Creates the file on
    /// first call. Writes are serialized through the actor; callers
    /// don't need their own locking.
    public func append(_ entry: JournalEntry) throws {
        let data = try encoder.encode(entry)
        var line = data
        line.append(0x0A) // '\n'

        let fm = FileManager.default
        if !fm.fileExists(atPath: path.path) {
            fm.createFile(atPath: path.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.close()
    }

    /// Cheap tail: the most-recent `count` entries, newest last.
    /// Implemented by reading the whole file today since the Status
    /// journal-tail rendering needs only a handful of entries and the
    /// file is line-oriented JSONL. If perf ever matters, reverse-seek
    /// from EOF and parse backward.
    public func lastEntries(limit: Int) throws -> [JournalEntry] {
        let all = try readAll()
        return Array(all.suffix(limit))
    }

    /// Every entry in the journal, in on-disk order. Undecodable rows
    /// (schema drift, hand-edits) are skipped rather than aborting the
    /// read; a one-shot console warning surfaces the skip count on the
    /// first read of this actor's lifetime.
    public func readAll() throws -> [JournalEntry] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let raw = try Data(contentsOf: path)
        guard let text = String(data: raw, encoding: .utf8) else { return [] }
        var out: [JournalEntry] = []
        var skipped = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // Per-row tolerance: a schema change (e.g. adding a field
            // to an enum case) makes older rows fail to decode. Rather
            // than letting one bad row bail the whole tail, skip it
            // and keep going. Mostly relevant during development —
            // pre-1.0 the wire format isn't frozen.
            do {
                let entry = try decoder.decode(JournalEntry.self, from: Data(trimmed.utf8))
                out.append(entry)
            } catch {
                skipped += 1
                continue
            }
        }
        if skipped > 0 && !hasWarnedAboutSkippedRows {
            print("[cairn.journal] skipped \(skipped) undecodable row(s) in \(path.lastPathComponent) — Settings → Clear journal to remove them")
            hasWarnedAboutSkippedRows = true
        }
        return out
    }

    /// Read the raw JSONL file as individual lines, preserving entries
    /// the current schema can't decode. Used by export.
    public func readRawLines() throws -> [String] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let raw = try Data(contentsOf: path)
        guard let text = String(data: raw, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Append pre-encoded JSONL lines from an import. Each line should
    /// be a complete JSON object (no trailing newline — this method adds it).
    public func appendRawLines(_ lines: [String]) throws {
        guard !lines.isEmpty else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: path.path) {
            fm.createFile(atPath: path.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            var data = Data(trimmed.utf8)
            data.append(0x0A)
            try handle.write(contentsOf: data)
        }
        try handle.close()
    }
}

/// One row of the journal. `runId` groups entries into a single
/// logical operation (trash, restore, dry-run, or reconciliation);
/// `JournalReader.summarize` buckets by it. `timestamp` defaults to
/// now, so append sites rarely pass it.
public struct JournalEntry: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let runId: String
    public let event: Event

    /// What initiated a given sync. Surfaced in the Runs tab so the
    /// user can distinguish a manual tap from an iOS-scheduled
    /// background slot. Encoded as a plain string for forward-
    /// compatibility; future cases default-decode as `.unknown` on
    /// older readers.
    public enum SyncTrigger: String, Codable, Sendable, Equatable, CaseIterable {
        /// User tapped Sync in the app foreground.
        case manualForeground = "manual_foreground"
        /// iOS fired a `BGAppRefreshTask` slot (~30s budget).
        case scheduledBackground = "scheduled_background"
        /// iOS fired a `BGProcessingTask` slot (several minutes;
        /// typically requires charging + idle).
        case scheduledHashContinuation = "scheduled_hash_continuation"
        /// Triggered by a Shortcut (Shortcuts app, Siri, or
        /// Personal Automation via `RunCairnSyncIntent`).
        case shortcut = "shortcut"
        /// DEBUG-only "Fire BG refresh now" Settings row.
        case debugManualFire = "debug_manual_fire"
        /// Pre-trigger-recording sync or unknown source.
        case unknown = "unknown"

        public var displayName: String {
            switch self {
            case .manualForeground: return "Manual"
            // Both BG task types display as "Background" — the
            // distinction (BGAppRefreshTask short slot vs
            // BGProcessingTask long slot) is an iOS implementation
            // detail. The earlier "Overnight" label for the long
            // slot was misleading: iOS fires BGProcessingTask any
            // time the device is charging + idle + on Wi-Fi, which
            // happens in the middle of the day too. Diagnostic
            // detail is preserved in the [cairn.bgtask] os.Logger
            // stream ("refresh fired" vs "hash fired"), which is
            // what `log collect --device` captures.
            case .scheduledBackground, .scheduledHashContinuation: return "Background"
            case .shortcut: return "Shortcut"
            case .debugManualFire: return "Debug"
            case .unknown: return "—"
            }
        }

        /// Short lowercase token for `key=value`-style log/journal
        /// messages. Matches the existing tail convention
        /// (`indexed=N`, `cand=N`, `edit-prot=N`, etc.) rather than
        /// the title-cased `displayName` used in UI rows.
        public var shortToken: String {
            switch self {
            case .manualForeground: return "manual"
            case .scheduledBackground, .scheduledHashContinuation: return "background"
            case .shortcut: return "shortcut"
            case .debugManualFire: return "debug"
            case .unknown: return "unknown"
            }
        }
    }

    public init(timestamp: Date = Date(), runId: String, event: Event) {
        self.timestamp = timestamp
        self.runId = runId
        self.event = event
    }

    /// Discriminated union of everything cairn writes to the journal.
    /// Adding a case is wire-compatible (older readers ignore unknown
    /// cases via `readAll`'s row-level tolerance); changing an existing
    /// case's payload is not — bump the schema or add a new case.
    public enum Event: Codable, Sendable, Equatable {
        /// What triggered a sync. Written by `performLiveReconciliation`
        /// alongside `syncCompleted` so the Runs tab can show whether
        /// a run came from a user tap, a background slot, a Shortcut,
        /// etc. Legacy runs without this event display as `.unknown`.
        case syncStarted(trigger: SyncTrigger)
        case runStarted(dryRun: Bool, candidateCount: Int, assetsInPurview: Int)
        case planningTrash(targets: [TrashTarget])
        // `durationMs` is the wall-clock time of just the underlying API
        // call (tag-create-or-attach for `tagApplied`, the trash batch
        // for `trashSucceeded`, the restore batch for `restoreSucceeded`).
        // Optional so older journals — which predate the field — decode
        // cleanly via Swift's `decodeIfPresent` for Optional associated
        // values. Adding the field does NOT break wire compatibility.
        case tagApplied(tagId: String, tagValue: String, assetIds: [String], durationMs: Int?)
        case trashSucceeded(assetIds: [String], durationMs: Int?)
        // `httpStatus` is the HTTP response code on failure (when the
        // underlying error was `ImmichClientError.httpStatus(...)`); nil
        // when the failure was a transport-level error (DNS, TLS, network
        // unreachable) or a non-HTTP exception. Optional for the same
        // wire-compat reason as the duration fields.
        case trashFailed(assetIds: [String], message: String, httpStatus: Int?)
        case runCompleted(deletedCount: Int)
        case runAborted(reason: String)
        case restoreStarted(fromRunId: String, assetIds: [String])
        case restoreSucceeded(fromRunId: String, assetIds: [String], durationMs: Int?)
        case restoreFailed(fromRunId: String, assetIds: [String], message: String, httpStatus: Int?)
        /// User added these checksums to the exclusion list. `fromRunId` is set when
        /// the exclusion happened from a run-detail view; nil for ad-hoc additions.
        case assetsExcluded(checksums: [String], fromRunId: String?)
        /// In `.strict` mode, candidates whose checksums were not in the
        /// confirmed-deleted set are held for the user's manual review rather
        /// than trashed. Records the held set for forensics.
        case pendingReview(assetIds: [String], checksums: [String])
        /// One reconciliation pass finished. Not part of the trash
        /// run-life-cycle (`runStarted` / `runCompleted`) — those fire
        /// only when assets actually move to Immich trash. `syncCompleted`
        /// fires on every reconcile, including no-op ones, so the Status
        /// screen's journal tail reflects real activity rather than
        /// sitting empty until a trash run finally happens.
        case syncCompleted(
            indexed: Int,                // assets with a committed SHA1 after this pass
            candidates: Int,             // eligible-to-trash count
            pendingReview: Int,          // held for user review
            deferredLarge: Int,          // skipped because iCloud fetch > limit
            deferredLargeBytes: Int64,   // summed iCloud bytes the deferred items would download
            deferredTimeout: Int,        // skipped because fetch took > per-asset timeout
            elapsedMs: Int               // wall-clock duration of the pass
        )
        /// Per-sync summary of state-transition counts that aren't
        /// covered by `syncCompleted`'s scalar totals — specifically the
        /// edit-retirement partitioning and the per-source attribution
        /// of newly-confirmed deletions. Emitted once per reconciliation
        /// pass when any of the four counts is non-zero; absent
        /// otherwise to keep journal volume modest. Read by display:
        /// `editsProtected` / `editsQuarantined` reveal whether edits
        /// in Photos.app are being handled correctly; `confirmedFrom*`
        /// pair distinguishes Photos.app-deleted assets (the primary
        /// signal) from back-channel deletions caught by the orphan
        /// safety net (which would otherwise look identical in the log).
        case syncTransitions(
            editsProtected: Int,
            editsQuarantined: Int,
            confirmedFromPhotoKit: Int,
            confirmedFromOrphanSweep: Int
        )
    }

    /// One asset's worth of info captured at trash-plan time. Carried
    /// verbatim into the journal so per-run detail views, restore
    /// commands, and offline forensics don't need to round-trip back
    /// to the Immich server.
    public struct TrashTarget: Codable, Sendable, Equatable {
        public let assetId: String
        public let checksum: String
        public let livePhotoVideoId: String?
        /// Filename captured at trash time so the per-run detail
        /// view can show real names rather than UUID fragments.
        /// Optional because older journal rows predate this field;
        /// the row-level decode tolerance in `readAll` keeps them
        /// readable either way.
        public let originalFileName: String?
        /// `fileCreatedAt` captured at trash time. Same rationale as
        /// `originalFileName` — populates the per-run detail's date
        /// column without a round-trip to Immich.
        public let fileCreatedAt: Date?

        public init(
            assetId: String,
            checksum: String,
            livePhotoVideoId: String?,
            originalFileName: String? = nil,
            fileCreatedAt: Date? = nil
        ) {
            self.assetId = assetId
            self.checksum = checksum
            self.livePhotoVideoId = livePhotoVideoId
            self.originalFileName = originalFileName
            self.fileCreatedAt = fileCreatedAt
        }

        // Custom decode: missing filename/date keys (pre-extension
        // rows) decode cleanly as nil rather than throwing
        // `DecodingError.keyNotFound`.
        private enum CodingKeys: String, CodingKey {
            case assetId, checksum, livePhotoVideoId
            case originalFileName, fileCreatedAt
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.assetId = try c.decode(String.self, forKey: .assetId)
            self.checksum = try c.decode(String.self, forKey: .checksum)
            self.livePhotoVideoId = try c.decodeIfPresent(String.self, forKey: .livePhotoVideoId)
            self.originalFileName = try c.decodeIfPresent(String.self, forKey: .originalFileName)
            self.fileCreatedAt = try c.decodeIfPresent(Date.self, forKey: .fileCreatedAt)
        }
    }
}
