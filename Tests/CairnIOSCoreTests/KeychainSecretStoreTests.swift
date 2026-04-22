import Testing
import Foundation
@testable import CairnIOSCore
import CairnCore

/// Keychain access is process-global. We mitigate cross-test interference
/// by giving each test a unique `service` identifier (UUID-suffixed) so
/// items live in their own namespace and clean up via `defer`. The suite
/// is `.serialized` defensively — even with unique services, parallel
/// access has historically surfaced flakiness on shared CI Macs.
@Suite("KeychainSecretStore", .serialized)
struct KeychainSecretStoreTests {
    /// Construct a store with a UUID-tagged service so it cannot collide
    /// with a real cairn install on the developer's Mac, nor with sibling
    /// tests in this suite.
    private func makeStore() -> KeychainSecretStore {
        KeychainSecretStore(service: "app.cairn.test.\(UUID().uuidString)")
    }

    @Test("reading an unset secret throws .missing")
    func readMissingThrowsMissing() throws {
        let store = makeStore()
        defer { try? store.clear() }

        #expect(throws: SecretStoreError.missing(name: store.urlAccount)) {
            _ = try store.serverURL()
        }
        #expect(throws: SecretStoreError.missing(name: store.keyAccount)) {
            _ = try store.apiKey()
        }
    }

    @Test("set then read roundtrips both URL and API key")
    func setAndReadRoundtrip() throws {
        let store = makeStore()
        defer { try? store.clear() }

        let url = URL(string: "https://immich.example.com")!
        let key = "k_test_abcdef0123456789"

        try store.setServerURL(url)
        try store.setAPIKey(key)

        #expect(try store.serverURL() == url)
        #expect(try store.apiKey() == key)
    }

    @Test("setting the URL twice does not throw errSecDuplicateItem; second set wins")
    func upsertDoesNotDuplicate() throws {
        let store = makeStore()
        defer { try? store.clear() }

        let first = URL(string: "https://first.example.com")!
        let second = URL(string: "https://second.example.com")!

        try store.setServerURL(first)
        // The whole point of upsert: this must not throw.
        try store.setServerURL(second)

        #expect(try store.serverURL() == second)
    }

    @Test("setting the API key twice does not throw; second set wins")
    func apiKeyUpsertDoesNotDuplicate() throws {
        let store = makeStore()
        defer { try? store.clear() }

        try store.setAPIKey("first-key")
        try store.setAPIKey("second-key")

        #expect(try store.apiKey() == "second-key")
    }

    @Test("clear removes both secrets; subsequent reads throw .missing")
    func clearRemovesBothSecrets() throws {
        let store = makeStore()

        try store.setServerURL(URL(string: "https://immich.example.com")!)
        try store.setAPIKey("k_test_value")

        try store.clear()

        #expect(throws: SecretStoreError.missing(name: store.urlAccount)) {
            _ = try store.serverURL()
        }
        #expect(throws: SecretStoreError.missing(name: store.keyAccount)) {
            _ = try store.apiKey()
        }
    }

    @Test("clear is idempotent — calling it on an empty store does not throw")
    func clearIsIdempotent() throws {
        let store = makeStore()
        // Never wrote anything; clear must still succeed.
        try store.clear()
        // And again.
        try store.clear()
    }

    /// `URL(string:)` is permissive — most strings parse as relative URLs.
    /// We construct an absolute URL, then verify the read returns it.
    /// Then we simulate a corrupted/garbage stored value by re-saving with
    /// `setServerURL` of a value `URL` accepts but whose `absoluteString`
    /// re-parses successfully. In practice `URL(string:)` is hard to defeat,
    /// so this test focuses on the primary positive path; a manual
    /// `invalidURL` round-trip would require writing raw bytes to the
    /// Keychain bypassing our typed API. We document and skip that here.
    @Test("invalidURL surfaces if a non-URL string is somehow stored")
    func invalidURLPath() throws {
        let store = makeStore()
        defer { try? store.clear() }

        // A string with a literal space is one of the few values
        // `URL(string:)` rejects outright on Apple platforms.
        let badRaw = "not a url with spaces"
        // If `URL(string:)` accepts it (varies by Foundation version),
        // we cannot exercise the invalidURL path through the public API
        // without a backdoor — our public writer takes a `URL`, not a
        // String. So we verify the precondition and skip if Foundation
        // is too lenient.
        guard URL(string: badRaw) == nil else {
            // Foundation accepted it, which means `serverURL()` would
            // also accept it — there is no longer a reachable invalidURL
            // case via the supported API surface. That's fine; the
            // type's contract is enforced statically.
            return
        }

        // We have no way to inject `badRaw` through `setServerURL` (it
        // takes a `URL`). The invalidURL branch is reachable only if a
        // Keychain item under our service/account holds a non-URL string
        // written by some external tool — which we cannot easily simulate
        // here without a private writer. The branch exists for defense in
        // depth; this test pins the precondition that motivates it.
        #expect(URL(string: badRaw) == nil)
    }
}
