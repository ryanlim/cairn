import CryptoKit
import Foundation

/// SHA1 of file content, base64-encoded — the identity scheme Immich uses on
/// every asset (`AssetResponseDto.checksum`). Both helpers produce a `Checksum`
/// in the exact format the server returns, so equality comparisons are direct.
///
/// SHA1 is hardware-accelerated on all supported Apple silicon via the ARMv8
/// crypto extensions; PhotoKit/file I/O dominates the pipeline, not the hash.
/// `CryptoKit.Insecure.SHA1` is the only API choice — the "Insecure" prefix is
/// a label about cryptographic suitability (collision resistance), not about
/// content addressing, which is what we need.
public enum Hashing {

    /// SHA1 of an in-memory `Data`. Use for small payloads or tests.
    public static func sha1Base64(of data: Data) -> Checksum {
        let digest = Insecure.SHA1.hash(data: data)
        return Checksum(base64: Data(digest).base64EncodedString())
    }

    /// SHA1 of a file, streamed in fixed-size chunks. Constant memory regardless
    /// of file size, so large videos don't risk OOM on a phone.
    public static func sha1Base64(ofFileAt url: URL, bufferSize: Int = 1 << 20) throws -> Checksum {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        while true {
            let chunk = try handle.read(upToCount: bufferSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return Checksum(base64: Data(hasher.finalize()).base64EncodedString())
    }
}
