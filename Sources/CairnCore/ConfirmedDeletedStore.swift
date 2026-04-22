import Foundation

/// The set of SHA1 checksums this device has ever observed in iOS's
/// "Recently Deleted" album. Companion to `EverSeenStore`. Together they
/// implement Wave 4's strict-mode safety: a candidate trash is only
/// trusted if its checksum has been positively observed transitioning
/// through Recently Deleted.
///
/// Semantics match `EverSeenStore`: append-only in steady state, idempotent
/// union, snapshot returns the full set. Restoration of a "recently deleted"
/// asset doesn't require removing its checksum here — the reconciliation
/// diff's `not in current-local` clause excludes restored assets from
/// candidates regardless of confirmed-deleted membership.
public protocol ConfirmedDeletedStore: Sendable {
    /// Every checksum the store has ever seen pass through Recently Deleted.
    func snapshot() async throws -> Set<Checksum>

    /// Merge `additions` into the store. Idempotent.
    func union(_ additions: Set<Checksum>) async throws
}

/// Default CLI-friendly impl: JSON array of base64 SHA1 strings at a
/// fixed path. Atomic writes; no-op on redundant unions to avoid churning
/// the file's mtime when nothing actually changed.
public actor JSONFileConfirmedDeletedStore: ConfirmedDeletedStore {
    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    public init(filePath: String) {
        self.path = URL(fileURLWithPath: filePath)
    }

    public func snapshot() async throws -> Set<Checksum> {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let data = try Data(contentsOf: path)
        guard !data.isEmpty else { return [] }
        let array = try JSONDecoder().decode([String].self, from: data)
        return Set(array.map { Checksum(base64: $0) })
    }

    public func union(_ additions: Set<Checksum>) async throws {
        var current = try await snapshot()
        let newCount = additions.subtracting(current).count
        guard newCount > 0 else { return }
        current.formUnion(additions)
        let sorted = current.map(\.base64).sorted()
        let data = try JSONEncoder().encode(sorted)
        try data.write(to: path, options: .atomic)
    }
}
