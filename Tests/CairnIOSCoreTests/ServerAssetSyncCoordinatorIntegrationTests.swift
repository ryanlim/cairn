import Foundation
import Testing
import SwiftData
import CairnCore
@testable import CairnIOSCore

/// End-to-end tests: real SwiftData-backed cache + ack store +
/// ServerAssetSyncCoordinator + IOSIOSMockURLProtocol-mocked ImmichClient.
/// Distinct from `ServerAssetSyncCoordinatorTests` in CairnCoreTests
/// which uses in-memory protocol fakes — this one exists to catch
/// integration bugs between the coordinator's actor isolation and
/// SwiftData's per-context isolation.
@Suite("ServerAssetSyncCoordinator + SwiftData integration", .serialized)
struct ServerAssetSyncCoordinatorIntegrationTests {

    // MARK: - Setup

    private func makeContainer() throws -> ModelContainer {
        try CairnSwiftDataContainer.make(inMemory: true)
    }

    private func makeClient() -> (client: ImmichClient, mock: IOSMockSession) {
        let mock = IOSMockURLProtocol.session()
        let client = ImmichClient(
            baseURL: URL(string: "https://photos.example.com")!,
            apiKey: "TEST-KEY",
            session: mock.session
        )
        return (client, mock)
    }

    private func assetLine(id: String, ck: String, deletedAt: Date? = nil, visibility: String = "timeline") -> String {
        let payload: [String: Any?] = [
            "id": id,
            "ownerId": "u1",
            "originalFileName": "\(id).HEIC",
            "thumbhash": nil,
            "checksum": ck,
            "fileCreatedAt": nil,
            "fileModifiedAt": nil,
            "localDateTime": nil,
            "duration": nil,
            "type": "image",
            "deletedAt": deletedAt.map { ISO8601DateFormatter().string(from: $0) } as Any?,
            "isFavorite": false,
            "visibility": visibility,
            "livePhotoVideoId": nil,
            "stackId": nil,
            "libraryId": nil,
            "width": nil,
            "height": nil,
            "isEdited": false,
        ]
        let cleaned = payload.compactMapValues { $0 }
        let dataJSON = try! JSONSerialization.data(withJSONObject: cleaned)
        let dataStr = String(data: dataJSON, encoding: .utf8)!
        return #"{"type":"AssetV1","data":\#(dataStr),"ack":"\#(id)-ack"}"#
    }

    private func deleteLine(_ assetId: String, ack: String) -> String {
        #"{"type":"AssetDeleteV1","data":{"assetId":"\#(assetId)"},"ack":"\#(ack)"}"#
    }

    private func completeLine(_ ack: String) -> String {
        #"{"type":"SyncCompleteV1","data":{},"ack":"\#(ack)"}"#
    }

