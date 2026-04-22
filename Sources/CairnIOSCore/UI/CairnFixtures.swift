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

        public enum Status: Sendable { case complete, aborted }
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

        public enum Kind: Sendable { case photo, video, livePair }
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

    public struct JournalTailEntry: Sendable, Identifiable {
        public var id: String { time + event }
        public let time: String
        public let event: String
        public let message: String
    }

    public static let journalTail: [JournalTailEntry] = [
        .init(time: "17:57:15.102", event: "run.start",    message: "run_id=2026-04-21T17:57:15Z-034389BC"),
        .init(time: "17:57:15.240", event: "server.pull",  message: "fetched 1204 assets in 138ms"),
        .init(time: "17:57:15.312", event: "reconcile",    message: "14 candidates · 0.66% of matched (4102)"),
        .init(time: "17:57:15.318", event: "safety.ok",    message: "percent 0.66 ≤ 1.00 cap · floor 5 met"),
        .init(time: "17:57:15.402", event: "tag.create",   message: "cairn/v1/run/…"),
        .init(time: "17:57:15.604", event: "tag.attach",   message: "attached 14 assets to breadcrumb tag"),
        .init(time: "17:57:15.790", event: "delete.batch", message: "DELETE /api/assets · 14 ids · force=false"),
        .init(time: "17:57:19.325", event: "run.complete", message: "trashed=14 failed=0 dur=4.21s"),
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
        if b < 1024 { return "\(b) B" }
        let kb = Double(b) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }
}
