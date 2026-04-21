import Foundation

/// Abstracts "give me every checksum currently in the local photo library."
///
/// On iOS (Phase 2) this will be backed by PhotoKit — `PHAsset.fetchAssets`
/// to enumerate, `PHAssetResource` + `CryptoKit.Insecure.SHA1` to hash each
/// asset's bytes. For Live Photos it returns checksums for both the still
/// and the paired motion video.
///
/// In the CLI, implementations read a file of pre-computed checksums (one
/// base64 SHA1 per line), which stubs the iPhone for algorithm validation
/// without needing a device in the loop.
public protocol PhotoEnumerator: Sendable {
    /// The full set of SHA1 checksums for every locally-available asset.
    /// Blocking call (async-friendly) — on iOS this may take seconds to
    /// minutes on a large library; callers should show progress UI.
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
        let raw = try String(contentsOf: path, encoding: .utf8)
        let values = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return Set(values.map { Checksum(base64: $0) })
    }
}
