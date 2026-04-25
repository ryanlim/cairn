import Foundation

public struct ServerPartitionKey: Sendable, Equatable, Hashable, Codable {
    public let directoryName: String
    public let normalizedURL: String

    public init(from url: URL) {
        let normalized = Self.normalizeForPartition(url)
        self.normalizedURL = normalized
        self.directoryName = Self.sanitize(normalized)
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

    static func sanitize(_ normalized: String) -> String {
        var result = normalized
        result = result.replacingOccurrences(of: "://", with: "_")
        result = result.replacingOccurrences(of: ":", with: "_")
        result = result.replacingOccurrences(of: "/", with: "")
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if result.isEmpty { result = "unknown" }
        return result
    }

    private static func isDefaultPort(_ port: Int, scheme: String) -> Bool {
        (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
    }
}
