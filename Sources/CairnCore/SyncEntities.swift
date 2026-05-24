import Foundation

// MARK: - Request types
//
// The Immich server distinguishes between *request* types (what the client
// asks to stream) and *entity* types (what the server emits on the wire).
// `SyncRequestType` is the outbound — `POST /api/sync/stream` body's `types`
// array. See `server/src/enum.ts:798` for the canonical list. Cairn only
// requests `assetsV1`; everything else is irrelevant to deletion reconciliation.

public enum SyncRequestType: String, Sendable, Codable, Hashable {
    case assetsV1 = "AssetsV1"
}

// MARK: - Entity (event) types
//
// `SyncEntityType` is what the server emits as the `type` field of each event
// envelope on the JSONL stream. See `server/src/enum.ts:828`. Cairn reads
// `assetV1` (insert/update) and `assetDeleteV1` (tombstone), terminated by
// `syncCompleteV1` for each requested entity type. Anything else from the
// stream is decoded as `.ignored` — defensive forward-compatibility for new
// types the server adds, even though the `types` request filter should
// keep most of them off the wire.

public enum SyncEntityType: String, Sendable, Codable, Hashable {
    case assetV1 = "AssetV1"
    case assetDeleteV1 = "AssetDeleteV1"
    case syncCompleteV1 = "SyncCompleteV1"
    case syncResetV1 = "SyncResetV1"
    case syncAckV1 = "SyncAckV1"
}

// MARK: - Asset payloads

/// Mirrors `SyncAssetV1` from `server/src/dtos/sync.dto.ts:68`. Cairn ignores
/// thumbhash, exif, stackId, libraryId, localDateTime, duration, isEdited —
/// none feed reconciliation. `checksum` is **base64-encoded SHA1**, identical
/// to `AssetResponseDto.checksum` (verified at `sync.service.ts:33-37`,
/// `hexOrBufferToBase64(checksum)`), so it joins directly against cairn's
/// existing Checksum primitive.
public struct SyncAssetV1: Sendable, Codable, Equatable, Hashable {
    public let id: String
    public let ownerId: String
    public let originalFileName: String
    public let checksum: String
    public let livePhotoVideoId: String?
    public let deletedAt: Date?
    public let visibility: String
    public let isFavorite: Bool
    public let type: String
    public let fileCreatedAt: Date?
    public let fileModifiedAt: Date?
    public let width: Int?
    public let height: Int?

    public init(
        id: String,
        ownerId: String,
        originalFileName: String,
        checksum: String,
        livePhotoVideoId: String? = nil,
        deletedAt: Date? = nil,
        visibility: String,
        isFavorite: Bool,
        type: String,
        fileCreatedAt: Date? = nil,
        fileModifiedAt: Date? = nil,
        width: Int? = nil,
        height: Int? = nil
    ) {
        self.id = id
        self.ownerId = ownerId
        self.originalFileName = originalFileName
        self.checksum = checksum
        self.livePhotoVideoId = livePhotoVideoId
        self.deletedAt = deletedAt
        self.visibility = visibility
        self.isFavorite = isFavorite
        self.type = type
        self.fileCreatedAt = fileCreatedAt
        self.fileModifiedAt = fileModifiedAt
        self.width = width
        self.height = height
    }
}

/// Mirrors `SyncAssetDeleteV1` from `server/src/dtos/sync.dto.ts:105`.
/// `assetId` is the server-side UUID (not the checksum) — cairn needs the
/// server-asset cache to maintain a UUID → checksum reverse index so
/// tombstones can find the row to drop.
public struct SyncAssetDeleteV1: Sendable, Codable, Equatable, Hashable {
    public let assetId: String

    public init(assetId: String) {
        self.assetId = assetId
    }
}

// MARK: - Wire envelope

/// One event on the JSONL stream returned by `POST /api/sync/stream`. The
/// server wraps every payload in `{ type, data, ack }`; this enum decodes
/// that envelope and dispatches `data` to the appropriate Codable struct
/// based on `type`. Unknown type strings decode to `.ignored` rather than
/// throwing — keeps the parser forward-compatible if the server adds new
/// entity types we don't request via `types`.
public enum SyncEvent: Sendable, Equatable, Hashable {
    case asset(SyncAssetV1, ack: String)
    case assetDeleted(SyncAssetDeleteV1, ack: String)
    case complete(type: SyncEntityType, ack: String)
    /// Type string we don't recognize, or one of `.syncResetV1` / `.syncAckV1`
    /// (defensive — we don't act on these but log them upstream).
    case ignored(type: String, ack: String?)

