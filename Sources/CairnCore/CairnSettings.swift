import Foundation

/// User-tunable configuration the iOS app (and CLI) persists between runs.
///
/// Intentionally excludes secrets (server URL, API key) — those have a
/// different security story and live in `SecretStore`, backed by Keychain
/// on iOS. Also excludes iOS-only concepts (Photos permission state,
/// Background Refresh state) which belong in the iOS target — `CairnCore`
/// stays pure Foundation + CryptoKit so the Kotlin port stays tractable.
///
/// Every field has a sensible default; a fresh install should be safe
/// without the user touching settings. See the plan doc's "Safety rails"
/// section for the rationale behind these specific defaults.
public struct CairnSettings: Sendable, Codable, Equatable {
    /// Abort a run if it would trash more than this percent of matched
    /// assets. 1.0 means 1%. Defense against a bug, permission regression,
    /// or library-wipe event cascading into a mass delete on the server.
    public var maxDeletePercent: Double

    /// Floor below which the percent rail is bypassed — on a small library
    /// (say 200 photos) 1% is 2 photos, which is noise. This sets the
    /// minimum run size that triggers the threshold check.
    public var minDeleteFloor: Int

    /// Local notification when a safety rail trips and a run is aborted.
    /// Default on — silently skipping a destructive-intent run that the
    /// user opted into is worse than one extra notification.
    public var notifyOnAbort: Bool

    /// Whether the journal records every API request or just headline
    /// events. Off by default because verbose journals grow quickly and
    /// can leak checksums into support bundles users share.
    public var verboseLogging: Bool

    /// How aggressively cairn acts on deletion candidates. See the plan
    /// doc's "Confirmed-deletion signal (Wave 4)" section for the full
    /// rationale.
    public var deletionStrictness: DeletionStrictness

    /// Number of days a confirmed-deleted checksum must age before it
    /// becomes eligible to trash. Gives the user a grace period to catch
    /// and recover from an accidental mass-offload before the server-side
    /// delete fires. Values outside `Self.quarantineDaysRange` are tolerated
    /// on decode (legacy files and manual edits round-trip unchanged); UI
    /// surfaces should clamp on write.
    public var quarantineDays: Int

    /// Permitted range for `quarantineDays`. `0` opts out (the held bucket
    /// is always empty). `90` caps cautious users at three months — long
    /// enough to recover from real mistakes, short enough to bound store
    /// growth and keep pending-review queues manageable.
    public static let quarantineDaysRange: ClosedRange<Int> = 0...90

    /// Per-asset iCloud-download soft limit (in megabytes) that the
    /// foreground hashing pipeline will accept. Assets whose combined
    /// unavailable-resource size exceeds this are **deferred**: queued
    /// into `DeferredHashStore` and drained later — a small batch on
    /// each subsequent incremental scan, or the whole queue during a
    /// `BGProcessingTask` slot (which ignores this soft limit entirely).
    ///
    /// Rationale: on iCloud-optimized libraries, large videos can take
    /// minutes each to fetch-then-hash. Without a limit, a first scan
    /// can stall for hours on a handful of multi-hundred-MB clips.
    /// Smaller values ship more work into the background bucket and
    /// make the foreground experience faster; larger values hash more
    /// on-demand but at the cost of responsiveness.
    public var iCloudDownloadLimitMB: Int

    /// Permitted range for `iCloudDownloadLimitMB`. `5` MB knocks out
    /// essentially every video and Live Photo motion track from the
    /// initial pass — aggressive. `500` MB lets almost everything
    /// through, approximating uncapped. Default `100` is a compromise
    /// that lets most short clips hash on the first pass while keeping
    /// multi-hundred-MB/GB videos in the background-drain bucket.
    public static let iCloudDownloadLimitMBRange: ClosedRange<Int> = 5...500

    /// Optional hard never-touch ceiling (in megabytes). Assets whose
    /// iCloud-download size exceeds this are **never hashed**, by any
    /// path — not foreground, not background. They're effectively
    /// out-of-scope for cairn: no checksum, not entered into
    /// `ObservedStore`, not added to `DeferredHashStore`. A consequence
    /// is that if the user later deletes them from iPhone, cairn won't
    /// propagate the deletion to Immich (because the checksum was never
    /// in `observed`). Use this for multi-GB iCloud-archived videos you
    /// want cairn to ignore entirely.
    ///
    /// `nil` = off (no hard ceiling, default). Values outside
    /// `iCloudMaxEverBytesMBRange` are tolerated on decode but should
    /// be clamped on write by the UI.
    public var iCloudMaxEverBytesMB: Int?

