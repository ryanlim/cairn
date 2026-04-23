import Foundation

/// Abstracts the local-photo-library queries the reconciliation pipeline
/// needs.
///
/// On iOS this is backed by PhotoKit: `PHAsset.fetchAssets` for the full
/// enumeration, `PHAssetResource` + `CryptoKit.Insecure.SHA1` for hashing.
/// The positive-deletion signal lives above this protocol in iOS-specific
/// code (`fetchPersistentChanges(since:)` → `ConfirmedDeletedStore.union`)
/// because the `localIdentifier` ↔ `Checksum` mapping PhotoKit requires is
/// a platform concern, not part of the portable core.
///
/// In the CLI, implementations read pre-computed checksum files (one base64
/// SHA1 per line), which stubs the iPhone for algorithm validation without
/// needing a device in the loop.
public protocol PhotoEnumerator: Sendable {
    /// The full set of SHA1 checksums for every locally-available asset.
    /// On iOS this may take seconds to minutes on a large library; callers
    /// should show progress UI.
    func currentChecksums() async throws -> Set<Checksum>
}

/// CLI-friendly implementation that reads a file of base64 SHA1 strings,
/// one per line. Blank lines and lines beginning with `#` are ignored.
public struct ChecksumFilePhotoEnumerator: PhotoEnumerator {
    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    public init(filePath: String) {
        self.path = URL(fileURLWithPath: filePath)
    }

    public func currentChecksums() async throws -> Set<Checksum> {
        try Self.readChecksumFile(at: path)
    }

    private static func readChecksumFile(at url: URL) throws -> Set<Checksum> {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let values = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return Set(values.map { Checksum(base64: $0) })
    }
}
