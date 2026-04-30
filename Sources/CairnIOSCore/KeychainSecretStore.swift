import Foundation
import Security
import CairnCore

/// Mutable variant of `SecretStore`. The base protocol in `CairnCore`
/// is read-only by design — the CLI populates secrets out-of-band via
/// a `.env` file loaded at process start. The iOS app must *write*
/// secrets during onboarding and rotate them later, so this
/// iOS-side protocol extends the base with setters and a clear.
///
/// A protocol (rather than methods on the concrete type) so tests
/// can substitute a fake mutable store behind any surface that
/// writes credentials — onboarding view-models, sign-out flows.
public protocol MutableSecretStore: SecretStore {
    /// Persist `url` as the Immich server URL. Overwrites any
    /// existing value. Thread-safe at the Keychain layer.
    func setServerURL(_ url: URL) throws
    /// Persist `key` as the Immich API key. Overwrites any existing
    /// value.
    func setAPIKey(_ key: String) throws
    /// Persist the Immich user identity (UUID + email) discovered at
    /// setup time. Used as the per-user discriminator for cairn's
    /// per-server partition key. Pass `nil` for either field to leave
    /// it unchanged; pass empty string to clear individually.
    func setUserIdentity(id: String?, email: String?) throws
    /// Read the per-key activation timestamp map. Each entry is
    /// `<apiKeyFingerprint>: <Date the key first verified>`. Filtering
    /// the runs/journal UI by `entries.where { $0.timestamp >= map[fp] }`
    /// gives the user "this key sees only what this key has done"
    /// without partitioning data per key. Returns an empty map for
    /// upgrade installs — `AppDependencies` seeds the current key with
    /// `.distantPast` on first read so existing history is preserved.
    func keyActivationMap() throws -> [String: Date]
    /// Persist the per-key activation timestamp map. Replaces the full
    /// map on every write — caller is expected to merge before calling
    /// (the typical pattern: read, insert one entry, write back).
    func setKeyActivationMap(_ map: [String: Date]) throws
    /// Read the recent-servers list, sorted by `lastUsedAt` descending
    /// (most recently used first). Returns an empty array on installs
    /// that predate this storage. Powers onboarding's URL field
    /// autocomplete.
    func recentServers() throws -> [RecentServerEntry]
    /// Upsert a recent-server entry. If an entry with a matching
    /// canonicalized URL exists, its `lastUsedAt` is bumped and `email`
    /// updated; otherwise a new row is inserted. The list is capped at
    /// `RecentServerEntry.maxRetained` after the upsert (oldest dropped).
    func recordRecentServer(_ entry: RecentServerEntry) throws
    /// Wipe the recent-servers list without touching anything else.
    /// Surfaced through Settings → Privacy as a less-nuclear option
    /// than "Reset index — all accounts."
    func clearRecentServers() throws
    /// Remove every secret this store manages. Idempotent — safe to
    /// call on sign-out even if one secret was already missing.
    func clear() throws
}

/// One entry in the recent-servers list. Stored in Keychain as JSON.
/// `url` is canonicalized (trailing-slash stripped, lowercased host)
/// at insert time so deduplication works across casing/format
/// variations the user types differently across sessions.
///
/// No identity (email/userId) is stored here. Two users on the same
/// server produce one row in the autocomplete — tapping it fills the
/// URL and the user pastes whichever API key matches the account
/// they're signing in as. Identity context would only be load-bearing
/// in a future cached-credentials "switch account" flow; until then
/// it's decorative noise that misleadingly suggests one account is
/// "the" account for this URL.
public struct RecentServerEntry: Sendable, Codable, Equatable {
    public let url: String
    public let lastUsedAt: Date

    public init(url: String, lastUsedAt: Date = Date()) {
        self.url = url
        self.lastUsedAt = lastUsedAt
    }

    private enum CodingKeys: String, CodingKey {
        case url
        case lastUsedAt
    }

    public init(from decoder: Decoder) throws {
        // Tolerant of legacy JSON that included `email` — old payloads
        // decode cleanly because the unknown key is ignored. No
        // migration step needed; the next `recordRecentServer` call
        // will rewrite the file in the new shape.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.url = try c.decode(String.self, forKey: .url)
        self.lastUsedAt = try c.decode(Date.self, forKey: .lastUsedAt)
    }

    /// Cap on the retained list. Beyond this, the oldest entry drops
    /// on the next `recordRecentServer` call. Ten covers the realistic
    /// "I switch between a couple homelab boxes and a backup server"
    /// scenarios without storing arbitrary historical entries.
    public static let maxRetained: Int = 10

    /// Canonicalize a URL string for dedup: strip trailing slashes,
    /// lowercase the scheme + host, leave path/query intact. Returns
    /// the input unchanged if it can't parse — keeps the storage
    /// resilient to weird inputs (the user's typo is still saved).
    public static func canonicalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed) else { return trimmed }
        var c = comps
        c.scheme = c.scheme?.lowercased()
        c.host = c.host?.lowercased()
        var s = c.string ?? trimmed
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

