import Foundation
@testable import CairnCore

/// Shared in-memory fake of `ImmichWriter` for orchestrator tests. Records every
/// call for assertion and exposes setters so tests can seed failure modes.
actor FakeWriter: ImmichWriter {
    var upsertedTagValues: [String] = []
    var taggedBatches: [(tagIds: [String], assetIds: [String])] = []
    var trashedBatches: [[String]] = []
    var restoredBatches: [[String]] = []

    var nextTagId = "tag-uuid-1"
    var failTrashWith: Error? = nil
    var failTagWith: Error? = nil
    var failBulkTagWith: Error? = nil
    var failRestoreWith: Error? = nil

    func setFailTrash(_ error: Error?) { failTrashWith = error }
    func setFailTag(_ error: Error?) { failTagWith = error }
    func setFailBulkTag(_ error: Error?) { failBulkTagWith = error }
    func setFailRestore(_ error: Error?) { failRestoreWith = error }

    func upsertTag(value: String) async throws -> ImmichTag {
        if let err = failTagWith { throw err }
        upsertedTagValues.append(value)
        return ImmichTag(id: nextTagId, value: value)
    }

    func bulkTagAssets(tagIds: [String], assetIds: [String]) async throws {
        if let err = failBulkTagWith { throw err }
        taggedBatches.append((tagIds, assetIds))
    }

    func trashAssets(ids: [String]) async throws {
        if let err = failTrashWith { throw err }
        trashedBatches.append(ids)
    }

    func restoreAssets(ids: [String]) async throws {
        if let err = failRestoreWith { throw err }
        restoredBatches.append(ids)
    }
}

struct FakeError: Error, CustomStringConvertible, Equatable {
    let message: String
    var description: String { message }
}
