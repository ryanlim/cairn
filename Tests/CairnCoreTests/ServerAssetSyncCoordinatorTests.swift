import Foundation
import Testing
@testable import CairnCore

@Suite("ServerAssetSyncCoordinator", .serialized)
struct ServerAssetSyncCoordinatorTests {

    // MARK: - In-memory test doubles

    /// Minimal in-memory `ServerAssetCacheStore`. Mirrors the SwiftData
    /// impl's idempotent-upsert behavior so the coordinator's contract
    /// with the cache is tested without booting SwiftData.
    actor FakeCache: ServerAssetCacheStore {
        private var rows: [String: SyncAssetV1] = [:]
        private(set) var applyCallCount = 0

        func snapshot() async throws -> [ServerAsset] {
            rows.values.map { payload in
                ServerAsset(
                    id: payload.id,
                    checksum: Checksum(base64: payload.checksum),
                    livePhotoVideoId: payload.livePhotoVideoId,
                    isTrashed: payload.deletedAt != nil,
                    originalFileName: payload.originalFileName,
                    fileCreatedAt: payload.fileCreatedAt,
                    thumbhash: nil
                )
            }
        }

        func size() async throws -> Int { rows.count }

        func applyEvents(_ events: [SyncEvent]) async throws -> ApplyEventsSummary {
            applyCallCount += 1
            var upserted = 0, deleted = 0, ignored = 0
            for event in events {
                switch event {
                case .asset(let payload, _):
                    rows[payload.id] = payload
                    upserted += 1
                case .assetDeleted(let payload, _):
                    if rows.removeValue(forKey: payload.assetId) != nil {
                        deleted += 1
                    } else {
                        ignored += 1
                    }
                case .complete, .ignored:
                    ignored += 1
                }
            }
            return ApplyEventsSummary(upserted: upserted, deleted: deleted, ignored: ignored)
        }

        func reset() async throws { rows.removeAll() }

        func seed(_ assets: [SyncAssetV1]) {
            for asset in assets { rows[asset.id] = asset }
        }
    }

    actor FakeAckStore: SyncAckStore {
        private var acks: [SyncEntityType: String] = [:]
        private(set) var setAckCallLog: [(SyncEntityType, String)] = []

        func ack(for type: SyncEntityType) async throws -> String? { acks[type] }

        func setAck(_ ack: String, for type: SyncEntityType) async throws {
            acks[type] = ack
            setAckCallLog.append((type, ack))
        }

        func allAcks() async throws -> [SyncAckRecord] {
            acks.map { SyncAckRecord(type: $0.key, ack: $0.value) }
        }

        func clearAll() async throws {
            acks.removeAll()
            setAckCallLog.removeAll()
        }
    }

    // MARK: - Helpers

    private func makeClient() -> ImmichClient {
        ImmichClient(
            baseURL: URL(string: "https://photos.example.com")!,
            apiKey: "TEST-KEY",
            session: MockURLProtocol.session()
        )
    }

    private func asset(_ id: String, ck: String, deletedAt: Date? = nil) -> SyncAssetV1 {
        SyncAssetV1(
            id: id,
            ownerId: "u1",
            originalFileName: "\(id).HEIC",
            checksum: ck,
            livePhotoVideoId: nil,
            deletedAt: deletedAt,
            visibility: "timeline",
            isFavorite: false,
            type: "image",
            fileCreatedAt: nil,
            fileModifiedAt: nil,
            width: nil,
            height: nil
        )
    }

    private func assetLine(_ a: SyncAssetV1, ack: String) -> String {
        let payload: [String: Any?] = [
            "id": a.id,
            "ownerId": a.ownerId,
            "originalFileName": a.originalFileName,
            "thumbhash": nil,
            "checksum": a.checksum,
            "fileCreatedAt": nil,
            "fileModifiedAt": nil,
            "localDateTime": nil,
            "duration": nil,
            "type": a.type,
            "deletedAt": a.deletedAt.map { ISO8601DateFormatter().string(from: $0) } as Any?,
            "isFavorite": a.isFavorite,
            "visibility": a.visibility,
            "livePhotoVideoId": a.livePhotoVideoId,
            "stackId": nil,
            "libraryId": nil,
            "width": nil,
            "height": nil,
            "isEdited": false,
        ]
        let cleaned = payload.compactMapValues { $0 }
        let dataJSON = try! JSONSerialization.data(withJSONObject: cleaned)
        let dataStr = String(data: dataJSON, encoding: .utf8)!
        return #"{"type":"AssetV1","data":\#(dataStr),"ack":"\#(ack)"}"#
    }