/// Keychain-specific errors. Surfaces the raw `OSStatus` rather than
/// translating into curated cases — Keychain failures in production
/// are mostly one-off platform quirks (device locked, entitlement
/// missing, interaction not allowed) that callers log and report.
/// The numeric code plus `SecCopyErrorMessageString` carries the most
/// useful signal.
public enum KeychainError: Error, CustomStringConvertible, Equatable {
    /// The Keychain API returned a non-success `OSStatus`. The
    /// `description` includes `SecCopyErrorMessageString`'s text.
    case osStatus(OSStatus)
    /// An item exists under our service identifier but isn't UTF-8
    /// bytes — something else wrote to this slot.
    case unexpectedItemFormat

    public var description: String {
        switch self {
        case .osStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String?
                ?? "unknown Keychain error"
            return "Keychain error \(status): \(message)"
        case .unexpectedItemFormat:
            return "Keychain item exists but is not in the expected format"
        }
    }
}

/// Keychain-backed `SecretStore` for the Immich server URL and API
/// key.
///
/// **Struct with no mutable state.** The Keychain itself is the
/// source of truth and `SecItem*` calls are thread-safe, so the
/// wrapper only carries identifiers (`service`, account names). That
/// makes it trivially `Sendable`.
///
/// **Accessibility policy:** `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
/// - `*ThisDeviceOnly` opts out of iCloud Keychain sync. The API key
///   is per-device by intent — the user can revoke a single device
///   without touching the others, and we don't want the key replicated
///   to other devices in plaintext-equivalent form.
/// - `WhenUnlocked` blocks reads while the device is locked. cairn's
///   background sync only runs post-unlock anyway, so this adds
///   defense-in-depth without breaking workflows.
///
/// **Survival across reinstall:** paid Apple Developer accounts keep
/// Keychain items through reinstalls; free-tier provisioning profiles
/// regenerate on each install and wipe the Keychain. Onboarding
/// handles the "credentials missing" case regardless.
///
/// **Upsert strategy:** `SecItemUpdate` first, fall back to
/// `SecItemAdd` on `errSecItemNotFound`. Naive wrappers call
/// `SecItemAdd` unconditionally and surface `errSecDuplicateItem` on
/// rotation. Update-first minimizes calls in the common
/// (already-set, just rotating) case.
public struct KeychainSecretStore: MutableSecretStore, Sendable {
    /// `kSecAttrService` value that groups this store's items.
    /// Defaults to `"app.cairn.immich"`; override for tests.
    public let service: String
    /// `kSecAttrAccount` for the server URL row.
    public let urlAccount: String
    /// `kSecAttrAccount` for the API key row.
    public let keyAccount: String
    /// `kSecAttrAccount` for the cached Immich user UUID. Stored as
    /// a string. Absent for installs that predate user-identity
    /// caching (graceful upgrade — bootstrap will fetch and cache on
    /// the next successful verify).
    public let userIdAccount: String
    /// `kSecAttrAccount` for the cached Immich user email. Same
    /// treatment as `userIdAccount`.
    public let userEmailAccount: String
    /// `kSecAttrAccount` for the per-key activation-timestamp map.
    /// Stored as JSON `{ "<fingerprint>": <unixSeconds>, ... }`. Empty
    /// or missing on installs that predate per-key activation tracking;
    /// `AppDependencies` seeds the current key on bootstrap.
    public let keyActivationsAccount: String
    /// `kSecAttrAccount` for the recent-servers autocomplete list.
    /// Stored as a JSON array of `RecentServerEntry`. Wipeable
    /// independently of credentials via `clearRecentServers()`.
    public let recentServersAccount: String

    public init(service: String = "app.cairn.immich",
                urlAccount: String = "server-url",
                keyAccount: String = "api-key",
                userIdAccount: String = "user-id",
                userEmailAccount: String = "user-email",
                keyActivationsAccount: String = "key-activations",
                recentServersAccount: String = "recent-servers") {
        self.service = service
        self.urlAccount = urlAccount
        self.keyAccount = keyAccount
        self.userIdAccount = userIdAccount
        self.userEmailAccount = userEmailAccount
        self.keyActivationsAccount = keyActivationsAccount
        self.recentServersAccount = recentServersAccount
    }

    // MARK: - SecretStore

    public func serverURL() throws -> URL {
        let raw = try readString(account: urlAccount)
        guard let url = URL(string: raw) else {
            throw SecretStoreError.invalidURL(value: raw)
        }
        return url
    }

    public func apiKey() throws -> String {
        try readString(account: keyAccount)
    }

    public func userId() throws -> String? {
        try readOptionalString(account: userIdAccount)
    }

    public func userEmail() throws -> String? {
        try readOptionalString(account: userEmailAccount)
    }

    // MARK: - Writes

    public func setServerURL(_ url: URL) throws {
        try writeString(url.absoluteString, account: urlAccount)
    }

    public func setAPIKey(_ key: String) throws {
        try writeString(key, account: keyAccount)
    }