    /// Override for the system color scheme. Default is `.system` (follow
    /// iOS Settings). Users who prefer a fixed appearance — or who find
    /// one scheme more readable — can pin `.light` or `.dark` here.
    public var appearance: AppearanceOverride

    /// Surface a prominent Status banner when the total deletion
    /// backlog (held-by-quarantine + pending-review + eligible-to-
    /// trash) reaches this count. 0 disables the banner entirely.
    /// The existing pending-candidates card on Status surfaces the
    /// count regardless; this threshold is the escalation signal
    /// for "you've accumulated a lot — come take a look."
    public var deletionBacklogAlertThreshold: Int

    /// Max disk space for cached full-resolution thumbnails (per server).
    /// FIFO eviction when exceeded. Default 100 MB.
    public var thumbnailCacheCapMB: Int

    /// Max disk space for thumbhash placeholders (per server). Default 5 MB.
    /// ~180K assets at 28 bytes each — a safety net, not a practical limit.
    public var thumbhashCapMB: Int

    public static let thumbnailCacheCapMBRange: ClosedRange<Int> = 10...500
    public static let thumbhashCapMBRange: ClosedRange<Int> = 1...20

    /// Permitted range for `deletionBacklogAlertThreshold`. 0 opts
    /// out; 500 caps a truly noise-tolerant user. Count-based (not
    /// percent) so behavior doesn't drift with library size —
    /// percent-based safety exists separately on the trash run rail.
    public static let deletionBacklogAlertThresholdRange: ClosedRange<Int> = 0...500

    /// Permitted range for `iCloudMaxEverBytesMB` when set. `50` MB is
    /// below the default soft-limit so a sensible UI clamps it above
    /// that; `10240` MB (10 GB) is an aggressive upper bound covering
    /// essentially every personal-library case. Callers should clamp
    /// on write.
    public static let iCloudMaxEverBytesMBRange: ClosedRange<Int> = 50...10_240

    /// Which slice of the user's Photos library cairn manages. Default
    /// `.fullLibrary` matches the original behavior (every visible asset
    /// in the user library is in scope). `.selectedAlbums` restricts
    /// cairn's view to a hand-picked set of Photos albums (identified
    /// by `PHAssetCollection.localIdentifier`); photos outside those
    /// albums are silently ignored — never hashed, never proposed for
    /// trash, never enter the Observed / Confirmed flow until they're
    /// added to a selected album.
    public var indexingScope: IndexingScope

    /// How many times the retry driver will re-attempt a failed trash
    /// before parking the intent. Once this cap is hit, the intent stays
    /// in the queue (still visible to the user, still drainable on a
    /// manual "Retry now" tap) but the driver stops touching it
    /// automatically — a transient-looking failure that's actually a
    /// real, persistent problem (wrong API key, dead server) shouldn't
    /// flap forever. Default 5; clamped to `maxRetryAttemptsRange`.
    public var maxRetryAttempts: Int

    /// Permitted range for `maxRetryAttempts`. `1` means "one shot, then
    /// park" — basically opts out of automatic retry. `20` is generous
    /// for users on flaky home networks. Default `5` is a balance.
    public static let maxRetryAttemptsRange: ClosedRange<Int> = 1...20

