import Foundation
import CairnCore

/// Preview fixtures — the SwiftUI mirror of the prototype's `data.js`.
/// Lets `#Preview` blocks render screens with realistic data without
/// needing a real Immich server, real photo library, or live SwiftData.
public enum CairnFixtures {

    public struct LibrarySize: Sendable {
        public let local: Int
        public let indexed: Int
        public let server: Int
        public let matched: Int
        public let candidates: Int

        public init(local: Int, indexed: Int, server: Int, matched: Int, candidates: Int) {
            self.local = local
            self.indexed = indexed
            self.server = server
            self.matched = matched
            self.candidates = candidates
        }

        /// All-zeros library stats. Default for a real-install
        /// `CairnAppModel` before the first successful sync has populated
        /// real counts.
        public static let empty = LibrarySize(local: 0, indexed: 0, server: 0, matched: 0, candidates: 0)

        /// Return a copy with any subset of fields overridden. Lets
        /// call sites update one dimension at a time without
        /// hand-reconstructing every field — e.g.
        /// `library = library.with(server: stats.total)` instead of
        /// the old five-line copy-construct. Missing args keep the
        /// current value.
        public func with(
            local: Int? = nil,
            indexed: Int? = nil,
            server: Int? = nil,
            matched: Int? = nil,
            candidates: Int? = nil
        ) -> LibrarySize {
            LibrarySize(
                local: local ?? self.local,
                indexed: indexed ?? self.indexed,
                server: server ?? self.server,
                matched: matched ?? self.matched,
                candidates: candidates ?? self.candidates
            )
        }
    }

    public static let small  = LibrarySize(local: 843,    indexed: 812,    server: 1_204,  matched: 798,    candidates: 3)
    public static let medium = LibrarySize(local: 4_216,  indexed: 4_189,  server: 5_873,  matched: 4_102,  candidates: 14)
    public static let large  = LibrarySize(local: 12_487, indexed: 12_431, server: 18_204, matched: 12_104, candidates: 47)

    public struct RunFixture: Sendable, Identifiable {
        public let id: String
        public let startedAt: Date
        public let durationMs: Int
        public let trashed: Int
        public let restored: Int
        public let dryRun: Bool
        public let status: Status
        public let tag: String?
        public let notes: String

        public enum Status: Sendable {
            /// Trash run finished; assets are in Immich trash (not yet
            /// restored).
            case complete
            /// Safety rail tripped before mutation.
            case aborted
            /// Previously trashed, later fully restored via cairn's
            /// restore path. The Runs UI hides the Restore button
            /// in this state to prevent double-restores.
            case restored
        }

        public init(
            id: String,
            startedAt: Date,
            durationMs: Int,
            trashed: Int,
            restored: Int,
            dryRun: Bool,
            status: Status,
            tag: String?,
            notes: String
        ) {
            self.id = id
            self.startedAt = startedAt
            self.durationMs = durationMs
            self.trashed = trashed
            self.restored = restored
            self.dryRun = dryRun
            self.status = status
            self.tag = tag
            self.notes = notes
        }

        /// Map a journal-derived `RunSummary` onto the fixture shape
        /// the Runs screens render. Returns `nil` for
        /// `.inProgress` summaries that never got a `runStarted`
        /// event (those are sync-only runs — already surfaced on the
        /// journal-tail card — and would be noise in the Runs list).
        public static func from(_ summary: RunSummary) -> RunFixture? {
            // `.inProgress` can mean "legitimately interrupted" OR
            // "this is just a sync with no trash/restore activity."
            // The RunSummary alone can't distinguish them without
            // consulting the raw events. Filter conservatively:
            // skip .inProgress entirely so sync-only runs don't
            // clutter Runs. A bug-triage path can always be added
            // later if interrupted trashes need surfacing.
            if summary.status == .inProgress { return nil }

            let fixtureStatus: Status = {
                switch summary.status {
                case .aborted:  return .aborted
                case .restored: return .restored
                default:        return .complete
                }
            }()
            let tag: String? = {
                switch summary.status {
                case .trashed, .restored, .trashFailed, .restoreFailed:
                    return "cairn/v1/run/\(summary.runId)"
                case .dryRun, .aborted, .inProgress:
                    return nil
                }
            }()

            return RunFixture(
                id: summary.runId,
                startedAt: summary.firstTimestamp,
                durationMs: summary.durationMs,
                trashed: summary.trashedCount,
                restored: summary.restoredCount,
                dryRun: summary.status == .dryRun,
                status: fixtureStatus,
                tag: tag,
                notes: summary.notes
            )
        }
    }