    private func arrangeMockServer(_ mock: IOSMockSession, streamLines: [String]) {
        let body = Data((streamLines.joined(separator: "\n") + "\n").utf8)
        mock.handler = { req in
            if req.url?.path == "/api/sync/stream" {
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    body
                )
            }
            if req.url?.path == "/api/sync/ack" {
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
    }

    // MARK: - Tests

    @Test("bootstrap: empty SwiftData cache + scripted stream lands all assets in storage")
    func bootstrapPopulatesSwiftDataCache() async throws {
        let container = try makeContainer()
        let cache = SwiftDataServerAssetCacheStore(container: container)
        let acks = SwiftDataSyncAckStore(container: container)
        let (client, mock) = makeClient()
        let coordinator = ServerAssetSyncCoordinator(
            client: client,
            cache: cache,
            ackStore: acks
        )

        let lines: [String] = [
            assetLine(id: "a1", ck: "AAAA"),
            assetLine(id: "a2", ck: "BBBB"),
            assetLine(id: "a3", ck: "CCCC"),
            completeLine("complete"),
        ]
        arrangeMockServer(mock, streamLines: lines)

        let summary = try await coordinator.syncToCache()
        #expect(summary.mode == .bootstrap)
        #expect(summary.upserted == 3)

        let snap = try await cache.snapshot()
        let ids = Set(snap.map(\.id))
        #expect(ids == ["a1", "a2", "a3"])

        // The highest asset ack is "a3-ack" — last AssetV1 in the
        // stream. SyncCompleteV1 also persists.
        #expect(try await acks.ack(for: .assetV1) == "a3-ack")
        #expect(try await acks.ack(for: .syncCompleteV1) == "complete")
    }

    @Test("incremental: pre-seeded SwiftData cache + scripted deltas yields net state")
    func incrementalUpdatesAndDeletes() async throws {
        let container = try makeContainer()
        let cache = SwiftDataServerAssetCacheStore(container: container)
        let acks = SwiftDataSyncAckStore(container: container)
        let (client, mock) = makeClient()
        let coordinator = ServerAssetSyncCoordinator(
            client: client,
            cache: cache,
            ackStore: acks
        )

        // Seed with 5 pre-existing assets to force incremental mode.
        let seedLines = (0..<5).map { i in assetLine(id: "seed\(i)", ck: "ck\(i)") } + [completeLine("seed-done")]
        arrangeMockServer(mock, streamLines: seedLines)
        _ = try await coordinator.syncToCache()
        #expect(try await cache.size() == 5)

        // Now the incremental delta: 3 new + 2 deletes.
        let deltaLines: [String] = [
            assetLine(id: "new1", ck: "N1"),
            assetLine(id: "new2", ck: "N2"),
            assetLine(id: "new3", ck: "N3"),
            deleteLine("seed1", ack: "del-seed1"),
            deleteLine("seed3", ack: "del-seed3"),
            completeLine("delta-done"),
        ]
        arrangeMockServer(mock, streamLines: deltaLines)

        let summary = try await coordinator.syncToCache()
        #expect(summary.mode == .incremental)
        #expect(summary.upserted == 3)
        #expect(summary.deleted == 2)

        let snap = try await cache.snapshot()
        let ids = Set(snap.map(\.id))
        #expect(ids == ["seed0", "seed2", "seed4", "new1", "new2", "new3"])
    }

    @Test("snapshot's visibility filter holds end-to-end: hidden + locked never reach reconciler")
    func snapshotFilterEndToEnd() async throws {
        let container = try makeContainer()
        let cache = SwiftDataServerAssetCacheStore(container: container)
        let acks = SwiftDataSyncAckStore(container: container)
        let (client, mock) = makeClient()
        let coordinator = ServerAssetSyncCoordinator(
            client: client,
            cache: cache,
            ackStore: acks
        )

        let lines: [String] = [
            assetLine(id: "timeline-asset", ck: "TL"),
            assetLine(id: "hidden-motion-video", ck: "MV", visibility: "hidden"),
            assetLine(id: "archive-asset", ck: "AR", visibility: "archive"),
            assetLine(id: "locked-asset", ck: "LK", visibility: "locked"),
            assetLine(id: "trashed-asset", ck: "TR", deletedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            completeLine("done"),
        ]
        arrangeMockServer(mock, streamLines: lines)

        _ = try await coordinator.syncToCache()
        // size() counts every row regardless of visibility/trash.
        #expect(try await cache.size() == 5)

        // snapshot() is the engine-facing view — only timeline + archive,
        // not-trashed.
        let snap = try await cache.snapshot()
        let ids = Set(snap.map(\.id))
        #expect(ids == ["timeline-asset", "archive-asset"])
    }

    @Test("crash safety: 403 on /sync/ack leaves applied events in SwiftData")
    func crashSafetyOnAckFailure() async throws {
        let container = try makeContainer()
        let cache = SwiftDataServerAssetCacheStore(container: container)
        let acks = SwiftDataSyncAckStore(container: container)
        let (client, mock) = makeClient()
        let coordinator = ServerAssetSyncCoordinator(
            client: client,
            cache: cache,
            ackStore: acks
        )

        let lines: [String] = [
            assetLine(id: "a1", ck: "AAAA"),
            assetLine(id: "a2", ck: "BBBB"),
            completeLine("done"),
        ]
        let body = Data((lines.joined(separator: "\n") + "\n").utf8)
        mock.handler = { req in
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

        // Applied events stayed in SwiftData even though the server
        // didn't get its ack — what lets the next stream call replay
        // them idempotently after the user regenerates the API key.
        let snap = try await cache.snapshot()
        #expect(Set(snap.map(\.id)) == ["a1", "a2"])
    }

    @Test("cache.snapshot survives across new actor instances on the same container")
    func snapshotPersistsAcrossActorInstances() async throws {
        let container = try makeContainer()
        // First coordinator pass: populate.
        do {
            let cache = SwiftDataServerAssetCacheStore(container: container)
            let acks = SwiftDataSyncAckStore(container: container)
            let (client, mock) = makeClient()
            let coordinator = ServerAssetSyncCoordinator(
                client: client,
                cache: cache,
                ackStore: acks
            )
            let lines: [String] = [
                assetLine(id: "persistent-1", ck: "P1"),
                completeLine("done"),
            ]
            arrangeMockServer(mock, streamLines: lines)
            _ = try await coordinator.syncToCache()
        }

        // Second pass — new actor instances over the same container.
        // Should see the persisted state.
        let cache = SwiftDataServerAssetCacheStore(container: container)
        let snap = try await cache.snapshot()
        #expect(Set(snap.map(\.id)) == ["persistent-1"])

        let acks = SwiftDataSyncAckStore(container: container)
        #expect(try await acks.ack(for: .assetV1) == "persistent-1-ack")
    }
}
