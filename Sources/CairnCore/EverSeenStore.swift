import Foundation

/// The durable "every checksum this device has ever observed locally" set.
/// On iOS this will be backed by SwiftData; in the CLI it's a JSON file.
/// Both conform to this protocol so the reconciliation pipeline doesn't
/// care which is in use.
///
/// Semantics:
/// - Reads return a full snapshot. Small libraries → small sets; a user
///   with 50k photos has ~2 MB of base64 SHA1 strings in memory. Fine.
/// - Writes are idempotent-union; inserting a checksum that's already
///   present is a no-op, not an error.
/// - The store is append-only in normal operation. No public delete.
///
/// **Album tags (scope-aware indexing).** Each entry can carry a
/// `Set<String>` of `PHAssetCollection.localIdentifier` values — the
/// selected-scope albums in which cairn most recently observed the
/// asset. When `CairnSettings.indexingScope` is restricted, the
/// reconciler filters EverSeen entries by `tags ∩ scope ≠ ∅`. Legacy
/// entries written before scope-aware indexing existed have empty
/// tags; under restricted scope they're treated as out-of-scope until
/// re-observed. The plain `snapshot` / `union` API ignores tags
/// (preserved for full-library callers and CLI use). New callers use
/// `snapshotWithTags` / `recordObserved` / `setTags` to read and
/// write the tag dimension.
public protocol EverSeenStore: Sendable {
    /// Every checksum currently in the store.
    func snapshot() async throws -> Set<Checksum>

    /// Merge `additions` into the store. Idempotent. Album tags on
    /// new entries are empty (`[]`); existing entries keep their tags.
    func union(_ additions: Set<Checksum>) async throws

    /// Remove `checksums` from the store. Silent no-op on absence.
    func remove(_ checksums: Set<Checksum>) async throws

    /// Full snapshot keyed by checksum, with each entry's album tags.
    /// Empty `Set<String>` means "untagged / legacy / out-of-scope".
    func snapshotWithTags() async throws -> [Checksum: Set<String>]

    /// Upsert entries with album tags. Replaces tags on existing
    /// entries (the new observation wins — moves between albums show
    /// up correctly), inserts new entries with the supplied tags.
    /// Idempotent if called with the same map twice.
    func recordObserved(_ observations: [Checksum: Set<String>]) async throws

    /// Bulk-set the album tags on a specific set of checksums to a
    /// single common value. Used during scope-change rebuilds where
    /// every asset enumerated from a selected album shares the same
    /// tag set. Silent no-op on checksums not in the store.
    func setTags(for checksums: Set<Checksum>, tags: Set<String>) async throws
}

/// Default CLI-friendly implementation: JSON file at a fixed path.
/// Writes are atomic (write-to-temp + rename) so interruption doesn't
/// corrupt the store.
///
/// **On-disk shape.** Two formats are accepted on read:
///
/// - **Legacy v1**: a flat `[String]` array of base64 SHA1s. Loaded with
///   empty album tags for each entry. Written by cairn 0.1.x.
/// - **v2 (current)**: an object map `{base64: [albumLocalId, …]}`.
///   Empty array means "untagged / out-of-scope under restricted
///   scope." Written by every save once any entry has tags.
///
/// New writes always use v2. The legacy v1 format is forward-compatible
/// (decoded with empty tags) but not backward — once a v2 file is
/// written, an older cairn binary won't decode it. Acceptable because
/// the CLI ships in lockstep with the iOS app.
public actor JSONFileEverSeenStore: EverSeenStore {
    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    public init(filePath: String) {
        self.path = URL(fileURLWithPath: filePath)
    }

    public func snapshot() async throws -> Set<Checksum> {
        let map = try await snapshotWithTags()
        return Set(map.keys)
    }

    public func union(_ additions: Set<Checksum>) async throws {
        var current = try await loadMap()
        var changed = false
        for ck in additions where current[ck.base64] == nil {
            current[ck.base64] = []
            changed = true
        }
        guard changed else { return }
        try writeMap(current)
    }

    public func remove(_ checksums: Set<Checksum>) async throws {
        guard !checksums.isEmpty else { return }
        var current = try await loadMap()
        let before = current.count
        for ck in checksums {
            current.removeValue(forKey: ck.base64)
        }
        guard current.count < before else { return }
        try writeMap(current)
    }

    public func snapshotWithTags() async throws -> [Checksum: Set<String>] {
        let map = try await loadMap()
        var out: [Checksum: Set<String>] = [:]
        out.reserveCapacity(map.count)
        for (b64, tags) in map {
            out[Checksum(base64: b64)] = Set(tags)
        }
        return out
    }

    public func recordObserved(_ observations: [Checksum: Set<String>]) async throws {
        guard !observations.isEmpty else { return }
        var current = try await loadMap()
        var changed = false
        for (ck, tags) in observations {
            let sorted = tags.sorted()
            if current[ck.base64] != sorted {
                current[ck.base64] = sorted
                changed = true
            }
        }
        guard changed else { return }
        try writeMap(current)
    }

    public func setTags(for checksums: Set<Checksum>, tags: Set<String>) async throws {
        guard !checksums.isEmpty else { return }
        var current = try await loadMap()
        var changed = false
        let sortedTags = tags.sorted()
        for ck in checksums where current[ck.base64] != nil {
            if current[ck.base64] != sortedTags {
                current[ck.base64] = sortedTags
                changed = true
            }
        }
        guard changed else { return }
        try writeMap(current)
    }

    // MARK: - Internal helpers

    /// Load the on-disk map, transparently migrating the legacy `[String]`
    /// shape to `[String: [String]]` (empty-tags) on read. Missing file
    /// returns an empty map (no error).
    private func loadMap() async throws -> [String: [String]] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        let data = try Data(contentsOf: path)
        // Try v2 (object) first.
        if let map = try? JSONDecoder().decode([String: [String]].self, from: data) {
            return map
        }
        // Fall back to v1 (array of base64 strings) for legacy files.
        let array = try JSONDecoder().decode([String].self, from: data)
        var map: [String: [String]] = [:]
        map.reserveCapacity(array.count)
        for b64 in array {
            map[b64] = []
        }
        return map
    }

    private func writeMap(_ map: [String: [String]]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(map)
        try data.write(to: path, options: .atomic)
    }
}