    public static let runs: [RunFixture] = [
        RunFixture(id: "2026-04-21T17:57:15Z-034389BC", startedAt: iso("2026-04-21T17:57:15Z"), durationMs: 4_210, trashed: 14, restored: 0, dryRun: false, status: .complete, tag: "cairn/v1/run/2026-04-21T17:57:15Z-034389BC", notes: "14 trashed · 2 live-photo videos included"),
        RunFixture(id: "2026-04-20T09:12:03Z-034389BC", startedAt: iso("2026-04-20T09:12:03Z"), durationMs: 3_870, trashed: 2,  restored: 0, dryRun: false, status: .complete, tag: "cairn/v1/run/2026-04-20T09:12:03Z-034389BC", notes: "2 trashed"),
        RunFixture(id: "2026-04-18T22:04:41Z-034389BC", startedAt: iso("2026-04-18T22:04:41Z"), durationMs: 0,     trashed: 0,  restored: 0, dryRun: true,  status: .complete, tag: nil, notes: "dry-run · no candidates"),
        RunFixture(id: "2026-04-17T08:30:00Z-034389BC", startedAt: iso("2026-04-17T08:30:00Z"), durationMs: 2_104, trashed: 1,  restored: 1, dryRun: false, status: .complete, tag: "cairn/v1/run/2026-04-17T08:30:00Z-034389BC", notes: "1 trashed · 1 restored from this run"),
        RunFixture(id: "2026-04-15T14:22:11Z-034389BC", startedAt: iso("2026-04-15T14:22:11Z"), durationMs: 890,   trashed: 0,  restored: 0, dryRun: false, status: .aborted,  tag: nil, notes: "threshold · 2.3% > 1% cap"),
    ]

    public struct CandidateFixture: Sendable, Identifiable {
        public var id: String { name }
        public let name: String
        public let kind: Kind
        public let date: String
        public let bytes: Int
        public let isLivePair: Bool
        /// Immich's server-side asset UUID. Populated when this fixture was
        /// projected from a real `ServerAsset` (via `from(_:)`); `nil` for
        /// synthetic preview fixtures. The UI passes this to
        /// `ImmichAssetThumb` to fetch real thumbnails.
        public let assetId: String?
        /// Base64 SHA1 checksum — Immich's content identity. Populated when
        /// this fixture came from a real journal row or server response;
        /// `nil` for synthetic preview fixtures. Required for the Exclude
        /// flow (the `ExclusionStore` is checksum-keyed); without it, the
        /// run-detail Exclude button can't persist a real exclusion.
        public let checksum: String?
        public let thumbhash: String?

        public enum Kind: Sendable { case photo, video, livePair }

        public init(
            name: String,
            kind: Kind,
            date: String,
            bytes: Int,
            isLivePair: Bool,
            assetId: String? = nil,
            checksum: String? = nil,
            thumbhash: String? = nil
        ) {
            self.name = name
            self.kind = kind
            self.date = date
            self.bytes = bytes
            self.isLivePair = isLivePair
            self.assetId = assetId
            self.checksum = checksum
            self.thumbhash = thumbhash
        }

        /// Build a fixture from a journal `TrashTarget`. Used to
        /// populate `RunDetailSheet` with real asset UUIDs +
        /// metadata captured at trash time — no extra network
        /// round-trip to Immich needed for rendering.
        ///
        /// Filename and date fall back to sensible placeholders
        /// for rows written before those fields were added to
        /// `TrashTarget` (the journal's row-level decode tolerance
        /// keeps those rows readable, they just come back with
        /// nils).
        public static func from(_ target: JournalEntry.TrashTarget) -> CandidateFixture {
            let name = target.originalFileName ?? "asset-\(target.assetId.prefix(8))"
            let ext = (name as NSString).pathExtension.lowercased()
            let isVideo = ["mov", "mp4", "m4v", "avi", "3gp"].contains(ext)
            let isLivePair = target.livePhotoVideoId != nil
            let kind: Kind = isLivePair ? .livePair : (isVideo ? .video : .photo)
            let date: String = {
                guard let created = target.fileCreatedAt else { return "—" }
                return CandidateFixture.dateFormatter.string(from: created)
            }()
            return CandidateFixture(
                name: name,
                kind: kind,
                date: date,
                bytes: 0,   // not captured in the journal (yet)
                isLivePair: isLivePair,
                assetId: target.assetId,
                checksum: target.checksum
            )
        }