    /// The opaque ack id the server expects back when we acknowledge this
    /// event via `POST /api/sync/ack`. Nil only for the `.ignored` case
    /// when the envelope itself was malformed enough that we couldn't
    /// recover the field; the streaming consumer should skip such events
    /// rather than ack them.
    public var ack: String? {
        switch self {
        case .asset(_, let ack), .assetDeleted(_, let ack), .complete(_, let ack):
            return ack
        case .ignored(_, let ack):
            return ack
        }
    }
}

extension SyncEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case data
        case ack
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decode(String.self, forKey: .type)
        let ack = try container.decodeIfPresent(String.self, forKey: .ack)

        guard let entity = SyncEntityType(rawValue: rawType) else {
            // Unknown type — forward-compatibility hatch. We still need to
            // surface the ack so the streaming consumer can advance past
            // the event without re-reading it on every reconnect.
            self = .ignored(type: rawType, ack: ack)
            return
        }
        guard let ack else {
            // Recognized type but missing ack — treat as ignored so the
            // consumer keeps going. Without an ack we can't advance the
            // cursor; the next stream call will replay this event and
            // we'll get another chance.
            self = .ignored(type: rawType, ack: nil)
            return
        }

        switch entity {
        case .assetV1:
            let asset = try container.decode(SyncAssetV1.self, forKey: .data)
            self = .asset(asset, ack: ack)
        case .assetDeleteV1:
            let deletion = try container.decode(SyncAssetDeleteV1.self, forKey: .data)
            self = .assetDeleted(deletion, ack: ack)
        case .syncCompleteV1:
            self = .complete(type: entity, ack: ack)
        case .syncResetV1, .syncAckV1:
            self = .ignored(type: rawType, ack: ack)
        }
    }
}

// MARK: - JSONL parsing

/// Decoder configured for the Immich sync wire format. Dates come over as
/// ISO-8601, with or without fractional seconds depending on the
/// asset/endpoint — `AssetItemDTO.parseISO8601` documents the same
/// ambiguity for `search/metadata`. This decoder mirrors that strategy
/// so callers don't have to manage their own date formatters.
public enum SyncWireDecoder {
    public static func make() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            let raw = try container.decode(String.self)
            if let d = Self.parseISO8601(raw) { return d }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Could not parse ISO-8601 date: \(raw)"
            )
        }
        return decoder
    }

    /// Try fractional-seconds first, fall back to plain. Mirrors
    /// `ImmichClient.AssetItemDTO.parseISO8601` (we deliberately don't
    /// share the helper because that one is fileprivate to ImmichClient
    /// and the shape doesn't quite fit).
    static func parseISO8601(_ s: String) -> Date? {
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    /// Decode a single JSONL line to a SyncEvent. Empty lines and lines
    /// that fail to parse as JSON return `nil` so the streaming consumer
    /// can skip them rather than abort the whole batch — the server is
    /// known to emit blank lines between batches.
    ///
    /// JSON-structurally-valid envelopes that don't match any known
    /// type still throw, because that signals either a server schema
    /// drift or a real protocol error and shouldn't be silently dropped.
    public static func decodeLine(_ line: String, decoder: JSONDecoder? = nil) throws -> SyncEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        let dec = decoder ?? Self.make()
        return try dec.decode(SyncEvent.self, from: data)
    }
}

// MARK: - Request body encoders

/// The body of `POST /api/sync/stream`. `types` is `SyncRequestType[]` (not
/// `SyncEntityType[]` — verified at `sync.dto.ts:444`). `reset: true` clears
/// the server-side cursor for this client before streaming, so the next
/// stream replays everything; we use it sparingly (e.g. forced re-sync from
/// settings).
public struct SyncStreamRequest: Sendable, Codable, Equatable {
    public let types: [SyncRequestType]
    public let reset: Bool?

    public init(types: [SyncRequestType], reset: Bool? = nil) {
        self.types = types
        self.reset = reset
    }
}

/// The body of `POST /api/sync/ack`. `acks` is bounded server-side to 1000
/// entries (`sync.dto.ts:460`); the streaming consumer flushes acks in
/// smaller batches to keep the request reasonable.
public struct SyncAckSetRequest: Sendable, Codable, Equatable {
    public let acks: [String]

    public init(acks: [String]) {
        self.acks = acks
    }

    /// Server limit. Keep batches strictly under this; we use this constant
    /// in the streaming consumer's flush gate.
    public static let maxAcksPerRequest = 1000
}

/// One element of the `GET /api/sync/ack` response array (`SyncAckDto`,
/// `sync.dto.ts:451`).
public struct SyncAckRecord: Sendable, Codable, Equatable, Hashable {
    public let type: SyncEntityType
    public let ack: String

    public init(type: SyncEntityType, ack: String) {
        self.type = type
        self.ack = ack
    }
}
