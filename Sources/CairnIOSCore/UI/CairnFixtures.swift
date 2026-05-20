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
        /// `false` when `indexed` hasn't been computed yet for the
        /// active account — UI should render "—" instead of the count.
        /// Bootstrap before server activation (and before user identity
        /// is cached) leaves this unset; the first successful
        /// `refreshLibrarySizeStats` after activation flips it to true.
        /// Without this flag, fresh-account onboarding would surface
        /// the global LocalHashStore count (potentially populated by a
        /// different account on this device), which reads as "we
        /// somehow know about all your photos" — confusing.
        public let indexedKnown: Bool

        public init(
            local: Int,
            indexed: Int,
            server: Int,
            matched: Int,
            candidates: Int,
            indexedKnown: Bool = true
        ) {
            self.local = local
            self.indexed = indexed
            self.server = server
            self.matched = matched
            self.candidates = candidates
            self.indexedKnown = indexedKnown
        }

        /// All-zeros library stats. Default for a real-install
        /// `CairnAppModel` before the first successful sync has populated
        /// real counts. `indexedKnown: false` so UI shows "—" rather
        /// than a misleading "0" until the first intersection compute
        /// happens.
        public static let empty = LibrarySize(local: 0, indexed: 0, server: 0, matched: 0, candidates: 0, indexedKnown: false)

        /// Return a copy with any subset of fields overridden. Lets
        /// call sites update one dimension at a time without
        /// hand-reconstructing every field — e.g.
        /// `library = library.with(server: stats.total)` instead of
        /// the old five-line copy-construct. Missing args keep the
        /// current value. Setting `indexed` (non-nil) auto-flips
        /// `indexedKnown` to true since the caller is providing a real
        /// value; pass an explicit `indexedKnown: false` to override.
        public func with(
            local: Int? = nil,
            indexed: Int? = nil,
            server: Int? = nil,
            matched: Int? = nil,
            candidates: Int? = nil,
            indexedKnown: Bool? = nil
        ) -> LibrarySize {
            LibrarySize(
                local: local ?? self.local,
                indexed: indexed ?? self.indexed,
                server: server ?? self.server,
                matched: matched ?? self.matched,
                candidates: candidates ?? self.candidates,
                indexedKnown: indexedKnown ?? (indexed != nil ? true : self.indexedKnown)
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
        // First 8 entries carry `assetId: "fixture-demo-photo-NN"` so
        // `ImmichAssetThumb`'s bundle-lookup short-circuit serves real
        // royalty-free thumbnails (see `Resources/FixturePhotos/`).
        // The remaining 7 are intentionally untagged — they only
        // surface on the Pending Review preview's deeper rows and
        // staying on the gradient keeps the bundle small.
        .init(name: "IMG_4821.HEIC", kind: .photo,    date: "2026-04-19", bytes: 2_431_002,  isLivePair: false, assetId: "fixture-demo-photo-01"),
        .init(name: "IMG_4820.HEIC", kind: .photo,    date: "2026-04-19", bytes: 2_188_440,  isLivePair: false, assetId: "fixture-demo-photo-02"),
        .init(name: "IMG_4819.HEIC", kind: .livePair, date: "2026-04-19", bytes: 8_104_772,  isLivePair: true,  assetId: "fixture-demo-photo-03"),
        .init(name: "IMG_4818.HEIC", kind: .photo,    date: "2026-04-19", bytes: 1_940_108,  isLivePair: false, assetId: "fixture-demo-photo-04"),
        .init(name: "IMG_4755.HEIC", kind: .photo,    date: "2026-04-14", bytes: 3_017_288,  isLivePair: false, assetId: "fixture-demo-photo-05"),
        .init(name: "IMG_4754.HEIC", kind: .photo,    date: "2026-04-14", bytes: 2_801_101,  isLivePair: false, assetId: "fixture-demo-photo-06"),
        .init(name: "IMG_4612.MP4",  kind: .video,    date: "2026-04-08", bytes: 41_220_990, isLivePair: false, assetId: "fixture-demo-photo-07"),
        .init(name: "IMG_4498.HEIC", kind: .photo,    date: "2026-04-02", bytes: 2_544_708,  isLivePair: false, assetId: "fixture-demo-photo-08"),
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
        public var id: String { time + event + runIdSuffix + message }
        public let time: String
        public let event: String
        public let message: String
        /// SF Symbol name for the leading status glyph. Lives on the
        /// fixture (rather than being mapped at render time from
        /// `event`) so the choice sits next to the message
        /// construction in `from(_:)` — adding a new event type
        /// touches one place.
        public let glyph: String
        /// Last 8 chars of the entry's runId (typically the UUID
        /// suffix portion of `<iso>-<uuid8>`). Right-aligned column
        /// on the row so users can correlate events to a run at a
        /// glance.
        public let runIdSuffix: String
        /// True only for `syncCompleted` events whose every signal
        /// field is zero (no candidates, no pending, no deferred).
        /// The Status filter chip elides these — they're noise in the
        /// tail. Anything else (including a sync that found
        /// candidates) stays visible.
        public let isRoutineSync: Bool
        /// The `runId` from the source `JournalEntry`. Used by the row
        /// tap handler to look up a matching `RunFixture` and open the
        /// run-detail sheet. Empty for fixture-only rows that didn't
        /// come from a `JournalEntry`.
        public let runId: String
        /// Severity tier for the leading dot, distinct from `glyph`
        /// (which is event-keyed). Lets users scan for problems
        /// without reading every event name.
        public let severity: Severity
        /// Pretty-printed JSON of the source `JournalEntry`. Surfaced
        /// via long-press on a row → raw-event sheet. Optional because
        /// fixture rows that didn't come from a real `JournalEntry`
        /// have nothing to encode.
        public let rawJSON: String?

        public enum Severity: Sendable {
            /// Routine activity: sync, plan, tag, run.start.
            case info
            /// Mutating action that succeeded: trash.ok, restore.ok,
            /// run.complete, exclude.add.
            case ok
            /// Held / deferred / awaiting attention: pending.hold.
            case warn
            /// Failure or aborted: *.fail, run.abort.
            case error
        }

        public init(
            time: String,
            event: String,
            message: String,
            glyph: String = "circle.fill",
            runIdSuffix: String = "",
            isRoutineSync: Bool = false,
            runId: String = "",
            severity: Severity = .info,
            rawJSON: String? = nil
        ) {
            self.time = time
            self.event = event
            self.message = message
            self.glyph = glyph
            self.runIdSuffix = runIdSuffix
            self.isRoutineSync = isRoutineSync
            self.runId = runId
            self.severity = severity
            self.rawJSON = rawJSON
        }

        /// Snapshot of the count fields a `syncCompleted` event carries
        /// that are interesting to delta. Lets `from(entries:)` walk
        /// chronologically and inject `(+5)` / `(−2)` clauses into the
        /// next sync row's message. Excludes `deferred*` and `elapsedMs`
        /// — those are per-pass measurements, not running totals where
        /// a delta is meaningful.
        public struct SyncCounts: Sendable, Equatable {
            public let indexed: Int
            public let candidates: Int
            public let pending: Int
            public init(indexed: Int, candidates: Int, pending: Int) {
                self.indexed = indexed
                self.candidates = candidates
                self.pending = pending
            }
        }

        /// Format a `DeletionJournal.JournalEntry` into the Status-screen
        /// tail shape. Keeps every event-type's rendering together so
        /// future event additions only touch this function. Time format
        /// is relative-aware (today → `HH:mm`, otherwise `MMM d HH:mm`).
        ///
        /// `previousSyncCounts` enables delta annotation on
        /// `syncCompleted` rows ("indexed=1010 (+10) cand=2 (−1)"). Pass
        /// `nil` (default) when there's no chronological prior sync in
        /// scope; `from(entries:)` populates it for batch construction.
        public static func from(
            _ entry: JournalEntry,
            previousSyncCounts: SyncCounts? = nil
        ) -> JournalTailEntry {
            let time = formatTime(entry.timestamp)
            let eventName: String
            let message: String
            let glyph: String
            let severity: Severity
            var routine = false
            switch entry.event {
            case .runStarted(let dryRun, let count, let purview):
                eventName = "run.start"
                glyph = "play.circle"
                severity = .info
                // Surface the candidate-vs-purview ratio when both are
                // known and meaningful. "12 of 4820 (0.25%)" reads more
                // honestly than a bare "12 candidates" — gives the user
                // a sense of how aggressive the run is relative to the
                // library. Skip the ratio for purview ≤ 0 (legacy rows
                // or genuine empty libraries).
                let countStr = "\(count) candidate\(count == 1 ? "" : "s")"
                let mode = dryRun ? "dry-run" : "live"
                if purview > 0 {
                    let pct = Double(count) / Double(purview) * 100
                    let pctStr = pct < 0.01 && count > 0
                        ? "<0.01%"
                        : String(format: "%.2f%%", pct)
                    message = "\(mode) · \(count) of \(purview) (\(pctStr))"
                } else {
                    message = "\(mode) · \(countStr)"
                }
            case .planningTrash(let targets):
                eventName = "plan.trash"
                glyph = "list.bullet"
                severity = .info
                message = "\(targets.count) asset\(targets.count == 1 ? "" : "s")"
            case .tagApplied(_, let value, let ids, let durationMs):
                eventName = "tag.apply"
                glyph = "tag"
                severity = .info
                // Tag values are `cairn/v1/run/<iso>-<uuid8>` — full
                // path is too wide for the single-line row. Trim to
                // the trailing 12 chars so the runId fragment stays
                // correlatable to the suffix column.
                let short = value.count > 12 ? "…" + String(value.suffix(12)) : value
                let durSuffix = formatDurationSuffix(durationMs)
                message = "\(short) → \(ids.count) asset\(ids.count == 1 ? "" : "s")\(durSuffix)"
            case .trashSucceeded(let ids, let durationMs):
                eventName = "trash.ok"
                glyph = "checkmark"
                severity = .ok
                let durSuffix = formatDurationSuffix(durationMs)
                message = "\(ids.count) asset\(ids.count == 1 ? "" : "s") moved to Immich's Trash\(durSuffix)"
            case .trashFailed(let ids, let msg, let httpStatus):
                eventName = "trash.fail"
                glyph = "xmark.octagon"
                severity = .error
                // HTTP status leads when known — `[401]` flags an auth
                // problem at a glance, vs. a transport error which has
                // no status. The full `msg` follows so the user still
                // sees the underlying detail.
                let httpPrefix = httpStatus.map { "[\($0)] " } ?? ""
                message = "\(ids.count) asset\(ids.count == 1 ? "" : "s") — \(httpPrefix)\(msg.prefix(60))"
            case .runCompleted(let n):
                eventName = "run.complete"
                glyph = "checkmark"
                severity = .ok
                message = "trashed=\(n)"
            case .runAborted(let reason):
                eventName = "run.abort"
                glyph = "exclamationmark.triangle"
                severity = .error
                message = summarizeAbortReason(reason)
            case .restoreStarted(let runId, let ids):
                eventName = "restore.start"
                glyph = "arrow.uturn.backward"
                severity = .info
                message = "\(ids.count) asset\(ids.count == 1 ? "" : "s") from \(runId.suffix(8))"
            case .restoreSucceeded(_, let ids, let durationMs):
                eventName = "restore.ok"
                glyph = "checkmark"
                severity = .ok
                let durSuffix = formatDurationSuffix(durationMs)
                message = "\(ids.count) asset\(ids.count == 1 ? "" : "s") restored\(durSuffix)"
            case .restoreFailed(_, let ids, let msg, let httpStatus):
                eventName = "restore.fail"
                glyph = "xmark.octagon"
                severity = .error
                let httpPrefix = httpStatus.map { "[\($0)] " } ?? ""
                message = "\(ids.count) — \(httpPrefix)\(msg.prefix(60))"
            case .assetsExcluded(let cks, _):
                eventName = "exclude.add"
                glyph = "shield.lefthalf.filled"
                severity = .ok
                message = "\(cks.count) checksum\(cks.count == 1 ? "" : "s")"
            case .pendingReview(let ids, _):
                eventName = "pending.hold"
                glyph = "clock.arrow.circlepath"
                severity = .warn
                message = "\(ids.count) asset\(ids.count == 1 ? "" : "s") awaiting review"
            case .syncStarted(let trigger):
                eventName = "sync.start"
                glyph = "arrow.triangle.2.circlepath"
                severity = .info
                // Routine: foreground/manual triggers don't add much
                // forensic value vs the syncCompleted that follows.
                // Background and Shortcut triggers ARE the signal the
                // user is looking for ("did BG actually run?"), so
                // those stay non-routine and surface in the filtered
                // tail by default.
                routine = (trigger == .manualForeground || trigger == .unknown)
                message = "triggered by \(trigger.displayName.lowercased())"
            case .syncCompleted(let indexed, let candidates, let pending, let large, let largeBytes, let timeout, let elapsedMs):
                eventName = "sync"
                glyph = "arrow.triangle.2.circlepath"
                severity = .info
                // The "no signal at all" pattern — every sync field is
                // zero. Filter chip on Status hides these so the tail
                // reflects real activity rather than every hourly
                // background poke.
                routine = (candidates == 0 && pending == 0 && large == 0 && timeout == 0)
                // Inline deltas for the three running totals (indexed /
                // candidates / pending) when a chronological prior sync
                // is in scope. Skip on first-ever sync (prev=nil) and
                // when the delta is zero — `(±0)` is noise.
                func deltaSuffix(_ now: Int, _ prev: Int?) -> String {
                    guard let prev, now != prev else { return "" }
                    let d = now - prev
                    return d > 0 ? " (+\(d))" : " (\(d))" // negatives already render with leading "-"
                }
                let dIdx = deltaSuffix(indexed, previousSyncCounts?.indexed)
                let dCand = deltaSuffix(candidates, previousSyncCounts?.candidates)
                let dPend = deltaSuffix(pending, previousSyncCounts?.pending)
                var parts: [String] = [
                    "indexed=\(indexed)\(dIdx)",
                    "cand=\(candidates)\(dCand)",
                ]
                if pending > 0 { parts.append("pending=\(pending)\(dPend)") }
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
            case .syncTransitions(let editsProtected, let editsQuarantined, let confirmedPK, let confirmedOrphan):
                eventName = "sync.trans"
                glyph = "arrow.triangle.branch"
                // Severity bumps to .warn when the orphan safety net
                // catches anything — that means PhotoKit's primary
                // deletion signal missed something, which is a worth-
                // flagging event for forensics. Otherwise routine.
                severity = confirmedOrphan > 0 ? .warn : .info
                var parts: [String] = []
                if editsProtected > 0  { parts.append("edit-prot=\(editsProtected)") }
                if editsQuarantined > 0 { parts.append("edit-q=\(editsQuarantined)") }
                if confirmedPK > 0     { parts.append("conf-pk=\(confirmedPK)") }
                if confirmedOrphan > 0 { parts.append("conf-orph=\(confirmedOrphan)") }
                message = parts.isEmpty ? "no transitions" : parts.joined(separator: " · ")
            }
            return JournalTailEntry(
                time: time,
                event: eventName,
                message: message,
                glyph: glyph,
                runIdSuffix: String(entry.runId.suffix(8)),
                isRoutineSync: routine,
                runId: entry.runId,
                severity: severity,
                rawJSON: encodeRawJSON(entry)
            )
        }

        /// Batch builder: walks `entries` chronologically (oldest →
        /// newest), wiring the previous `syncCompleted` counts forward
        /// into the next sync row so deltas can render. Use this from
        /// real-data call sites instead of `entries.map(.from)` —
        /// otherwise sync rows can't show `(+5)`-style deltas because
        /// `from(_:)` alone has no chronological context.
        ///
        /// Caller is responsible for any final ordering (e.g. reversing
        /// for newest-first display); this preserves input order.
        public static func from(entries: [JournalEntry]) -> [JournalTailEntry] {
            var out: [JournalTailEntry] = []
            out.reserveCapacity(entries.count)
            var prevSync: SyncCounts? = nil
            for entry in entries {
                out.append(.from(entry, previousSyncCounts: prevSync))
                if case .syncCompleted(let i, let c, let p, _, _, _, _) = entry.event {
                    prevSync = SyncCounts(indexed: i, candidates: c, pending: p)
                }
            }
            return out
        }

        /// `· 1.4s` / `· 320ms` clause appended to success-event
        /// messages when the underlying journal row carries a
        /// `durationMs`. Renders nothing for legacy rows where the
        /// field is nil.
        private static func formatDurationSuffix(_ durationMs: Int?) -> String {
            guard let ms = durationMs else { return "" }
            if ms < 1000 {
                return " · \(ms)ms"
            } else {
                return " · \(String(format: "%.1fs", Double(ms) / 1000))"
            }
        }

        /// Pretty-printed JSON for the long-press raw-event sheet.
        /// Encoder errors collapse to `nil` (the row still renders; just
        /// no JSON to inspect) — better than throwing from `from(_:)`.
        private static func encodeRawJSON(_ entry: JournalEntry) -> String? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(entry),
                  let str = String(data: data, encoding: .utf8) else {
                return nil
            }
            return str
        }

        /// Thin delegate so the journal-tail format matches the
        /// `[cairn.hash]` log lines exactly (no space between number
        /// and unit).
        private static func formatBytes(_ bytes: Int64) -> String {
            CairnTimeHelpers.formatBytesCompact(bytes)
        }

        /// Single-line summary of `SafetyRails.AbortReason.description`.
        /// The full description carries the code-name and the long
        /// human-readable clause; the journal-tail row only has room
        /// for one line, so trim aggressively. Public so tests pin
        /// the mapping case-by-case.
        public static func summarizeAbortReason(_ reason: String) -> String {
            // `thresholdExceeded — would delete 12 of 1024 in-purview assets (1.17%); limit is 1.00%`
            // Numbers are load-bearing; pull them out via straight
            // contains-checks on the leading code-name. No regex
            // needed beyond simple split + scan.
            if reason.hasPrefix("thresholdExceeded") {
                // Best-effort extract: "would delete N of … (P%); limit is L%"
                if let candidates = scanInt(after: "would delete ", in: reason),
                   let percent = scanDouble(before: "%);", in: reason),
                   let limit = scanDouble(after: "limit is ", trailing: "%", in: reason) {
                    return String(
                        format: "safety rail (%d / %.2f%% > %.2f%% cap)",
                        candidates, percent, limit
                    )
                }
                return "safety rail tripped"
            }
            if reason.hasPrefix("emptyServerResponse") {
                return "server returned 0 assets"
            }
            if reason.hasPrefix("emptyLocalLibrary") {
                return "local library empty (Photos permission?)"
            }
            if reason.hasPrefix("firstRunNotDryRun") {
                return "first run must be dry-run"
            }
            return String(reason.prefix(60))
        }

        /// Scan an integer that begins immediately after `prefix`.
        private static func scanInt(after prefix: String, in s: String) -> Int? {
            guard let r = s.range(of: prefix) else { return nil }
            let tail = s[r.upperBound...]
            let digits = tail.prefix(while: { $0.isNumber })
            return Int(digits)
        }

        /// Scan a double sitting between two delimiters: starts after
        /// `after` (default "(") and ends at `trailing` (default "%").
        /// Returns the parsed value or nil on first miss.
        private static func scanDouble(after prefix: String = "(", trailing: String = "%", in s: String) -> Double? {
            guard let r = s.range(of: prefix) else { return nil }
            let tail = s[r.upperBound...]
            let body = tail.prefix(while: { $0.isNumber || $0 == "." })
            return Double(body)
        }

        /// Scan a double that ends just before a delimiter substring.
        /// Used for the percent-before-`%);` case where a forward
        /// scan would also match the `%` in `1.00%`.
        private static func scanDouble(before suffix: String, in s: String) -> Double? {
            guard let r = s.range(of: suffix) else { return nil }
            // Walk backward from the suffix consuming digits/dot.
            let end = r.lowerBound
            var start = end
            while start > s.startIndex {
                let prev = s.index(before: start)
                let ch = s[prev]
                if ch.isNumber || ch == "." {
                    start = prev
                } else {
                    break
                }
            }
            return Double(s[start..<end])
        }

        /// Compact, relative-aware time. Today → `HH:mm` (no seconds,
        /// no millis). Different day → `MMM d HH:mm`. Replaces the
        /// previous always-on `MM/dd · HH:mm:ss.SSS` format — the
        /// dropped column width frees room for the runId suffix.
        public static func formatTime(_ date: Date, now: Date = Date()) -> String {
            let cal = Calendar.current
            if cal.isDate(date, inSameDayAs: now) {
                return Self.todayFormatter.string(from: date)
            }
            return Self.otherDayFormatter.string(from: date)
        }

        /// `17:57` — same-day events. Dropped seconds + millis: a few
        /// adjacent rows might share a clock minute, but the runId
        /// suffix column already disambiguates, and the full-precision
        /// timestamp is in the on-disk journal for forensic use.
        private static let todayFormatter: DateFormatter = {
            let df = DateFormatter()
            df.dateFormat = "HH:mm"
            df.locale = Locale(identifier: "en_US_POSIX")
            return df
        }()

        /// `Apr 22 17:57` — past-day events. No middle-dot separator
        /// and no seconds, so the column stays narrow.
        private static let otherDayFormatter: DateFormatter = {
            let df = DateFormatter()
            df.dateFormat = "MMM d HH:mm"
            df.locale = Locale(identifier: "en_US_POSIX")
            return df
        }()
    }

    /// Newest-first (matches how the runtime model populates
    /// `CairnAppModel.journalTail` from `DeletionJournal.lastEntries`).
    /// Uses the post-Wave-4 event-name set (`run.complete`, `tag.apply`,
    /// `trash.ok`, `run.start`) and the compact relative-aware time
    /// format. Glyphs and runIdSuffix mirror what `from(_:)` would
    /// emit for equivalent journal entries.
    public static let journalTail: [JournalTailEntry] = [
        .init(time: "17:57", event: "run.complete", message: "trashed=14",
              glyph: "checkmark", runIdSuffix: "034389BC", runId: "2026-04-21T17:57:15Z-034389BC"),
        .init(time: "17:57", event: "trash.ok",    message: "14 assets moved to Immich's Trash",
              glyph: "checkmark", runIdSuffix: "034389BC", runId: "2026-04-21T17:57:15Z-034389BC"),
        .init(time: "17:57", event: "tag.apply",   message: "…21Z-034389BC → 14 assets",
              glyph: "tag", runIdSuffix: "034389BC", runId: "2026-04-21T17:57:15Z-034389BC"),
        .init(time: "17:57", event: "plan.trash",  message: "14 assets",
              glyph: "list.bullet", runIdSuffix: "034389BC", runId: "2026-04-21T17:57:15Z-034389BC"),
        .init(time: "17:57", event: "run.start",   message: "live · 14 candidates",
              glyph: "play.circle", runIdSuffix: "034389BC", runId: "2026-04-21T17:57:15Z-034389BC"),
        .init(time: "17:55", event: "sync",        message: "indexed=4189 · cand=14 · dur=1.32s",
              glyph: "arrow.triangle.2.circlepath", runIdSuffix: "sync5512", runId: "2026-04-21T17:55:00Z-sync5512"),
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