    private func deleteLine(_ assetId: String, ack: String) -> String {
        #"{"type":"AssetDeleteV1","data":{"assetId":"\#(assetId)"},"ack":"\#(ack)"}"#
    }

    private func completeLine(_ ack: String) -> String {
        #"{"type":"SyncCompleteV1","data":{},"ack":"\#(ack)"}"#
    }

    /// Wire the MockURLProtocol up so /sync/stream returns `streamLines`
    /// and /sync/ack accepts any POST. Optionally record the ack bodies
    /// for assertion. Returns a Ref the test can inspect.
    private func arrangeHappyPath(
        streamLines: [String],
        ackBodies: Ref<[Data]> = Ref([])
    ) -> Ref<[Data]> {
        let body = Data((streamLines.joined(separator: "\n") + "\n").utf8)
        MockURLProtocol.handler = { req in
            if req.url?.path == "/api/sync/stream" {
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    body
                )
            }
            if req.url?.path == "/api/sync/ack", req.httpMethod == "POST" {
                ackBodies.mutate { $0.append(req.readBody()) }
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        return ackBodies
    }

    // MARK: - Mode classification

    @Test("empty cache → bootstrap mode, sets reset:true on the stream request")
    func bootstrapModeSetsReset() async throws {
        let client = makeClient()
        let cache = FakeCache()
        let ackStore = FakeAckStore()
        let coordinator = ServerAssetSyncCoordinator(client: client, cache: cache, ackStore: ackStore)

        let streamBodies = Ref<[Data]>([])
        MockURLProtocol.handler = { req in
            if req.url?.path == "/api/sync/stream" {
                streamBodies.mutate { $0.append(req.readBody()) }
                let body = Data((self.completeLine("done-ack") + "\n").utf8)
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    body
                )
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        let summary = try await coordinator.syncToCache()
        #expect(summary.mode == .bootstrap)

        let firstBody = try #require(streamBodies.value.first)
        let json = try JSONSerialization.jsonObject(with: firstBody) as? [String: Any]
        #expect((json?["reset"] as? Bool) == true)
        #expect((json?["types"] as? [String]) == ["AssetsV1"])
    }

    @Test("non-empty cache → incremental mode, reset omitted")
    func incrementalModeOmitsReset() async throws {
        let client = makeClient()
        let cache = FakeCache()
        await cache.seed([asset("preexisting", ck: "ZZZZ")])
        let ackStore = FakeAckStore()
        let coordinator = ServerAssetSyncCoordinator(client: client, cache: cache, ackStore: ackStore)

        let streamBodies = Ref<[Data]>([])
        MockURLProtocol.handler = { req in
            if req.url?.path == "/api/sync/stream" {
                streamBodies.mutate { $0.append(req.readBody()) }
                let body = Data((self.completeLine("done-ack") + "\n").utf8)
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    body
                )
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        let summary = try await coordinator.syncToCache()
        #expect(summary.mode == .incremental)

        let body = try #require(streamBodies.value.first)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["reset"] == nil)
    }

    // MARK: - Event flow

    @Test("scripted stream of asset events ends up in the cache")
    func bootstrapPopulatesCache() async throws {
        let client = makeClient()
        let cache = FakeCache()
        let ackStore = FakeAckStore()
        let coordinator = ServerAssetSyncCoordinator(client: client, cache: cache, ackStore: ackStore)

        let lines: [String] = [
            assetLine(asset("a1", ck: "AAAA"), ack: "ack-1"),
            assetLine(asset("a2", ck: "BBBB"), ack: "ack-2"),
            assetLine(asset("a3", ck: "CCCC"), ack: "ack-3"),
            completeLine("complete-ack"),
        ]
        _ = arrangeHappyPath(streamLines: lines)

        let summary = try await coordinator.syncToCache()
        #expect(summary.upserted == 3)
        #expect(summary.deleted == 0)
        let snap = try await cache.snapshot()
        #expect(snap.count == 3)
    }

    @Test("inserts + deletes apply and the cache reflects the net state")
    func appliesInsertsAndDeletes() async throws {
        let client = makeClient()
        let cache = FakeCache()
        await cache.seed([asset("preexisting", ck: "PRE")])
        let ackStore = FakeAckStore()
        let coordinator = ServerAssetSyncCoordinator(client: client, cache: cache, ackStore: ackStore)

        let lines: [String] = [
            assetLine(asset("a1", ck: "AAAA"), ack: "ack-i1"),
            assetLine(asset("a2", ck: "BBBB"), ack: "ack-i2"),
            deleteLine("preexisting", ack: "ack-d1"),
            completeLine("complete-ack"),
        ]
        _ = arrangeHappyPath(streamLines: lines)

        let summary = try await coordinator.syncToCache()
        #expect(summary.upserted == 2)
        #expect(summary.deleted == 1)

        let snap = try await cache.snapshot()
        let ids = Set(snap.map(\.id))
        #expect(ids == ["a1", "a2"])
    }

    // MARK: - Ack flow

    @Test("acks every received event to the server")
    func acksEveryEvent() async throws {
        let client = makeClient()
        let cache = FakeCache()
        let ackStore = FakeAckStore()
        let coordinator = ServerAssetSyncCoordinator(client: client, cache: cache, ackStore: ackStore)

        let lines: [String] = [
            assetLine(asset("a1", ck: "AAAA"), ack: "ack-1"),
            assetLine(asset("a2", ck: "BBBB"), ack: "ack-2"),
            completeLine("complete-ack"),
        ]
        let ackBodies = arrangeHappyPath(streamLines: lines)
        _ = try await coordinator.syncToCache()

        // We POSTed at least one ack request; flatten every ack array.
        var allAckIds: Set<String> = []
        for body in ackBodies.value {
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            for ack in (json?["acks"] as? [String]) ?? [] {
                allAckIds.insert(ack)
            }
        }
        #expect(allAckIds == ["ack-1", "ack-2", "complete-ack"])
    }

    @Test("persists the highest-per-type ack to the local SyncAckStore")
    func persistsHighestPerTypeAck() async throws {
        let client = makeClient()
        let cache = FakeCache()
        let ackStore = FakeAckStore()
        let coordinator = ServerAssetSyncCoordinator(client: client, cache: cache, ackStore: ackStore)

        let lines: [String] = [
            assetLine(asset("a1", ck: "AAAA"), ack: "asset-ack-1"),
            assetLine(asset("a2", ck: "BBBB"), ack: "asset-ack-2"),
            assetLine(asset("a3", ck: "CCCC"), ack: "asset-ack-3"),
            deleteLine("a1", ack: "delete-ack-1"),
            completeLine("complete-ack"),
        ]
        _ = arrangeHappyPath(streamLines: lines)
        _ = try await coordinator.syncToCache()

        // Last asset ack received should be the persisted cursor for AssetV1;
        // last delete ack for AssetDeleteV1; last complete ack for SyncCompleteV1.
        #expect(try await ackStore.ack(for: .assetV1) == "asset-ack-3")
        #expect(try await ackStore.ack(for: .assetDeleteV1) == "delete-ack-1")
        #expect(try await ackStore.ack(for: .syncCompleteV1) == "complete-ack")
    }

    // MARK: - Batching

    @Test("batchSize controls flush cadence — large stream chunks into multiple cache applies")
    func batchSizeFlushesPeriodically() async throws {
        let client = makeClient()
        let cache = FakeCache()
        let ackStore = FakeAckStore()
        let coordinator = ServerAssetSyncCoordinator(client: client, cache: cache, ackStore: ackStore)

        var lines: [String] = []
        for i in 0..<25 {
            lines.append(assetLine(asset("a\(i)", ck: "ck\(i)"), ack: "ack-\(i)"))
        }
        lines.append(completeLine("done"))
        _ = arrangeHappyPath(streamLines: lines)

        let summary = try await coordinator.syncToCache(batchSize: 10)
        #expect(summary.upserted == 25)
        // 25 asset events + 1 complete = 26 events. With batchSize=10:
        // 3 flushes (10, 10, 6).
        let count = await cache.applyCallCount
        #expect(count == 3)
    }

    @Test("empty stream still finishes cleanly with .empty summary")
    func emptyStreamSummary() async throws {
        let client = makeClient()
        let cache = FakeCache()
        let ackStore = FakeAckStore()
        let coordinator = ServerAssetSyncCoordinator(client: client, cache: cache, ackStore: ackStore)

        MockURLProtocol.handler = { req in
            if req.url?.path == "/api/sync/stream" {
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        let summary = try await coordinator.syncToCache()
        #expect(summary.upserted == 0)
        #expect(summary.deleted == 0)
        #expect(summary.ignored == 0)
    }

    // MARK: - Error paths

    @Test("403 on sync/stream propagates .missingScope from the coordinator")
    func missingScopeOnStreamPropagates() async {
        let client = makeClient()
        let cache = FakeCache()
        let ackStore = FakeAckStore()
        let coordinator = ServerAssetSyncCoordinator(client: client, cache: cache, ackStore: ackStore)

        MockURLProtocol.handler = { req in
            return (
                HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        do {
            _ = try await coordinator.syncToCache()
            Issue.record("expected throw")
        } catch let err as ImmichClientError {
            guard case .missingScope(let scopes) = err else {
                Issue.record("expected .missingScope, got \(err)")
                return
            }
            #expect(scopes == ["sync.stream"])
        } catch {
            Issue.record("expected ImmichClientError, got \(error)")
        }
    }

    @Test("403 on sync/ack mid-batch propagates .missingScope but applied events stay in cache")
    func missingScopeOnAckPreservesAppliedEvents() async throws {
        let client = makeClient()
        let cache = FakeCache()
        let ackStore = FakeAckStore()
        let coordinator = ServerAssetSyncCoordinator(client: client, cache: cache, ackStore: ackStore)

        let lines: [String] = [
            assetLine(asset("a1", ck: "AAAA"), ack: "ack-1"),
            assetLine(asset("a2", ck: "BBBB"), ack: "ack-2"),
            completeLine("complete"),
        ]
        let body = Data((lines.joined(separator: "\n") + "\n").utf8)

        MockURLProtocol.handler = { req in
            if req.url?.path == "/api/sync/stream" {
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    body
                )
            }
            if req.url?.path == "/api/sync/ack" {
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        do {
            _ = try await coordinator.syncToCache()
            Issue.record("expected throw")
        } catch let err as ImmichClientError {
            guard case .missingScope(let scopes) = err else {
                Issue.record("expected .missingScope, got \(err)")
                return
            }
            #expect(scopes == ["sync.checkpoint.update"])
        } catch {
            Issue.record("expected ImmichClientError, got \(error)")
        }

        // Cache state: events were applied to the cache before the ack
        // failed. This is the crash-safety property — partial work
        // stays, the next stream call replays idempotently.
        let snap = try await cache.snapshot()
        #expect(snap.count == 2)
    }

    @Test("500 on sync/stream surfaces as .httpStatus, not .missingScope")
    func nonAuthErrorPropagates() async {
        let client = makeClient()
        let cache = FakeCache()
        let ackStore = FakeAckStore()
        let coordinator = ServerAssetSyncCoordinator(client: client, cache: cache, ackStore: ackStore)

        MockURLProtocol.handler = { req in
            return (
                HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data("internal server error".utf8)
            )
        }
        do {
            _ = try await coordinator.syncToCache()
            Issue.record("expected throw")
        } catch let err as ImmichClientError {
            guard case .httpStatus(let code, _) = err else {
                Issue.record("expected .httpStatus, got \(err)")
                return
            }
            #expect(code == 500)
        } catch {
            Issue.record("expected ImmichClientError, got \(error)")
        }
    }
}
