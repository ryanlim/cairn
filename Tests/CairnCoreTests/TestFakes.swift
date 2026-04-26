import Foundation
@testable import CairnCore

/// Shared in-memory fake of `ImmichWriter` for orchestrator tests. Records every
/// call for assertion and exposes setters so tests can seed failure modes.
actor FakeWriter: ImmichWriter {
    var upsertedTagValues: [String] = []
    var taggedBatches: [(tagIds: [String], assetIds: [String])] = []
    var deletedTagIds: [String] = []
    var trashedBatches: [[String]] = []
    var restoredBatches: [[String]] = []
    var fetchedIdBatches: [[String]] = []

    var nextTagId = "tag-uuid-1"
    var failTrashWith: Error? = nil
    var failTagWith: Error? = nil
    var failBulkTagWith: Error? = nil
    var failDeleteTagWith: Error? = nil
    var failRestoreWith: Error? = nil
    var failFetchAssetsWith: Error? = nil
    /// Override returned state for `fetchAssets`. Defaults to "every
    /// requested id is now non-trashed" — i.e. the optimistic case
    /// where `RestoreOrchestrator`'s post-restore verification finds
    /// every asset successfully restored. Tests that want to model a
    /// silent-no-op partial restore replace this with an explicit
    /// fixture.
    var fetchAssetsHandler: (@Sendable ([String]) -> [ServerAsset])? = nil

    func setFailTrash(_ error: Error?) { failTrashWith = error }
    func setFailTag(_ error: Error?) { failTagWith = error }
    func setFailBulkTag(_ error: Error?) { failBulkTagWith = error }
    func setFailDeleteTag(_ error: Error?) { failDeleteTagWith = error }
    func setFailRestore(_ error: Error?) { failRestoreWith = error }
    func setFailFetchAssets(_ error: Error?) { failFetchAssetsWith = error }
    func setFetchAssetsHandler(_ handler: (@Sendable ([String]) -> [ServerAsset])?) {
        fetchAssetsHandler = handler
    }

    func upsertTag(value: String) async throws -> ImmichTag {
        if let err = failTagWith { throw err }
        upsertedTagValues.append(value)
        return ImmichTag(id: nextTagId, value: value)
    }

    func bulkTagAssets(tagIds: [String], assetIds: [String]) async throws {
        if let err = failBulkTagWith { throw err }
        taggedBatches.append((tagIds, assetIds))
    }

    func deleteTag(id: String) async throws {
        if let err = failDeleteTagWith { throw err }
        deletedTagIds.append(id)
    }

    func trashAssets(ids: [String]) async throws {
        if let err = failTrashWith { throw err }
        trashedBatches.append(ids)
    }

    func restoreAssets(ids: [String]) async throws {
        if let err = failRestoreWith { throw err }
        restoredBatches.append(ids)
    }

    func fetchAssets(ids: [String]) async throws -> [ServerAsset] {
        if let err = failFetchAssetsWith { throw err }
        fetchedIdBatches.append(ids)
        if let handler = fetchAssetsHandler {
            return handler(ids)
        }
        // Default: every requested id comes back non-trashed. Mirrors
        // the happy-path post-restore state for
        // `RestoreOrchestrator`'s verification step.
        return ids.map {
            ServerAsset(id: $0, checksum: Checksum(base64: "ck-\($0)"), isTrashed: false)
        }
    }
}

struct FakeError: Error, CustomStringConvertible, Equatable {
    let message: String
    var description: String { message }
}
