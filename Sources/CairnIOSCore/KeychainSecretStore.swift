import Foundation
import Security
import CairnCore

/// Mutable variant of `SecretStore`. The base protocol in `CairnCore` is
/// deliberately read-only because the CLI populates secrets out-of-band
/// (a `.env` file loaded at process start). The iOS app, by contrast,
/// has to *write* secrets during onboarding and rotate them later, so
/// we add an iOS-side protocol the concrete Keychain type conforms to.
///
/// Defining this as a protocol (rather than just methods on the concrete
/// type) lets test code substitute a fake mutable store for any iOS
/// surface — onboarding view-models, sign-out flows — that needs to
/// write credentials.
public protocol MutableSecretStore: SecretStore {
    func setServerURL(_ url: URL) throws
    func setAPIKey(_ key: String) throws
    /// Remove every secret this store manages. Used by sign-out.
    func clear() throws
}

/// Errors specific to the Keychain-backed implementation. We surface the
/// raw `OSStatus` rather than translating into a curated set of cases
/// because Keychain failures in production tend to be one-off platform
/// quirks (locked, no-entitlement, interaction-not-allowed) that callers
/// will mostly just log and report. The numeric code plus
/// `SecCopyErrorMessageString` is the most useful thing to surface.
public enum KeychainError: Error, CustomStringConvertible, Equatable {
    case osStatus(OSStatus)
    /// The Keychain returned a value of an unexpected type (e.g. a non-Data
    /// blob where we expected UTF-8 bytes). Indicates an item created by
    /// some other tool under our service identifier.
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

/// Keychain-backed `SecretStore` for the Immich server URL and API key.
///
/// Why a `struct` with no mutable state: the Keychain is the source of
/// truth, and `SecItem*` calls are themselves thread-safe. The wrapper
/// only carries identifiers (`service`, account names) so it's trivially
/// `Sendable` and safe to share across actors.
///
/// Why `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`:
/// - `*ThisDeviceOnly` opts the item out of iCloud Keychain sync. The
///   Immich API key is per-device by intent (the user can revoke a
///   single device without touching others) and we do not want it
///   replicated to other devices in plaintext-equivalent form.
/// - `WhenUnlocked` blocks reads while the device is locked; cairn's
///   background sync runs only after the user unlocks anyway, so this
///   adds defense-in-depth without breaking workflows.
///
/// Why upsert (update-then-add) instead of always add: many naive
/// Keychain wrappers call `SecItemAdd` unconditionally and surface
/// `errSecDuplicateItem` to callers when the item already exists — which
/// is exactly what onboarding-then-rotation will trigger. We try
/// `SecItemUpdate` first and fall back to `SecItemAdd` on
/// `errSecItemNotFound`. Either order works; this one minimizes the
/// number of calls in the common (already-set, just rotating) case.
public struct KeychainSecretStore: MutableSecretStore, Sendable {
    public let service: String
    public let urlAccount: String
    public let keyAccount: String

    public init(service: String = "app.cairn.immich",
                urlAccount: String = "server-url",
                keyAccount: String = "api-key") {
        self.service = service
        self.urlAccount = urlAccount
        self.keyAccount = keyAccount
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

    // MARK: - Writes

    public func setServerURL(_ url: URL) throws {
        try writeString(url.absoluteString, account: urlAccount)
    }

    public func setAPIKey(_ key: String) throws {
        try writeString(key, account: keyAccount)
    }

    public func clear() throws {
        try delete(account: urlAccount)
        try delete(account: keyAccount)
    }

    // MARK: - Keychain primitives

    /// Base query identifying *this store's* items. Every call narrows
    /// it with the specific account.
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

    private func writeString(_ value: String, account: String) throws {
        let data = Data(value.utf8)

        // Try update first (the common case once onboarding has run).
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            // Re-assert accessibility on every write so an item created
            // under a different policy gets corrected. Cheap and harmless
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
        // `errSecItemNotFound` is fine for a delete — clear() should be
        // idempotent so sign-out works even if one secret was already gone.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }
}
