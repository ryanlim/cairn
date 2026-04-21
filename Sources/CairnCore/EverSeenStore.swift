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
public protocol EverSeenStore: Sendable {
    /// Every checksum currently in the store.
    func snapshot() async throws -> Set<Checksum>

    /// Merge `additions` into the store. Idempotent.
    func union(_ additions: Set<Checksum>) async throws
}

/// Default CLI-friendly implementation: JSON array at a fixed path.
/// Writes are atomic (write-to-temp + rename) so interruption doesn't
/// corrupt the store.
public actor JSONFileEverSeenStore: EverSeenStore {
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
