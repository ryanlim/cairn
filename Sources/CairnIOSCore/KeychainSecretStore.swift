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
    /// Remove every secret this store manages. Idempotent — safe to
    /// call on sign-out even if one secret was already missing.
    func clear() throws
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

    public init(service: String = "app.cairn.immich",
                urlAccount: String = "server-url",
                keyAccount: String = "api-key",
                userIdAccount: String = "user-id",
                userEmailAccount: String = "user-email") {
        self.service = service
        self.urlAccount = urlAccount
        self.keyAccount = keyAccount
        self.userIdAccount = userIdAccount
        self.userEmailAccount = userEmailAccount
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

    public func clear() throws {
        try delete(account: urlAccount)
        try delete(account: keyAccount)
        try delete(account: userIdAccount)
        try delete(account: userEmailAccount)
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