        /// `yyyy-MM-dd` — matches the prototype's date column style
        /// and keeps the column narrow in the run-detail list.
        private static let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }()

        /// Project a real server asset into the view-facing shape.
        /// Uses `originalFileName` + `fileCreatedAt` when Immich
        /// supplied them; falls back to a UUID-prefix name and an
        /// empty date string otherwise. Byte size remains a
        /// placeholder — Immich's list endpoint doesn't carry it
        /// without enabling the exif expansion.
        public static func from(_ server: ServerAsset) -> CandidateFixture {
            let name = server.originalFileName ?? "asset-\(server.id.prefix(8))"
            let ext = (name as NSString).pathExtension.lowercased()
            let isVideo = ["mov", "mp4", "m4v", "avi", "3gp"].contains(ext)
            let isLivePair = server.livePhotoVideoId != nil
            let kind: Kind = isLivePair ? .livePair : (isVideo ? .video : .photo)
            let date: String = server.fileCreatedAt.map { dateFormatter.string(from: $0) } ?? ""
            return CandidateFixture(
                name: name,
                kind: kind,
                date: date,
                bytes: 0,
                isLivePair: isLivePair,
                assetId: server.id,
                checksum: server.checksum.base64,
                thumbhash: server.thumbhash
            )
        }
    }

    public static let candidates: [CandidateFixture] = [
        .init(name: "IMG_4821.HEIC", kind: .photo,    date: "2026-04-19", bytes: 2_431_002,  isLivePair: false),
        .init(name: "IMG_4820.HEIC", kind: .photo,    date: "2026-04-19", bytes: 2_188_440,  isLivePair: false),
        .init(name: "IMG_4819.HEIC", kind: .livePair, date: "2026-04-19", bytes: 8_104_772,  isLivePair: true),
        .init(name: "IMG_4818.HEIC", kind: .photo,    date: "2026-04-19", bytes: 1_940_108,  isLivePair: false),
        .init(name: "IMG_4755.HEIC", kind: .photo,    date: "2026-04-14", bytes: 3_017_288,  isLivePair: false),
        .init(name: "IMG_4754.HEIC", kind: .photo,    date: "2026-04-14", bytes: 2_801_101,  isLivePair: false),
        .init(name: "IMG_4612.MP4",  kind: .video,    date: "2026-04-08", bytes: 41_220_990, isLivePair: false),
        .init(name: "IMG_4498.HEIC", kind: .photo,    date: "2026-04-02", bytes: 2_544_708,  isLivePair: false),
        .init(name: "IMG_4497.HEIC", kind: .photo,    date: "2026-04-02", bytes: 2_490_212,  isLivePair: false),
        .init(name: "IMG_4412.HEIC", kind: .photo,    date: "2026-03-29", bytes: 2_610_880,  isLivePair: false),
        .init(name: "IMG_4399.HEIC", kind: .photo,    date: "2026-03-27", bytes: 2_104_551,  isLivePair: false),
        .init(name: "IMG_4354.HEIC", kind: .photo,    date: "2026-03-22", bytes: 2_980_334,  isLivePair: false),
        .init(name: "IMG_4302.HEIC", kind: .livePair, date: "2026-03-18", bytes: 2_402_991,  isLivePair: true),
        .init(name: "IMG_4287.HEIC", kind: .photo,    date: "2026-03-15", bytes: 3_221_044,  isLivePair: false),
        .init(name: "IMG_4210.HEIC", kind: .photo,    date: "2026-03-11", bytes: 2_210_004,  isLivePair: false),
    ]

    // MARK: - Pending-review fixtures (grouped)
    //
    // These exist to drive `PendingReviewScreen` previews in their grouped
    // form: most groups are singletons, but `IMG_4821.HEIC` has two
    // versions (original + edited) and `IMG_4754.HEIC` has three (original
    // + two edits) so the multi-version card layout is exercised. The
    // first-observed anchor set marks the original-content checksum for
    // each multi-version group, which is what the UI uses to render the
    // "Original" pill.

    private static func pendingDate(_ s: String) -> Date {
        ISO8601DateFormatter().date(from: s) ?? Date()
    }

    /// Fixture server assets for the held/aging-out section. Includes two
    /// multi-version groups so the grouping UI is exercised in previews.
    public static let pendingHeldAssets: [ServerAsset] = [
        // Multi-version: IMG_4821.HEIC original + edited
        ServerAsset(
            id: "00000000-0000-0000-0000-0000000004821a",
            checksum: Checksum(base64: "AAAA4821AAAAoriginalcontent"),
            originalFileName: "IMG_4821.HEIC",
            fileCreatedAt: pendingDate("2026-04-19T12:00:00Z")
        ),
        ServerAsset(
            id: "00000000-0000-0000-0000-0000000004821b",
            checksum: Checksum(base64: "BBBB4821BBBBeditedcontent01"),
            originalFileName: "IMG_4821.HEIC",
            fileCreatedAt: pendingDate("2026-04-19T12:00:00Z")
        ),

        ServerAsset(
            id: "00000000-0000-0000-0000-0000000004820a",
            checksum: Checksum(base64: "AAAA4820AAAAsingleversion01"),
            originalFileName: "IMG_4820.HEIC",
            fileCreatedAt: pendingDate("2026-04-19T12:01:00Z")
        ),
        ServerAsset(
            id: "00000000-0000-0000-0000-0000000004819a",
            checksum: Checksum(base64: "AAAA4819AAAAlivepairversion"),
            livePhotoVideoId: "ffffffff-0000-0000-0000-0000000004819b",
            originalFileName: "IMG_4819.HEIC",
            fileCreatedAt: pendingDate("2026-04-19T12:02:00Z")
        ),

        // Multi-version: IMG_4754.HEIC with 3 versions (1 anchored)
        ServerAsset(
            id: "00000000-0000-0000-0000-0000000004754a",
            checksum: Checksum(base64: "AAAA4754AAAAoriginalcontent"),
            originalFileName: "IMG_4754.HEIC",
            fileCreatedAt: pendingDate("2026-04-14T09:00:00Z")
        ),
        ServerAsset(
            id: "00000000-0000-0000-0000-0000000004754b",
            checksum: Checksum(base64: "BBBB4754BBBBeditedcontent01"),
            originalFileName: "IMG_4754.HEIC",
            fileCreatedAt: pendingDate("2026-04-14T09:00:00Z")
        ),
        ServerAsset(
            id: "00000000-0000-0000-0000-0000000004754c",
            checksum: Checksum(base64: "CCCC4754CCCCeditedcontent02"),
            originalFileName: "IMG_4754.HEIC",
            fileCreatedAt: pendingDate("2026-04-14T09:00:00Z")
        ),

        ServerAsset(
            id: "00000000-0000-0000-0000-0000000004612a",
            checksum: Checksum(base64: "AAAA4612AAAAvideoversion010"),
            originalFileName: "IMG_4612.MP4",
            fileCreatedAt: pendingDate("2026-04-08T19:30:00Z")
        ),
    ]

    /// Fixture server assets for the unconfirmed section. Singletons —
    /// the multi-version case is already exercised by the held set.
    public static let pendingUnconfirmedAssets: [ServerAsset] = [
        ServerAsset(
            id: "00000000-0000-0000-0000-0000000004498a",
            checksum: Checksum(base64: "AAAA4498AAAAunconfirmed0001"),
            originalFileName: "IMG_4498.HEIC",
            fileCreatedAt: pendingDate("2026-04-02T10:00:00Z")
        ),
        ServerAsset(
            id: "00000000-0000-0000-0000-0000000004412a",
            checksum: Checksum(base64: "AAAA4412AAAAunconfirmed0002"),
            originalFileName: "IMG_4412.HEIC",
            fileCreatedAt: pendingDate("2026-03-29T11:00:00Z")
        ),
        ServerAsset(
            id: "00000000-0000-0000-0000-0000000004302a",
            checksum: Checksum(base64: "AAAA4302AAAAlivepairunconf0"),
            livePhotoVideoId: "ffffffff-0000-0000-0000-0000000004302b",
            originalFileName: "IMG_4302.HEIC",
            fileCreatedAt: pendingDate("2026-03-18T14:00:00Z")
        ),
    ]

    /// Anchored "Original" checksums — the first-observed bytes for each
    /// multi-version group above. The view labels these versions
    /// "Original" and pins them first within their group.
    public static let pendingFirstObservedAnchors: Set<Checksum> = [
        Checksum(base64: "AAAA4821AAAAoriginalcontent"),
        Checksum(base64: "AAAA4754AAAAoriginalcontent"),
    ]

    public struct JournalTailEntry: Sendable, Identifiable {
        public var id: String { time + event }
        public let time: String
        public let event: String
        public let message: String

        public init(time: String, event: String, message: String) {
            self.time = time
            self.event = event
            self.message = message
        }

        /// Format a `DeletionJournal.JournalEntry` into the Status-screen
        /// tail shape. Keeps every event-type's rendering together so
        /// future event additions only touch this function. Time uses
        /// millisecond precision to line up with the prototype's tail.
        public static func from(_ entry: JournalEntry) -> JournalTailEntry {
            let time = Self.timeFormatter.string(from: entry.timestamp)
            let eventName: String
            let message: String
            switch entry.event {
            case .runStarted(let dryRun, let count, _):
                eventName = "run.start"
                message = "\(dryRun ? "dry-run" : "live") · \(count) candidate\(count == 1 ? "" : "s")"
            case .planningTrash(let targets):
                eventName = "plan.trash"
                message = "\(targets.count) asset\(targets.count == 1 ? "" : "s")"
            case .tagApplied(_, let value, let ids):
                eventName = "tag.apply"
                message = "\(value) → \(ids.count) asset\(ids.count == 1 ? "" : "s")"
            case .trashSucceeded(let ids):
                eventName = "trash.ok"
                message = "\(ids.count) asset\(ids.count == 1 ? "" : "s") moved to Immich's Trash"
            case .trashFailed(let ids, let msg):
                eventName = "trash.fail"
                message = "\(ids.count) asset\(ids.count == 1 ? "" : "s") — \(msg.prefix(60))"
            case .runCompleted(let n):
                eventName = "run.complete"
                message = "trashed=\(n)"
            case .runAborted(let reason):
                eventName = "run.abort"
                message = String(reason.prefix(80))
            case .restoreStarted(let runId, let ids):
                eventName = "restore.start"
                message = "\(ids.count) asset\(ids.count == 1 ? "" : "s") from \(runId.suffix(8))"
            case .restoreSucceeded(_, let ids):
                eventName = "restore.ok"
                message = "\(ids.count) asset\(ids.count == 1 ? "" : "s") restored"
            case .restoreFailed(_, let ids, let msg):
                eventName = "restore.fail"
                message = "\(ids.count) — \(msg.prefix(60))"
            case .assetsExcluded(let cks, _):
                eventName = "exclude.add"
                message = "\(cks.count) checksum\(cks.count == 1 ? "" : "s")"
            case .pendingReview(let ids, _):
                eventName = "pending.hold"
                message = "\(ids.count) asset\(ids.count == 1 ? "" : "s") awaiting review"
            case .syncCompleted(let indexed, let candidates, let pending, let large, let largeBytes, let timeout, let elapsedMs):
                eventName = "sync"
                var parts: [String] = [
                    "indexed=\(indexed)",
                    "cand=\(candidates)",
                ]
                if pending > 0 { parts.append("pending=\(pending)") }
                if large > 0 {
                    // `12 (9.7GB)` when we know the bytes; bytes of
                    // zero means every deferred item had unknown size
                    // (unusual — collapse to the count-only form).
                    if largeBytes > 0 {
                        parts.append("deferred-large=\(large) (\(Self.formatBytes(largeBytes)))")
                    } else {
                        parts.append("deferred-large=\(large)")
                    }
                }
                if timeout > 0 { parts.append("deferred-timeout=\(timeout)") }
                parts.append("dur=\(String(format: "%.2fs", Double(elapsedMs) / 1000))")
                message = parts.joined(separator: " · ")
            }
            return JournalTailEntry(time: time, event: eventName, message: message)
        }

        /// Thin delegate so the journal-tail format matches the
        /// `[cairn.hash]` log lines exactly (no space between number
        /// and unit).
        private static func formatBytes(_ bytes: Int64) -> String {
            CairnTimeHelpers.formatBytesCompact(bytes)
        }

        /// `04/22 · 17:57:19.325` — zero-padded numeric month/day so
        /// yesterday's events don't get confused with today's when
        /// scrolling the expanded tail, and so the column width is
        /// constant regardless of month name length. Ms precision
        /// retained for ordering clarity. Locale pinned to
        /// en_US_POSIX for predictable rendering across devices.
        private static let timeFormatter: DateFormatter = {
            let df = DateFormatter()
            df.dateFormat = "MM/dd · HH:mm:ss.SSS"
            df.locale = Locale(identifier: "en_US_POSIX")
            return df
        }()
    }

    /// Newest-first (matches how the runtime model populates
    /// `CairnAppModel.journalTail` from `DeletionJournal.lastEntries`).
    public static let journalTail: [JournalTailEntry] = [
        .init(time: "04/21 · 17:57:19.325", event: "run.complete", message: "trashed=14 failed=0 dur=4.21s"),
        .init(time: "04/21 · 17:57:15.790", event: "delete.batch", message: "DELETE /api/assets · 14 ids · force=false"),
        .init(time: "04/21 · 17:57:15.604", event: "tag.attach",   message: "attached 14 assets to breadcrumb tag"),
        .init(time: "04/21 · 17:57:15.402", event: "tag.create",   message: "cairn/v1/run/…"),
        .init(time: "04/21 · 17:57:15.318", event: "safety.ok",    message: "percent 0.66 ≤ 1.00 cap · floor 5 met"),
        .init(time: "04/21 · 17:57:15.312", event: "reconcile",    message: "14 candidates · 0.66% of matched (4102)"),
        .init(time: "04/21 · 17:57:15.240", event: "server.pull",  message: "fetched 1204 assets in 138ms"),
        .init(time: "04/21 · 17:57:15.102", event: "run.start",    message: "run_id=2026-04-21T17:57:15Z-034389BC"),
    ]

    private static func iso(_ s: String) -> Date {
        ISO8601DateFormatter().date(from: s) ?? Date()
    }
}

