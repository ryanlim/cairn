import Foundation

public struct CairnExportPayload: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public let version: Int
    public let exportedAt: Date
    public let exportedFrom: String?
    public let servers: [ServerPayload]
    public let settings: CairnSettings?

    public init(
        exportedAt: Date = Date(),
        exportedFrom: String? = nil,
        servers: [ServerPayload],
        settings: CairnSettings? = nil
    ) {
        self.version = Self.currentVersion
        self.exportedAt = exportedAt
        self.exportedFrom = exportedFrom
        self.servers = servers
        self.settings = settings
    }

    public struct ServerPayload: Codable, Sendable, Equatable {
        public let partitionKey: String
        public let normalizedURL: String
        public let observed: [String]  // sorted base64 checksums
        public let exclusions: [ExclusionRecord]
        public let journal: [String]  // raw JSONL lines

        public init(
            partitionKey: String,
            normalizedURL: String,
            observed: [String],
            exclusions: [ExclusionRecord],
            journal: [String]
        ) {
            self.partitionKey = partitionKey
            self.normalizedURL = normalizedURL
            self.observed = observed
            self.exclusions = exclusions
            self.journal = journal
        }

        // The Swift property was renamed `everSeen` → `observed` for
        // clarity, but the on-disk JSON key stays `everSeen` so older
        // export files (the only payload format shipped before the
        // rename) decode unchanged. Future v2 schema bumps are free
        // to drop this mapping.
        private enum CodingKeys: String, CodingKey {
            case partitionKey
            case normalizedURL
            case observed = "everSeen"
            case exclusions
            case journal
        }

        public struct ExclusionRecord: Codable, Sendable, Equatable {
            public let checksum: String
            public let addedAt: Date
            public let fromRunId: String?
            public let reason: String?

            public init(checksum: String, addedAt: Date, fromRunId: String? = nil, reason: String? = nil) {
                self.checksum = checksum
                self.addedAt = addedAt
                self.fromRunId = fromRunId
                self.reason = reason
            }
        }
    }

    // MARK: - Encoding helpers

    public static func encode(_ payload: CairnExportPayload) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(payload)
    }

    public static func decode(from data: Data) throws -> CairnExportPayload {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let payload = try dec.decode(CairnExportPayload.self, from: data)
        guard payload.version <= currentVersion else {
            throw ExportError.unsupportedVersion(payload.version)
        }
        return payload
    }

    public enum ExportError: Error, LocalizedError {
        case unsupportedVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v):
                return "This export was created with a newer version of cairn (format v\(v)). Update the app to import it."
            }
        }
    }
}
