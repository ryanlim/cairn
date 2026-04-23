import Foundation

/// Opaque bytes representing a platform change-tracking cursor (on iOS, a
/// serialized `PHPersistentChangeToken`), plus the date we captured it.
/// The type is deliberately agnostic about the token's internals — the
/// platform owns archiving/unarchiving; cairn just persists the blob so a
/// later launch can ask "what has changed since then?".
public struct StoredToken: Sendable, Equatable, Codable {
    /// Platform-archived token bytes. Not human-readable; callers pass
    /// them back to the platform API unmodified.
    public let data: Data
    /// When the token was captured. Surfaced in the UI as "last synced"
    /// and used to estimate how stale the cursor is before a new sync.
    public let savedAt: Date

    public init(data: Data, savedAt: Date) {
        self.data = data
        self.savedAt = savedAt
    }
}

/// Narrow protocol over singleton token persistence. There is only
/// ever one live token per device; `save` replaces, `load` returns the
/// current token or `nil` when none has been captured yet, and `clear`
/// is used when the system reports
/// `PHPhotosError.persistentChangeTokenExpired` and we fall back to
/// full-library re-enumeration.
public protocol PersistentChangeTokenStore: Sendable {
    /// Current token, or `nil` on first launch / after `clear()`.
    func load() async throws -> StoredToken?
    /// Replace the stored token. Callers save immediately after
    /// successfully consuming a `fetchPersistentChanges(since:)` batch
    /// so the next run resumes from the new cursor.
    func save(_ token: StoredToken) async throws
    /// Drop the stored token. Forces the next sync to full-enumerate.
    func clear() async throws
}
