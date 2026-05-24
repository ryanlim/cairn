import Foundation
import Testing
@testable import CairnCore

@Suite("SyncEntities wire format")
struct SyncEntitiesTests {

    // MARK: - Envelope parsing

    @Test("AssetV1 event decodes with all fields populated")
    func decodesAssetEvent() throws {
        let line = """
        {"type":"AssetV1","data":{"id":"a1","ownerId":"u1","originalFileName":"IMG_0001.HEIC","thumbhash":"abc","checksum":"AAAA","fileCreatedAt":"2026-01-15T03:45:12.123Z","fileModifiedAt":"2026-01-15T03:45:12.123Z","localDateTime":"2026-01-14T19:45:12.123Z","duration":null,"type":"image","deletedAt":null,"isFavorite":false,"visibility":"timeline","livePhotoVideoId":"v1","stackId":null,"libraryId":null,"width":4032,"height":3024,"isEdited":false},"ack":"ack-1"}
        """
        let event = try SyncWireDecoder.decodeLine(line)
        guard case .asset(let asset, let ack) = event else {
            Issue.record("expected .asset, got \(String(describing: event))")
            return
        }
        #expect(ack == "ack-1")
        #expect(asset.id == "a1")
        #expect(asset.ownerId == "u1")
        #expect(asset.originalFileName == "IMG_0001.HEIC")
        #expect(asset.checksum == "AAAA")
        #expect(asset.livePhotoVideoId == "v1")
        #expect(asset.visibility == "timeline")
        #expect(asset.isFavorite == false)
        #expect(asset.type == "image")
        #expect(asset.width == 4032)
        #expect(asset.height == 3024)
        #expect(asset.deletedAt == nil)
        #expect(asset.fileCreatedAt != nil)
        #expect(asset.fileModifiedAt != nil)
    }

    @Test("AssetV1 event decodes with optionals nilled out")
    func decodesAssetEventWithNilOptionals() throws {
        let line = """
        {"type":"AssetV1","data":{"id":"a2","ownerId":"u1","originalFileName":"IMG.HEIC","thumbhash":null,"checksum":"BBBB","fileCreatedAt":null,"fileModifiedAt":null,"localDateTime":null,"duration":null,"type":"image","deletedAt":null,"isFavorite":false,"visibility":"timeline","livePhotoVideoId":null,"stackId":null,"libraryId":null,"width":null,"height":null,"isEdited":false},"ack":"ack-2"}
        """
        let event = try SyncWireDecoder.decodeLine(line)
        guard case .asset(let asset, _) = event else {
            Issue.record("expected .asset")
            return
        }
        #expect(asset.livePhotoVideoId == nil)
        #expect(asset.fileCreatedAt == nil)
        #expect(asset.fileModifiedAt == nil)
        #expect(asset.width == nil)
        #expect(asset.height == nil)
    }

    @Test("AssetV1 with non-fractional ISO date still decodes")
    func decodesPlainISO8601() throws {
        // sync.service emits dates as luxon-formatted DateTime; varies
        // by asset whether fractional seconds are included.
        let line = """
        {"type":"AssetV1","data":{"id":"a3","ownerId":"u1","originalFileName":"IMG.HEIC","thumbhash":null,"checksum":"CCCC","fileCreatedAt":"2026-04-21T00:00:00Z","fileModifiedAt":"2026-04-21T00:00:00Z","localDateTime":null,"duration":null,"type":"image","deletedAt":null,"isFavorite":false,"visibility":"timeline","livePhotoVideoId":null,"stackId":null,"libraryId":null,"width":null,"height":null,"isEdited":false},"ack":"ack-3"}
        """
        let event = try SyncWireDecoder.decodeLine(line)
        guard case .asset(let asset, _) = event else {
            Issue.record("expected .asset")
            return
        }
        #expect(asset.fileCreatedAt != nil)
    }

    @Test("AssetDeleteV1 event decodes to assetDeleted case")
    func decodesAssetDeleteEvent() throws {
        let line = """
        {"type":"AssetDeleteV1","data":{"assetId":"a99"},"ack":"ack-d"}
        """
        let event = try SyncWireDecoder.decodeLine(line)
        guard case .assetDeleted(let deletion, let ack) = event else {
            Issue.record("expected .assetDeleted")
            return
        }
        #expect(deletion.assetId == "a99")
        #expect(ack == "ack-d")
    }

    @Test("SyncCompleteV1 event decodes to complete case")
    func decodesCompleteEvent() throws {
        let line = """
        {"type":"SyncCompleteV1","data":{},"ack":"ack-c"}
        """
        let event = try SyncWireDecoder.decodeLine(line)
        guard case .complete(let type, let ack) = event else {
            Issue.record("expected .complete")
            return
        }
        #expect(type == .syncCompleteV1)
        #expect(ack == "ack-c")
    }

