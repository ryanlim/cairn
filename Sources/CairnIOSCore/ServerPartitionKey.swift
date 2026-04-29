import Foundation

/// The discriminator that picks which on-disk directory cairn's per-server
/// state lives in. Originally URL-only; now also carries the Immich
/// `userId` so multiple accounts on the same server URL get isolated
/// state on the same device.
///
/// Backward compatibility: when initialized with `userId: nil`, the
/// `directoryName` matches the pre-userId-partitioning shape exactly.
/// This is intentional — bootstrap uses the URL-only key to detect
/// pre-migration directories and rename them in place.
public struct ServerPartitionKey: Sendable, Equatable, Hashable, Codable {
    public let directoryName: String
    public let normalizedURL: String
    /// The Immich user UUID this partition is for. `nil` for legacy /
    /// pre-userId partitions; cairn migrates these in-place at bootstrap
    /// once the userId is fetched.
    public let userId: String?

    public init(from url: URL, userId: String? = nil) {
        let normalized = Self.normalizeForPartition(url)
        self.normalizedURL = normalized
        self.userId = userId
        self.directoryName = Self.sanitize(normalized, userId: userId)
    }

    static func normalizeForPartition(_ url: URL) -> String {
        var components = URLComponents()
        components.scheme = (url.scheme ?? "https").lowercased()
        components.host = url.host(percentEncoded: false)?.lowercased()
        if let port = url.port, !Self.isDefaultPort(port, scheme: components.scheme ?? "https") {
            components.port = port
        }
        return components.string ?? url.absoluteString.lowercased()
    }

    static func sanitize(_ normalized: String, userId: String? = nil) -> String {
        var result = normalized
        result = result.replacingOccurrences(of: "://", with: "_")
        result = result.replacingOccurrences(of: ":", with: "_")
        result = result.replacingOccurrences(of: "/", with: "")
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if result.isEmpty { result = "unknown" }
        // Append a sanitized userId when present. Use a `__` separator
        // (double underscore) so we can unambiguously parse legacy
        // (URL-only) vs new (URL__user) directory names later if needed.
        // Sanitize the userId with the same character class as the URL
        // portion — Immich user UUIDs use hex + dashes, both filesystem-
        // safe; this guards against future Immich changes.
        if let userId, !userId.isEmpty {
            let safeId = sanitizeUserId(userId)
            result = "\(result)__\(safeId)"
        }
        return result
    }

    private static func sanitizeUserId(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var out = ""
        for scalar in raw.unicodeScalars {
            if allowed.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                out.append("_")
            }
        }
        return out.isEmpty ? "unknown" : out
    }

    private static func isDefaultPort(_ port: Int, scheme: String) -> Bool {
        (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
    }
}
