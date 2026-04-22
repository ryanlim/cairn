import Foundation

/// Metadata attached to each protected checksum. Kept alongside the checksum
/// so a human reading `exclusions.json` later can answer "why is this here?"
/// without having to cross-reference a journal.
///
/// - `addedAt`: when the user (or tooling) asked to protect this content.
/// - `fromRunId`: the run that surfaced this checksum as a deletion candidate,
///   if the exclusion was decided in response to a specific reconciliation
///   pass. Optional because the allowlist can also be seeded out-of-band
///   (e.g. a user importing a known-good list).
/// - `reason`: free-text, user-supplied. Intentionally unstructured — this
///   is a note-to-future-self, not a schema field the tool introspects.
public struct ExclusionMetadata: Sendable, Codable, Equatable {
    public let addedAt: Date
    public let fromRunId: String?
    public let reason: String?

    public init(addedAt: Date, fromRunId: String? = nil, reason: String? = nil) {
        self.addedAt = addedAt
        self.fromRunId = fromRunId
        self.reason = reason
    }
}

/// The durable "never trash these, no matter what reconciliation says" set.
/// Keyed by `Checksum` because filenames are not stable across server-side
/// renames, but SHA1 of file content is. A user who once said "keep this"
/// means it about the bytes, not the current metadata wrapper around them.
///
/// Semantics:
/// - `snapshot()` returns the full map. Libraries large enough for this to
///   matter don't exist — exclusion lists are user-curated and small.
/// - `insert` is last-writer-wins on collision: re-inserting an existing
///   checksum overwrites its metadata. Rationale: the most recent call has
///   the most recent user intent (e.g. a new reason string).
/// - `remove` is a silent no-op for checksums that aren't present. Callers
///   that care can diff `snapshot()` first; the store itself is forgiving
///   so that `cairn exclude --remove` never errors on double-runs.
public protocol ExclusionStore: Sendable {
    /// Every excluded checksum currently in the store, with its metadata.
    func snapshot() async throws -> [Checksum: ExclusionMetadata]

    /// Fast-path membership check. Implementations are free to optimize,
    /// but the default just reads the snapshot — the data is small.
    func isExcluded(_ checksum: Checksum) async throws -> Bool

    /// Add or replace entries. Last-writer-wins on collision.
    func insert(_ entries: [Checksum: ExclusionMetadata]) async throws

    /// Drop entries. Missing checksums are silently ignored.
    func remove(_ checksums: Set<Checksum>) async throws
}

/// Default CLI-friendly implementation: JSON array of `{checksum, addedAt,
/// fromRunId, reason}` objects at a fixed path. Writes are atomic so a
/// crash mid-write cannot corrupt the file.
///
/// JSON shape is an **array of objects** rather than a dict keyed by
/// checksum because base64 SHA1 strings are awkward as JSON keys — they
/// contain `/` and `+`, and tools that diff JSON (editors, git) render
/// an array of small objects more readably. The on-disk order is sorted
/// by checksum for stable diffs.
public actor JSONFileExclusionStore: ExclusionStore {
    public let path: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(path: URL) {
        self.path = path
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    public init(filePath: String) {
        self.init(path: URL(fileURLWithPath: filePath))
    }

    public func snapshot() async throws -> [Checksum: ExclusionMetadata] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        let data = try Data(contentsOf: path)
        guard !data.isEmpty else { return [:] }
        let records = try decoder.decode([DiskRecord].self, from: data)
        var out: [Checksum: ExclusionMetadata] = [:]
        out.reserveCapacity(records.count)
        for record in records {
            out[Checksum(base64: record.checksum)] = ExclusionMetadata(
                addedAt: record.addedAt,
                fromRunId: record.fromRunId,
                reason: record.reason
            )
        }
        return out
    }

    public func isExcluded(_ checksum: Checksum) async throws -> Bool {
        try await snapshot()[checksum] != nil
    }

    public func insert(_ entries: [Checksum: ExclusionMetadata]) async throws {
        guard !entries.isEmpty else { return }
        var current = try await snapshot()
        for (checksum, metadata) in entries {
            current[checksum] = metadata
        }
        try writeAll(current)
    }

    public func remove(_ checksums: Set<Checksum>) async throws {
        guard !checksums.isEmpty else { return }
        var current = try await snapshot()
        var changed = false
        for checksum in checksums where current.removeValue(forKey: checksum) != nil {
            changed = true
        }
        guard changed else { return }
        try writeAll(current)
    }

    // MARK: - Private

    /// On-disk row. Kept private so the public API exposes `ExclusionMetadata`
    /// keyed by `Checksum`; the array-of-flat-rows shape is an encoding
    /// detail callers shouldn't have to know about.
    private struct DiskRecord: Codable {
        let checksum: String
        let addedAt: Date
        let fromRunId: String?
        let reason: String?
    }

    private func writeAll(_ entries: [Checksum: ExclusionMetadata]) throws {
        let records = entries
            .map { key, value in
                DiskRecord(
                    checksum: key.base64,
                    addedAt: value.addedAt,
                    fromRunId: value.fromRunId,
                    reason: value.reason
                )
            }
            .sorted { $0.checksum < $1.checksum }
        let data = try encoder.encode(records)
        try data.write(to: path, options: .atomic)
    }
}