// MARK: - Time helpers shared across screens

public enum CairnTimeHelpers {

    /// "just now" / "5m ago" / "3h ago" / "2d ago" / "Apr 21".
    /// Mirrors the prototype's `relTime`. The "now" param is overridable
    /// so previews and snapshot tests can pin a deterministic clock.
    public static func relativeTime(_ d: Date, now: Date = Date()) -> String {
        let diff = Int(now.timeIntervalSince(d))
        if diff < 60 { return "just now" }
        let m = diff / 60
        if m < 60 { return "\(m)m ago" }
        let h = m / 60
        if h < 24 { return "\(h)h ago" }
        let d2 = h / 24
        if d2 < 7 { return "\(d2)d ago" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f.string(from: d)
    }

    /// "2.4 MB" / "41.2 MB" / "1.06 GB". Mirrors prototype `fmtBytes`.
    public static func formatBytes(_ b: Int) -> String {
        formatBytes(Int64(b))
    }

    /// `Int64` variant for the byte counts PhotoKit / reconciler
    /// return. Same output shape as the `Int` overload so callers
    /// can pick whichever type is convenient.
    public static func formatBytes(_ b: Int64) -> String {
        if b < 1024 { return "\(b) B" }
        let kb = Double(b) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }

    /// Compact form used in log lines: "189.2MB", "9.7GB" — no
    /// space between number and unit, only MB/GB granularity.
    /// Matches the `[cairn.hash]` log output so device console
    /// and journal tail read consistently.
    public static func formatBytesCompact(_ b: Int64) -> String {
        let mb = Double(b) / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%.1fGB", mb / 1024)
        }
        return String(format: "%.1fMB", mb)
    }
}