    public func setUserIdentity(id: String?, email: String?) throws {
        if let id, !id.isEmpty {
            try writeString(id, account: userIdAccount)
        } else if id?.isEmpty == true {
            try delete(account: userIdAccount)
        }
        if let email, !email.isEmpty {
            try writeString(email, account: userEmailAccount)
        } else if email?.isEmpty == true {
            try delete(account: userEmailAccount)
        }
    }

    public func keyActivationMap() throws -> [String: Date] {
        guard let raw = try readOptionalString(account: keyActivationsAccount) else {
            return [:]
        }
        guard let data = raw.data(using: .utf8) else {
            // Item exists but isn't UTF-8 — same defensive posture as
            // `unexpectedItemFormat` elsewhere. Treat as empty rather
            // than throwing so a corrupt slot doesn't brick onboarding.
            return [:]
        }
        let raw2 = (try? JSONDecoder().decode([String: Double].self, from: data)) ?? [:]
        var out: [String: Date] = [:]
        out.reserveCapacity(raw2.count)
        for (fp, secs) in raw2 {
            out[fp] = Date(timeIntervalSince1970: secs)
        }
        return out
    }

    public func setKeyActivationMap(_ map: [String: Date]) throws {
        if map.isEmpty {
            try delete(account: keyActivationsAccount)
            return
        }
        var encodable: [String: Double] = [:]
        encodable.reserveCapacity(map.count)
        for (fp, date) in map {
            encodable[fp] = date.timeIntervalSince1970
        }
        let data = try JSONEncoder().encode(encodable)
        guard let json = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedItemFormat
        }
        try writeString(json, account: keyActivationsAccount)
    }

    public func recentServers() throws -> [RecentServerEntry] {
        guard let raw = try readOptionalString(account: recentServersAccount) else {
            return []
        }
        guard let data = raw.data(using: .utf8) else {
            return []
        }
        let entries = (try? JSONDecoder().decode([RecentServerEntry].self, from: data)) ?? []
        return entries.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    public func recordRecentServer(_ entry: RecentServerEntry) throws {
        let canonical = RecentServerEntry.canonicalize(entry.url)
        var current = try recentServers()
        // Drop any matching canonicalized URL — we'll re-insert with
        // the new lastUsedAt below. Comparison is case-insensitive
        // on the canonical form.
        current.removeAll { RecentServerEntry.canonicalize($0.url).caseInsensitiveCompare(canonical) == .orderedSame }
        current.insert(
            RecentServerEntry(url: canonical, lastUsedAt: entry.lastUsedAt),
            at: 0
        )
        if current.count > RecentServerEntry.maxRetained {
            current = Array(current.prefix(RecentServerEntry.maxRetained))
        }
        let data = try JSONEncoder().encode(current)
        guard let json = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedItemFormat
        }
        try writeString(json, account: recentServersAccount)
    }

    public func clearRecentServers() throws {
        try delete(account: recentServersAccount)
    }

    public func clear() throws {
        try delete(account: urlAccount)
        try delete(account: keyAccount)
        try delete(account: userIdAccount)
        try delete(account: userEmailAccount)
        try delete(account: keyActivationsAccount)
        // `recentServersAccount` is intentionally preserved here.
        // Sign-out brings the user back to the onboarding flow,
        // and the whole point of the autocomplete is to make
        // returning to a known server fast — wiping it on
        // sign-out defeats that. Two explicit user-driven paths
        // wipe it: "Clear saved servers" (Settings → Danger zone
        // → just this list) and "Reset Index — all accounts"
        // (the nuclear, which calls `clearRecentServers()`
        // alongside its other wipes).
    }

    // MARK: - Keychain primitives

    /// Base query identifying this store's items. Every call narrows
    /// it with a specific account.
    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func readString(account: String) throws -> String {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let string = String(data: data, encoding: .utf8) else {
                throw KeychainError.unexpectedItemFormat
            }
            return string
        case errSecItemNotFound:
            throw SecretStoreError.missing(name: account)
        default:
            throw KeychainError.osStatus(status)
        }
    }

    /// Like `readString` but returns nil for missing items instead of
    /// throwing. Used for fields that aren't required (cached user
    /// identity) — pre-userId-caching installs simply have nothing
    /// here and we want graceful degradation, not an error.
    private func readOptionalString(account: String) throws -> String? {
        do {
            return try readString(account: account)
        } catch SecretStoreError.missing {
            return nil
        }
    }

    private func writeString(_ value: String, account: String) throws {
        let data = Data(value.utf8)

        // Update first — the common case once onboarding has run.
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            // Re-assert accessibility on every write so items created
            // under a different policy get corrected. Cheap; harmless
            // when the policy already matches.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            updateAttrs as CFDictionary
        )

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            // Fall through to add.
            break
        default:
            throw KeychainError.osStatus(updateStatus)
        }

        var addQuery = baseQuery(account: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.osStatus(addStatus)
        }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        // `errSecItemNotFound` is fine on delete — `clear()` must be
        // idempotent so sign-out succeeds when one secret was
        // already gone.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }
}
