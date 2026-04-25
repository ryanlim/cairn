import Foundation

/// Immich's content-addressing primitive. `base64` holds a base64-encoded
/// SHA1 over the file's bytes — Immich exposes it as
/// `AssetResponseDto.checksum` and rejects any other algorithm (see
/// `server/src/enum.ts:44` in the Immich source). Every identity
/// decision cairn makes is keyed on this value; filenames, UUIDs, and
/// device IDs are all untrustworthy by comparison.
public struct Checksum: Hashable, Sendable, Codable, CustomStringConvertible {
    public let base64: String

    public init(base64: String) {
        self.base64 = base64
    }

    public var description: String { base64 }
}

/// One asset as the Immich server presents it. `id` is the server's
/// UUID (stable across renames); `checksum` is the identity carriers
/// rely on. `livePhotoVideoId` is the UUID of the paired motion video
/// when this asset is a Live Photo still — the server does **not**
/// cascade trash through that link, so `TrashOrchestrator` has to
/// include paired IDs in every delete batch explicitly.
public struct ServerAsset: Hashable, Sendable, Codable {
    public let id: String
    public let checksum: Checksum
    public let livePhotoVideoId: String?
    public let isTrashed: Bool
    public let originalFileName: String?
    /// When Immich recorded the asset's original `fileCreatedAt`.
    /// Optional because the field isn't universally populated on
    /// every Immich version's list endpoint; when present, flows
    /// into `TrashTarget` so run-detail rows show real dates.
    public let fileCreatedAt: Date?
    /// Base64-encoded thumbhash from the Immich API. Decodes to a
    /// small (~4×4) blurry placeholder image. ~28 bytes raw.
    public let thumbhash: String?

    public init(
        id: String,
        checksum: Checksum,
        livePhotoVideoId: String? = nil,
        isTrashed: Bool = false,
        originalFileName: String? = nil,
        fileCreatedAt: Date? = nil,
        thumbhash: String? = nil
    ) {
        self.id = id
        self.checksum = checksum
        self.livePhotoVideoId = livePhotoVideoId
        self.isTrashed = isTrashed
        self.originalFileName = originalFileName
        self.fileCreatedAt = fileCreatedAt
        self.thumbhash = thumbhash
    }
}

/// Mirrors Immich's `AssetVisibility` enum (`server/src/enum.ts:934`). The
/// `hidden` case is the one we care about for Live Photos: motion videos are
/// stored as `hidden` so they don't clutter the timeline. `search/metadata`
/// excludes hidden assets by default — pass an explicit value to override.
public enum AssetVisibility: String, Sendable, Codable, CaseIterable {
    case archive
    case timeline
    case hidden
    case locked
}

/// Opaque identifier for one trash-run's lifetime. Flows into the
/// journal, the server-side breadcrumb tag (`cairn/v1/run/<value>`),
/// and the restore CLI. Default init generates a fresh UUID; pass an
/// explicit value to reconstruct a prior run's identity.
public struct RunID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let value: String

    public init(value: String = UUID().uuidString) {
        self.value = value
    }

    public var description: String { value }
}
