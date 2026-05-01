import Foundation

/// Checksums this device has positively observed as locally-deleted, each
/// carrying the timestamp it was first confirmed at. Companion to
/// `ObservedStore`. Together they implement Wave 4's strict-mode safety: a
/// candidate trash is only trusted if its checksum has been positively
/// observed leaving the local library, and the confirmation is older than
/// the settings-controlled quarantine window.
///
/// **Quarantine semantics.** The timestamp is the basis of the quarantine
/// window: freshly-confirmed items are held in pending review until
/// `confirmedAt + quarantineDays < now`, after which they become eligible
/// to trash. `union` is first-write-wins on the timestamp — re-confirming
/// an already-confirmed checksum does **not** reset its clock, so a
/// flapping asset (offloaded, re-downloaded, offloaded again) still ages
/// out predictably.
///
/// **Restoration.** If an asset re-appears locally (user restored from
/// iOS's Recently Deleted, or iCloud re-downloaded) the persistent-change
/// pipeline calls `remove` to un-confirm the checksum. A subsequent
/// deletion starts a fresh quarantine clock.
public protocol ConfirmedDeletedStore: Sendable {
    /// Every checksum the store has ever recorded as locally-deleted,
    /// paired with the timestamp it was first confirmed at.
    func snapshot() async throws -> [Checksum: Date]

    /// Merge `additions` into the store at `timestamp`. Idempotent on
    /// checksum; existing entries keep their original confirmation time.
    func union(_ additions: Set<Checksum>, at timestamp: Date) async throws

    /// Drop `checksums` from the store. Silent no-op on absence. Called
    /// by the persistent-change pipeline when an asset re-appears locally.
    func remove(_ checksums: Set<Checksum>) async throws
}

/// Default CLI-friendly impl: JSON object `{ "<base64>": "<iso8601>" }` at
/// a fixed path. Atomic writes; no-op on redundant unions to avoid
/// churning the file's mtime when nothing actually changed.
///
/// **Legacy migration.** Pre-quarantine deployments wrote a JSON array of
/// strings (no timestamps). On read, a legacy array decodes as "all
/// entries are `.distantPast`" — past any quarantine window, so they
/// remain eligible to trash, preserving the pre-migration behavior without
/// a separate migration step.
public actor JSONFileConfirmedDeletedStore: ConfirmedDeletedStore {
    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    public init(filePath: String) {
        self.path = URL(fileURLWithPath: filePath)
    }

    public func snapshot() async throws -> [Checksum: Date] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        let data = try Data(contentsOf: path)
        guard !data.isEmpty else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let map = try? decoder.decode([String: Date].self, from: data) {
            var out: [Checksum: Date] = [:]
            out.reserveCapacity(map.count)
            for (base64, date) in map {
                out[Checksum(base64: base64)] = date
            }
            return out
        }
        if let array = try? decoder.decode([String].self, from: data) {
            var out: [Checksum: Date] = [:]
            out.reserveCapacity(array.count)
            for base64 in array {
                out[Checksum(base64: base64)] = .distantPast
            }
            return out
        }
        // Neither legacy nor current format decoded cleanly. Re-run the
        // current-format decode without `try?` so the `DecodingError`
        // reaches the caller with its full parse trace — much more
        // actionable than a silent empty snapshot.
        //
        // `return [:]` below is technically unreachable — the `try`
        // above always throws once both `try?` fallbacks returned nil.
        // Swift's exhaustiveness check doesn't know that, so the return
        // is present to satisfy the type system.
        _ = try decoder.decode([String: Date].self, from: data)
        return [:]
    }

    public func union(_ additions: Set<Checksum>, at timestamp: Date) async throws {
        guard !additions.isEmpty else { return }
        var current = try await snapshot()
        var changed = false
        for checksum in additions where current[checksum] == nil {
            current[checksum] = timestamp
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

    private func writeSnapshot(_ map: [Checksum: Date]) throws {
        var encoded: [String: Date] = [:]
        encoded.reserveCapacity(map.count)
        for (checksum, date) in map {
            encoded[checksum.base64] = date
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(encoded)
        try data.write(to: path, options: .atomic)
    }
}
