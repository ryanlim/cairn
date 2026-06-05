import Foundation

/// Lightweight metadata captured at PhotoKit insert/update time —
/// well before the asset is hashed. The point is to record everything
/// we'd need to *correlate against the server* in case the asset is
/// deleted before cairn finishes (or even starts) hashing it.
///
/// Concrete scenario: user takes a photo, Immich uploads it, user
/// deletes it. cairn runs after all of that. The persistent-change log
/// emits insert + delete events for the same identifier. By the time
/// cairn looks, the asset is gone — `PHAsset.fetchAssets(withLocalIdentifiers:)`
/// returns empty, hashing is impossible. But if we recorded the
/// filename + creation date when we first saw the insert event, we can
/// still find the matching server asset (Immich tracks `originalFileName`
/// and `fileCreatedAt`) and propagate the deletion.
///
/// Storage shape: keyed by `localIdentifier`, value is the captured
/// metadata. Entries are tiny (~100 bytes); the whole store is bounded
/// by library size.
public struct LocalAssetMetadata: Sendable, Equatable, Codable {
    public let localIdentifier: String
    public let originalFileName: String?
    public let creationDate: Date?
    public let modificationDate: Date?
    public let fileSize: Int64?
    /// When cairn first observed (recorded) this metadata — distinct
    /// from `creationDate` which is the camera/EXIF capture time.
    public let observedAt: Date
    /// Every `originalFilename` from every `PHAssetResource` attached
    /// to the asset, in enumeration order. For unedited assets this
    /// is one or two entries (still + paired video for Live Photos);
    /// for assets that have been edited via Photos.app it grows to
    /// include the rendered edit (`FullSizeRender.mov`,
    /// `FullSizeRender.jpeg`), an `Adjustments.plist` sidecar, and
    /// any other resource cairn observed at capture time.
    ///
    /// **Why this exists separate from `originalFileName`.** For
    /// edited assets PhotoKit replaces the PHAsset's KVC `filename`
    /// with a UUID-style placeholder, and the resource picker
    /// `PhotoKitPhotoEnumerator.selectPrimaryResource(...)` returns
    /// the rendered version's filename (e.g. `FullSizeRender.mov`).
    /// Immich's server entry usually still has the *original* upload
    /// filename (`IMG_1234.MOV`), because the asset was uploaded
    /// before the edit. The engine's alive-on-phone safety check
    /// needs every candidate filename available — primary alone
    /// misses the edited-asset case entirely. End-user-confirmed
    /// report at build 120 showed exactly this shape: phone KVC was
    /// `80EE02BF-...MOV`, primary resource was `FullSizeRender.mov`,
    /// and the still-on-server filename was `IMG_2999.MOV` from the
    /// pre-edit upload.
    ///
    /// Defaulted to `[]` for migration safety. Existing rows decode
    /// as "no extras known" and the alive-key build falls back to
    /// its other sources.
    public let allResourceFilenames: [String]

    public init(
        localIdentifier: String,
        originalFileName: String?,
        creationDate: Date?,
        modificationDate: Date?,
        fileSize: Int64?,
        observedAt: Date,
        allResourceFilenames: [String] = []
    ) {
        self.localIdentifier = localIdentifier
        self.originalFileName = originalFileName
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.fileSize = fileSize
        self.observedAt = observedAt
        self.allResourceFilenames = allResourceFilenames
    }

    // Custom decoder so older JSON payloads that didn't have the
    // field decode cleanly with an empty array default.
    private enum CodingKeys: String, CodingKey {
        case localIdentifier, originalFileName, creationDate
        case modificationDate, fileSize, observedAt
        case allResourceFilenames
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.localIdentifier = try c.decode(String.self, forKey: .localIdentifier)
        self.originalFileName = try c.decodeIfPresent(String.self, forKey: .originalFileName)
        self.creationDate = try c.decodeIfPresent(Date.self, forKey: .creationDate)
        self.modificationDate = try c.decodeIfPresent(Date.self, forKey: .modificationDate)
        self.fileSize = try c.decodeIfPresent(Int64.self, forKey: .fileSize)
        self.observedAt = try c.decode(Date.self, forKey: .observedAt)
        self.allResourceFilenames = try c.decodeIfPresent([String].self, forKey: .allResourceFilenames) ?? []
    }
}

/// Records metadata at PhotoKit observation time so the deletion-
/// correlation path can fall back to filename + date matching when no
/// SHA1 is available for a deleted asset.
public protocol LocalAssetMetadataStore: Sendable {
    /// Read metadata for a specific identifier. `nil` when unknown.
    func metadata(for localIdentifier: String) async throws -> LocalAssetMetadata?

    /// Insert or replace metadata for an identifier. Idempotent.
    func record(_ entry: LocalAssetMetadata) async throws

    /// Bulk insert/replace. Same semantics as `record` but cheaper for
    /// batches (single transaction).
    func record(_ entries: [LocalAssetMetadata]) async throws

    /// Drop entries for the given identifiers. Used when the orphan
    /// reconciliation has matched an entry against the server and the
    /// deletion has been propagated — no point keeping it around.
    func remove(_ localIdentifiers: Set<String>) async throws

    /// Full snapshot. Used by `OrphanReconciler.match` to correlate
    /// every observed-but-unhashed asset against the server's view of
    /// the world. Implementations should be cheap relative to library
    /// size (typically tens to low hundreds of entries — anything we
    /// observed but couldn't hash, plus some recent successes that
    /// haven't been swept yet).
    func snapshot() async throws -> [LocalAssetMetadata]

    /// Wipe the store. Paired with `LocalHashStore.clear()` from the
    /// "rescan" / "reset index" actions.
    func clear() async throws
}

public extension LocalAssetMetadataStore {
    func record(_ entry: LocalAssetMetadata) async throws {
        try await record([entry])
    }
}
