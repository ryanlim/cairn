import Foundation

/// Sidecar to `ConfirmedDeletedStore` that records the source
/// `localIdentifier` for each confirmed-deleted checksum. Lets the UI
/// group quarantine entries with inferred orphans by their shared
/// origin asset — without this persistence, the linkage is only valid
/// in the immediate post-delete sync and grouping degrades on
/// subsequent runs.
///
/// **Why a separate store** instead of folding the source-id onto
/// `ConfirmedDeletedStore`. The protocol is shared with the legacy
/// CLI and a (potential) Kotlin port; widening it for an iOS-only
/// concept would impose a no-op column on every consumer. Sidecar
/// keeps `ConfirmedDeletedStore` focused on the quarantine clock and
/// lets the source-id mapping evolve independently.
///
/// **Append-and-prune semantics.** `record` overwrites existing
/// entries for the given checksums (last write wins on the source-
/// id); callers should treat that as "the most recent scan that
/// retired this checksum from a particular id." `remove` is called
/// when a candidate is approved/excluded/dismissed by the user.
public protocol DeletionSourceStore: Sendable {
    /// Every recorded `(checksum → localIdentifier)` mapping.
    func snapshot() async throws -> [Checksum: String]

    /// Upsert each `(checksum, localIdentifier)` pair. Last write
    /// wins on collision. Idempotent: re-recording an unchanged
    /// entry must not churn the underlying file's mtime.
    func record(_ entries: [Checksum: String]) async throws

    /// Drop `checksums` from the store. Silent no-op on absence.
    func remove(_ checksums: Set<Checksum>) async throws

    /// Wipe every entry. Called by Settings → Reset index and
    /// related "start over" affordances.
    func clear() async throws
}

/// Default CLI-friendly impl: JSON object `{ "<base64>": "<localId>" }`
/// at a fixed path. Atomic writes; no-op on redundant records to avoid
/// churning the file's mtime when nothing actually changed. Mirrors
/// `JSONFileConfirmedDeletedStore`'s structure so the two sidecars
/// stay symmetrical on disk.
public actor JSONFileDeletionSourceStore: DeletionSourceStore {
    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    public init(filePath: String) {
        self.path = URL(fileURLWithPath: filePath)
    }

    public func snapshot() async throws -> [Checksum: String] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        let data = try Data(contentsOf: path)
        guard !data.isEmpty else { return [:] }
        let decoder = JSONDecoder()
        let map = try decoder.decode([String: String].self, from: data)
        var out: [Checksum: String] = [:]
        out.reserveCapacity(map.count)
        for (base64, localId) in map {
            out[Checksum(base64: base64)] = localId
        }
        return out
    }

    public func record(_ entries: [Checksum: String]) async throws {
        guard !entries.isEmpty else { return }
        var current = try await snapshot()
        var changed = false
        for (checksum, localId) in entries where current[checksum] != localId {
            current[checksum] = localId
            changed = true
        }
        guard changed else { return }
        try writeSnapshot(current)
    }

    public func remove(_ checksums: Set<Checksum>) async throws {
        guard !checksums.isEmpty else { return }
        var current = try await snapshot()
        var changed = false
        for checksum in checksums where current.removeValue(forKey: checksum) != nil {
            changed = true
        }
        guard changed else { return }
        try writeSnapshot(current)
    }

    public func clear() async throws {
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        try FileManager.default.removeItem(at: path)
    }

    private func writeSnapshot(_ map: [Checksum: String]) throws {
        var encoded: [String: String] = [:]
        encoded.reserveCapacity(map.count)
        for (checksum, localId) in map {
            encoded[checksum.base64] = localId
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(encoded)
        try data.write(to: path, options: .atomic)
    }
}