    public init(
        maxDeletePercent: Double = 1.0,
        minDeleteFloor: Int = 5,
        notifyOnAbort: Bool = true,
        verboseLogging: Bool = false,
        deletionStrictness: DeletionStrictness = .trusting,
        quarantineDays: Int = 14,
        iCloudDownloadLimitMB: Int = 100,
        iCloudMaxEverBytesMB: Int? = nil,
        appearance: AppearanceOverride = .system,
        deletionBacklogAlertThreshold: Int = 25,
        thumbnailCacheCapMB: Int = 100,
        thumbhashCapMB: Int = 5,
        indexingScope: IndexingScope = .fullLibrary,
        maxRetryAttempts: Int = 5
    ) {
        self.maxDeletePercent = maxDeletePercent
        self.minDeleteFloor = minDeleteFloor
        self.notifyOnAbort = notifyOnAbort
        self.verboseLogging = verboseLogging
        self.deletionStrictness = deletionStrictness
        self.quarantineDays = quarantineDays
        self.iCloudDownloadLimitMB = iCloudDownloadLimitMB
        self.iCloudMaxEverBytesMB = iCloudMaxEverBytesMB
        self.appearance = appearance
        self.deletionBacklogAlertThreshold = deletionBacklogAlertThreshold
        self.thumbnailCacheCapMB = thumbnailCacheCapMB
        self.thumbhashCapMB = thumbhashCapMB
        self.indexingScope = indexingScope
        self.maxRetryAttempts = maxRetryAttempts
    }

    /// The factory defaults. Kept as a single constant so tests and the
    /// "reset to defaults" UI path reference the same source of truth.
    public static let defaults: CairnSettings = CairnSettings()

    // Custom Codable so legacy payloads (written before newer fields
    // existed) decode cleanly: missing keys fall back to the current
    // default, matching how a fresh install would experience them.
    private enum CodingKeys: String, CodingKey {
        case maxDeletePercent, minDeleteFloor, notifyOnAbort
        case verboseLogging, deletionStrictness, quarantineDays
        case iCloudDownloadLimitMB, iCloudMaxEverBytesMB, appearance
        case deletionBacklogAlertThreshold
        case thumbnailCacheCapMB, thumbhashCapMB
        case indexingScope
        case maxRetryAttempts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CairnSettings.defaults
        self.maxDeletePercent = try c.decodeIfPresent(Double.self, forKey: .maxDeletePercent) ?? d.maxDeletePercent
        self.minDeleteFloor = try c.decodeIfPresent(Int.self, forKey: .minDeleteFloor) ?? d.minDeleteFloor
        self.notifyOnAbort = try c.decodeIfPresent(Bool.self, forKey: .notifyOnAbort) ?? d.notifyOnAbort
        self.verboseLogging = try c.decodeIfPresent(Bool.self, forKey: .verboseLogging) ?? d.verboseLogging
        self.deletionStrictness = try c.decodeIfPresent(DeletionStrictness.self, forKey: .deletionStrictness) ?? d.deletionStrictness
        self.quarantineDays = try c.decodeIfPresent(Int.self, forKey: .quarantineDays) ?? d.quarantineDays
        self.iCloudDownloadLimitMB = try c.decodeIfPresent(Int.self, forKey: .iCloudDownloadLimitMB) ?? d.iCloudDownloadLimitMB
        self.iCloudMaxEverBytesMB = try c.decodeIfPresent(Int.self, forKey: .iCloudMaxEverBytesMB) ?? d.iCloudMaxEverBytesMB
        self.appearance = try c.decodeIfPresent(AppearanceOverride.self, forKey: .appearance) ?? d.appearance
        self.deletionBacklogAlertThreshold = try c.decodeIfPresent(Int.self, forKey: .deletionBacklogAlertThreshold) ?? d.deletionBacklogAlertThreshold
        self.thumbnailCacheCapMB = try c.decodeIfPresent(Int.self, forKey: .thumbnailCacheCapMB) ?? d.thumbnailCacheCapMB
        self.thumbhashCapMB = try c.decodeIfPresent(Int.self, forKey: .thumbhashCapMB) ?? d.thumbhashCapMB
        self.indexingScope = try c.decodeIfPresent(IndexingScope.self, forKey: .indexingScope) ?? d.indexingScope
        self.maxRetryAttempts = try c.decodeIfPresent(Int.self, forKey: .maxRetryAttempts) ?? d.maxRetryAttempts
    }
}

/// Which slice of the user's Photos library cairn watches.
///
/// Encoded as a tagged-payload object, e.g.
/// `{"kind":"fullLibrary"}` or
/// `{"kind":"selectedAlbums","albums":["AB12...","CD34..."]}`. The
/// hand-rolled coding keeps the on-disk shape stable and human-readable,
/// and avoids the synthesized `{"selectedAlbums":{"_0":[...]}}` format
/// that ties the JSON to Swift's enum-associated-value internals.
///
/// `albums` is `Set<String>` of `PHAssetCollection.localIdentifier`
/// values. Stable across launches; PhotoKit also returns these values
/// from the picker UI.
public enum IndexingScope: Sendable, Equatable {
    case fullLibrary
    case selectedAlbums(Set<String>)

