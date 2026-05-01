import Foundation

/// First-observed checksum set per `localIdentifier`. Anchors the
/// "original-content backup on Immich is sacred" guarantee — while a
/// `localIdentifier` is alive in the photo library, the very first
/// SHA1s cairn ever observed for it are exempt from candidate
/// evaluation, even after edits replace them in `LocalHashStore`.
///
/// **Why this exists.** Apple's edit model preserves originals locally
/// inside Photos.app's `PHAsset` bundle (visible via `PHAssetResource`
/// type `.photo` alongside `.fullSizePhoto`), but the adjustment data
/// — the actual edit instructions — is a private blob that never
/// leaves Photos.app. Every export/upload yields flat rendered bytes,
/// so once on Immich an "edited photo" is just two unrelated assets
/// (original + rendered edit). Without `EditRetirementStore`, cairn's
/// cache reflects the post-edit bytes, the pre-edit SHA1 sits in
/// `ObservedStore` with no local presence, and reconciliation candidates
/// the original for trash — destroying the user's original-content
/// backup. This store anchors the original so `currentLocalChecksums`
/// can extend to include "first observed for any live id" and the
/// candidate diff skips the protected SHA1s.
///
/// **Why a Set, not a single Checksum.** Live Photos hash to two
/// resources (still + paired motion video) so the first observation
/// is naturally a set. Storing the full set lets us protect both
/// halves identically.
///
/// **First-write-wins semantics.** `recordFirstObserved` only writes
/// when no entry exists for the id. Re-observation (full enumeration,
/// orphan-sweep recovery, repeated insert events) is idempotent. This
/// is the load-bearing rule: if a later observation could overwrite,
/// edited photos would lose their original-content anchor and the
/// edit-protection contract breaks.
///
/// **Lifecycle.** Cleared alongside `LocalHashStore` at sign-out and
/// reset-index time. On delete (PhotoKit `deletedLocalIdentifier`),
/// the reconciler reads the entry into the union of "removed
/// checksums" before calling `remove(for:)` — both the current bytes
/// and the protected original propagate to `ConfirmedDeletedStore`
/// for quarantine. After 14 days both versions move to ready-to-trash
/// and propagate to Immich, matching user intent ("delete on iPhone
/// propagates everything to Immich").
///
/// **Worked scenarios** (`SHA1_O` original, `SHA1_E*` edits — see
/// CLAUDE.md "Edit semantics" for the full design discussion):
///
/// - *Edit → revert → edit again.* First edit retires `SHA1_O` ∈
///   firstObserved → **protect**, no quarantine, original stays on
///   Immich. Revert retires `SHA1_E1` ∉ firstObserved → quarantine,
///   trashes after 14 days. Second edit retires `SHA1_O` again →
///   protect. Steady state on Immich: `{SHA1_O, SHA1_E2}` — exactly
///   one original + one current.
/// - *Edit → edit (no revert).* Identical end state: intermediate
///   `SHA1_E1` quarantines; original stays anchored.
/// - *Delete after multiple edits.* `removedChecksums` includes both
///   current cache bytes AND firstObserved set; both flow through
///   `trulyAbsent` filter into `ConfirmedDeletedStore` at the same
///   timestamp. All versions trash together after the quarantine
///   window.
///
/// **Cairn-installed-after-edit caveat.** If cairn first observes an
/// id that's already been edited, `firstObserved` ends up being the
/// edited bytes, not the true pre-cairn original. The actual
/// pre-cairn original on Immich is invisible to cairn (its SHA1 isn't
/// in `ObservedStore` since cairn never hashed it) so reconciliation
/// never candidates it — it stays safe on Immich by virtue of being
/// outside the diff. Net behavior is acceptable: every cairn-known
/// version is protected; pre-cairn versions are also protected by
/// virtue of being unknown.
public protocol EditRetirementStore: Sendable {
    /// Read the protected SHA1 set for one id. Returns `[]` when the
    /// id has never been observed.
    func firstObserved(for localIdentifier: String) async throws -> Set<Checksum>

    /// First-write-wins write. No-op when an entry for `localIdentifier`
    /// already exists. Callers can invoke at every observation site
    /// (insert, full-enum re-hash, orphan-sweep recovery) without
    /// worrying about stomping the original.
    func recordFirstObserved(_ checksums: Set<Checksum>, for localIdentifier: String) async throws

    /// Full snapshot — every id with its protected SHA1 set. Used by
    /// the live reconciliation to extend `currentLocalChecksums` so
    /// protected SHA1s never enter the candidate diff.
    func snapshot() async throws -> [String: Set<Checksum>]

    /// Drop entries for these ids. Called when PhotoKit confirms a
    /// deletion — the protection no longer applies.
    func remove(for localIdentifiers: Set<String>) async throws

    /// Wipe every entry. Reset-index and sign-out paths.
    func clear() async throws
}

/// Default CLI/test impl: JSON object `{ "<localIdentifier>": ["<base64>",...] }`
/// at a fixed path. Atomic writes; no-op on idempotent re-records to
/// keep the file's mtime stable.
public actor JSONFileEditRetirementStore: EditRetirementStore {
    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    public init(filePath: String) {
        self.path = URL(fileURLWithPath: filePath)
    }

    public func firstObserved(for localIdentifier: String) async throws -> Set<Checksum> {
        let map = try readMap()
        guard let base64s = map[localIdentifier] else { return [] }
        return Set(base64s.map { Checksum(base64: $0) })
    }

    public func recordFirstObserved(_ checksums: Set<Checksum>, for localIdentifier: String) async throws {
        guard !checksums.isEmpty else { return }
        var map = try readMap()
        // First-write-wins. An existing entry stays untouched even if
        // the proposed set differs — that's exactly the case the
        // original-content anchor protects against.
        guard map[localIdentifier] == nil else { return }
        map[localIdentifier] = checksums.map(\.base64).sorted()
        try writeMap(map)
    }

    public func snapshot() async throws -> [String: Set<Checksum>] {
        let map = try readMap()
        var out: [String: Set<Checksum>] = [:]
        out.reserveCapacity(map.count)
        for (id, base64s) in map {
            out[id] = Set(base64s.map { Checksum(base64: $0) })
        }
        return out
    }

    public func remove(for localIdentifiers: Set<String>) async throws {
        guard !localIdentifiers.isEmpty else { return }
        var map = try readMap()
        var changed = false
        for id in localIdentifiers where map.removeValue(forKey: id) != nil {
            changed = true
        }
        guard changed else { return }
        try writeMap(map)
    }

    public func clear() async throws {
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        try FileManager.default.removeItem(at: path)
    }

    private func readMap() throws -> [String: [String]] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        let data = try Data(contentsOf: path)
        guard !data.isEmpty else { return [:] }
        return try JSONDecoder().decode([String: [String]].self, from: data)
    }

    private func writeMap(_ map: [String: [String]]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(map)
        try data.write(to: path, options: .atomic)
    }
}