    @Test("Unknown type strings decode to .ignored without throwing")
    func unknownTypeDecodesAsIgnored() throws {
        // Forward-compatibility: server adds a hypothetical SyncFoobarV3
        // and we shouldn't blow up on a single event. Drop it on the
        // floor with its ack so the consumer can advance the cursor.
        let line = """
        {"type":"SyncFoobarV3","data":{"unknown":"shape"},"ack":"ack-f"}
        """
        let event = try SyncWireDecoder.decodeLine(line)
        guard case .ignored(let rawType, let ack) = event else {
            Issue.record("expected .ignored")
            return
        }
        #expect(rawType == "SyncFoobarV3")
        #expect(ack == "ack-f")
    }

    @Test("Known-but-unused entity types decode to .ignored")
    func knownButUnusedTypesIgnored() throws {
        // SyncResetV1 and SyncAckV1 exist on the server but cairn doesn't
        // act on them. Decoder routes them to .ignored.
        let resetLine = """
        {"type":"SyncResetV1","data":{},"ack":"ack-r"}
        """
        let event = try SyncWireDecoder.decodeLine(resetLine)
        guard case .ignored(let rawType, _) = event else {
            Issue.record("expected .ignored for SyncResetV1")
            return
        }
        #expect(rawType == "SyncResetV1")
    }

    @Test("Empty line returns nil rather than throwing")
    func emptyLineReturnsNil() throws {
        #expect(try SyncWireDecoder.decodeLine("") == nil)
        #expect(try SyncWireDecoder.decodeLine("   \n") == nil)
    }

    @Test("Malformed JSON throws (caller decides how to recover)")
    func malformedJSONThrows() {
        // Structurally-invalid JSON is fail-loud — there's no
        // recovery story that doesn't risk silently corrupting the
        // cursor state.
        #expect(throws: (any Error).self) {
            _ = try SyncWireDecoder.decodeLine("{not json")
        }
    }

    // MARK: - Ack field accessor

    @Test("SyncEvent.ack returns ack id for all event cases")
    func ackAccessor() throws {
        let assetLine = """
        {"type":"AssetV1","data":{"id":"a1","ownerId":"u1","originalFileName":"x","thumbhash":null,"checksum":"AAAA","fileCreatedAt":null,"fileModifiedAt":null,"localDateTime":null,"duration":null,"type":"image","deletedAt":null,"isFavorite":false,"visibility":"timeline","livePhotoVideoId":null,"stackId":null,"libraryId":null,"width":null,"height":null,"isEdited":false},"ack":"a"}
        """
        let deleteLine = """
        {"type":"AssetDeleteV1","data":{"assetId":"a99"},"ack":"d"}
        """
        let completeLine = """
        {"type":"SyncCompleteV1","data":{},"ack":"c"}
        """
        let ignoredLine = """
        {"type":"WhoKnowsV1","data":{},"ack":"i"}
        """
        #expect(try SyncWireDecoder.decodeLine(assetLine)?.ack == "a")
        #expect(try SyncWireDecoder.decodeLine(deleteLine)?.ack == "d")
        #expect(try SyncWireDecoder.decodeLine(completeLine)?.ack == "c")
        #expect(try SyncWireDecoder.decodeLine(ignoredLine)?.ack == "i")
    }

    // MARK: - Request bodies

    @Test("SyncStreamRequest encodes to the wire shape")
    func streamRequestEncoding() throws {
        let req = SyncStreamRequest(types: [.assetsV1], reset: false)
        let data = try JSONEncoder().encode(req)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect((json["types"] as? [String]) == ["AssetsV1"])
        #expect((json["reset"] as? Bool) == false)
    }

    @Test("SyncStreamRequest omits reset when nil")
    func streamRequestOmitsResetWhenNil() throws {
        let req = SyncStreamRequest(types: [.assetsV1], reset: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(req)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        // Default behavior of `Encodable` is to omit nil — keeps the body
        // minimal and matches what the server expects for "just stream
        // from wherever the cursor left off."
        #expect(json["reset"] == nil)
    }

    @Test("SyncAckSetRequest encodes acks array")
    func ackSetRequestEncoding() throws {
        let req = SyncAckSetRequest(acks: ["a1", "a2", "a3"])
        let data = try JSONEncoder().encode(req)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect((json["acks"] as? [String]) == ["a1", "a2", "a3"])
    }

    @Test("SyncAckSetRequest declares the server's batch cap")
    func ackBatchCap() {
        // Server validates acks.length <= 1000 (sync.dto.ts:460). Pinning
        // the constant in tests catches a future drift where someone
        // bumps the field without noticing the server check.
        #expect(SyncAckSetRequest.maxAcksPerRequest == 1000)
    }

    @Test("SyncAckRecord round-trips through Codable")
    func ackRecordRoundTrip() throws {
        let original = SyncAckRecord(type: .assetV1, ack: "opaque-id-42")
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SyncAckRecord.self, from: encoded)
        #expect(decoded == original)
    }
}