    /// Convenience: `true` iff a specific album set is being watched.
    public var isRestricted: Bool {
        switch self {
        case .fullLibrary: return false
        case .selectedAlbums: return true
        }
    }

    /// The selected album localIdentifiers when restricted; empty set
    /// when `.fullLibrary`. Useful for callers that just want a flat
    /// collection without unwrapping the enum each time.
    public var albumLocalIdentifiers: Set<String> {
        switch self {
        case .fullLibrary: return []
        case .selectedAlbums(let ids): return ids
        }
    }
}

extension IndexingScope: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, albums
    }

    private enum Kind: String, Codable {
        case fullLibrary, selectedAlbums
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .fullLibrary:
            self = .fullLibrary
        case .selectedAlbums:
            let albums = try c.decodeIfPresent(Set<String>.self, forKey: .albums) ?? []
            self = .selectedAlbums(albums)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fullLibrary:
            try c.encode(Kind.fullLibrary, forKey: .kind)
        case .selectedAlbums(let ids):
            try c.encode(Kind.selectedAlbums, forKey: .kind)
            // Encode as a sorted array for stable JSON; the Swift
            // `Set<String>` decode side accepts any ordering.
            try c.encode(ids.sorted(), forKey: .albums)
        }
    }
}

/// User-facing override for the system color scheme. Serialized as the
/// raw string (`"system"` / `"light"` / `"dark"`) so the on-disk format
/// is stable and human-readable.
public enum AppearanceOverride: String, Sendable, Codable, Equatable, CaseIterable {
    /// Follow iOS Settings → Display & Brightness (the default).
    case system
    /// Force light mode regardless of the system preference.
    case light
    /// Force dark mode regardless of the system preference.
    case dark
}

/// How aggressively cairn translates "no longer in the local library"
/// into "trash on the server."
///
/// `.strict` requires a positive deletion signal — a
/// `PHPhotoLibrary.fetchPersistentChanges` event that named the
/// checksum's `localIdentifier` as deleted — before any candidate is
/// trashed. Diff-discovered candidates that lack the positive signal
/// are held in pending review for manual approval. The right choice
/// for users who want both signals required in parallel.
///
/// `.trusting` skips the positive-signal gate. Any diff-discovered
/// candidate flows through the normal pipeline, gated only by the
/// quarantine window. The default since Wave 4b — quarantine alone
/// gives a large recovery margin without blocking happy-path users
/// behind a "pending review" queue.
public enum DeletionStrictness: String, Sendable, Codable, Equatable, CaseIterable {
    case strict
    case trusting
    case autonomous
}

/// Narrow protocol over settings persistence. The iOS target may back
/// this with a SwiftData-adjacent store or UserDefaults; the CLI uses
/// `JSONFileSettingsStore`. `load()` never errors on "nothing saved yet" —
/// a fresh install gets `.defaults`, not a thrown error the caller has to
/// handle specially on every startup.
public protocol SettingsStore: Sendable {
    func load() async throws -> CairnSettings
    func save(_ settings: CairnSettings) async throws
}

/// Default file-backed implementation: one JSON blob at a fixed path.
/// Writes are atomic (write-to-temp + rename) so an interrupted save
/// can't produce a half-written file that fails to decode on next launch.
/// Missing file is not an error — it yields `.defaults`.
public actor JSONFileSettingsStore: SettingsStore {
    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    public init(filePath: String) {
        self.path = URL(fileURLWithPath: filePath)
    }

    public func load() async throws -> CairnSettings {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return .defaults
        }
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(CairnSettings.self, from: data)
    }

    public func save(_ settings: CairnSettings) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        // `.atomic` is write-to-temp + rename; a crash mid-write leaves
        // the previous good file intact. No merging with prior contents —
        // the struct is the complete state, callers load/mutate/save.
        try data.write(to: path, options: .atomic)
    }
}
