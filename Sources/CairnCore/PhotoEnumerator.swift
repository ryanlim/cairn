import Foundation

/// Abstracts the local-photo-library queries the reconciliation pipeline
/// needs.
///
/// On iOS, this is backed by PhotoKit — `PHAsset.fetchAssets` to enumerate
/// the main library, plus a `smartAlbumRecentlyDeleted` collection for
/// Recently Deleted. Hashing uses `PHAssetResource` + `CryptoKit.Insecure.SHA1`.
/// For Live Photos `currentChecksums` returns checksums for both the still
/// and the paired motion video; the same applies to `recentlyDeletedChecksums`.
///
/// In the CLI, implementations read pre-computed checksum files (one base64
/// SHA1 per line), which stubs the iPhone for algorithm validation without
/// needing a device in the loop.
public protocol PhotoEnumerator: Sendable {
    /// The full set of SHA1 checksums for every locally-available asset.
    /// Blocking call (async-friendly) — on iOS this may take seconds to
    /// minutes on a large library; callers should show progress UI.
    func currentChecksums() async throws -> Set<Checksum>

    /// The set of SHA1 checksums for assets currently in iOS's "Recently
    /// Deleted" album (or the platform equivalent). Used by the Wave 4
    /// confirmed-deletion signal: a checksum that has been observed here
    /// is positive proof the user explicitly deleted the asset, vs. it
    /// merely vanishing from the main library for sync/storage reasons.
    ///
    /// Default implementation returns an empty set — implementations that
    /// don't have access to a trash concept don't need to provide it.
    /// Callers in `.strict` deletion mode treat an empty set as "nothing
    /// is positively confirmed yet" and route diff-discovered candidates
    /// to pending review.
    func recentlyDeletedChecksums() async throws -> Set<Checksum>
}

extension PhotoEnumerator {
    public func recentlyDeletedChecksums() async throws -> Set<Checksum> { [] }
}

/// CLI-friendly implementation that reads files of base64 SHA1 strings,
/// one per line. Blank lines and lines beginning with `#` are ignored.
/// `recentlyDeletedPath` is optional — when nil, the `recentlyDeletedChecksums`
/// method returns an empty set, mirroring real iOS behavior on a system
/// with no recent deletions.
public struct ChecksumFilePhotoEnumerator: PhotoEnumerator {
    public let path: URL
    public let recentlyDeletedPath: URL?

    public init(path: URL, recentlyDeletedPath: URL? = nil) {
        self.path = path
        self.recentlyDeletedPath = recentlyDeletedPath
    }

    public init(filePath: String, recentlyDeletedFilePath: String? = nil) {
        self.path = URL(fileURLWithPath: filePath)
        self.recentlyDeletedPath = recentlyDeletedFilePath.map(URL.init(fileURLWithPath:))
    }

    public func currentChecksums() async throws -> Set<Checksum> {
        try Self.readChecksumFile(at: path)
    }

    public func recentlyDeletedChecksums() async throws -> Set<Checksum> {
        guard let recentlyDeletedPath else { return [] }
        guard FileManager.default.fileExists(atPath: recentlyDeletedPath.path) else { return [] }
        return try Self.readChecksumFile(at: recentlyDeletedPath)
    }

    private static func readChecksumFile(at url: URL) throws -> Set<Checksum> {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let values = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return Set(values.map { Checksum(base64: $0) })
    }
}
