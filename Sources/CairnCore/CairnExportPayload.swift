import Foundation

public struct CairnExportPayload: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public let version: Int
    public let exportedAt: Date
    public let exportedFrom: String?
    public let servers: [ServerPayload]
    public let settings: CairnSettings?
    /// `UIDevice.current.identifierForVendor` at export time. Used to
    /// gate `localHashCache` restoration: the per-vendor IDFV rotates
    /// on the exact triggers that invalidate `PHAsset.localIdentifier`
    /// (device restore from backup, uninstall of every cairn-vendor
    /// app), so a matching IDFV guarantees the cached localIds still
    /// resolve. Mismatch means restoring the hash cache would point
    /// cairn at the wrong assets — the importer skips the hash cache
    /// portion and surfaces the mismatch. Optional for backwards
    /// compatibility with payloads written before this field existed.
    public let deviceVendorId: String?
    /// Snapshot of `LocalHashStore` at export time. Optional because
    /// older exports didn't include it and because the user can opt
    /// out of including it (large libraries → meaningful payload size).
    public let localHashCache: [HashCacheRow]?

    public init(
        exportedAt: Date = Date(),
        exportedFrom: String? = nil,
        servers: [ServerPayload],
        settings: CairnSettings? = nil,
        deviceVendorId: String? = nil,
        localHashCache: [HashCacheRow]? = nil
    ) {
        self.version = Self.currentVersion
        self.exportedAt = exportedAt
        self.exportedFrom = exportedFrom
        self.servers = servers
        self.settings = settings
        self.deviceVendorId = deviceVendorId
        self.localHashCache = localHashCache
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

    /// One row from `LocalHashStore`. Encodes the same shape as
    /// `StoredLocalHashEntry` on the SwiftData side (minus the
    /// derived compoundKey, which is regenerated on insert).
    /// `imputed` defaults to `false` so payloads written before
    /// fast-initial-scan landed decode cleanly with the right
    /// semantics (everything pre-imputation was locally verified).
    public struct HashCacheRow: Codable, Sendable, Equatable {
        public let localId: String
        public let checksumBase64: String
        public let modificationDate: Date?
        public let imputed: Bool

        public init(
            localId: String,
            checksumBase64: String,
            modificationDate: Date?,
            imputed: Bool = false
        ) {
            self.localId = localId
            self.checksumBase64 = checksumBase64
            self.modificationDate = modificationDate
            self.imputed = imputed
        }

        // Custom decoder so old payloads (no imputed field) default
        // to false rather than failing to decode.
        private enum CodingKeys: String, CodingKey {
            case localId, checksumBase64, modificationDate, imputed
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.localId = try c.decode(String.self, forKey: .localId)
            self.checksumBase64 = try c.decode(String.self, forKey: .checksumBase64)
            self.modificationDate = try c.decodeIfPresent(Date.self, forKey: .modificationDate)
            self.imputed = try c.decodeIfPresent(Bool.self, forKey: .imputed) ?? false
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
