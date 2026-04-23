import Foundation
import Testing
@testable import CairnIOSCore
@testable import CairnCore

// Serialized: UserDefaults suites are process-global, and even though each
// test scopes to its own random suite name, running them serially keeps
// any future cross-test interaction (or accidental shared key) honest.
@Suite("UserDefaultsSettingsStore", .serialized)
struct UserDefaultsSettingsStoreTests {

    /// Fresh per-test suite + cleanup helper. Returning the suite name as
    /// well so the test can call `removePersistentDomain(forName:)` to nuke
    /// any persisted bytes the suite created on disk.
    private func makeSuite() -> (UserDefaults, String) {
        let name = "test-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: name) else {
            fatalError("UserDefaults(suiteName:) returned nil for \(name)")
        }
        return (suite, name)
    }

    @Test("fresh suite with no key set loads as defaults")
    func freshSuiteLoadsDefaults() async throws {
        let (suite, name) = makeSuite()
        defer { suite.removePersistentDomain(forName: name) }

        let store = UserDefaultsSettingsStore(defaults: suite)
        let loaded = try await store.load()
        #expect(loaded == .defaults)
    }

    @Test("save + load round-trips every field")
    func roundTripPreservesFields() async throws {
        let (suite, name) = makeSuite()
        defer { suite.removePersistentDomain(forName: name) }

        let store = UserDefaultsSettingsStore(defaults: suite)
        let custom = CairnSettings(
            maxDeletePercent: 3.5,
            minDeleteFloor: 42,
            notifyOnAbort: false,
            verboseLogging: true,
            deletionStrictness: .strict,
            quarantineDays: 21
        )
        try await store.save(custom)

        let loaded = try await store.load()
        #expect(loaded == custom)
        #expect(loaded.maxDeletePercent == 3.5)
        #expect(loaded.minDeleteFloor == 42)
        #expect(loaded.notifyOnAbort == false)
        #expect(loaded.verboseLogging == true)
        #expect(loaded.quarantineDays == 21)
        #expect(loaded.deletionStrictness == .strict)
    }

    @Test("save replaces previous contents — no merging with prior state")
    func saveReplacesPrevious() async throws {
        let (suite, name) = makeSuite()
        defer { suite.removePersistentDomain(forName: name) }

        let store = UserDefaultsSettingsStore(defaults: suite)

        let first = CairnSettings(
            maxDeletePercent: 9.0,
            minDeleteFloor: 99,
            notifyOnAbort: false,
            verboseLogging: true,
            deletionStrictness: .strict,
            quarantineDays: 60
        )
        try await store.save(first)

        // Second save flips everything back toward defaults — the expectation
        // is that load() returns exactly `second`, not a field-wise merge
        // with `first`. Mirrors the same invariant the JSONFile store carries.
        let second = CairnSettings(
            maxDeletePercent: 0.5,
            minDeleteFloor: 1,
            notifyOnAbort: true,
            verboseLogging: false,
            deletionStrictness: .trusting,
            quarantineDays: 0
        )
        try await store.save(second)

        let loaded = try await store.load()
        #expect(loaded == second)
        #expect(loaded != first)
    }

    @Test("corrupted data on disk fails soft to defaults rather than throwing")
    func corruptedDataFailsSoft() async throws {
        let (suite, name) = makeSuite()
        defer { suite.removePersistentDomain(forName: name) }

        let key = "app.cairn.settings"
        // Bytes that are valid `Data` but emphatically not JSON-decodable as
        // CairnSettings. Could happen via a downgrade from a future schema or
        // an external process scribbling on our key.
        suite.set(Data("not json".utf8), forKey: key)

        let store = UserDefaultsSettingsStore(defaults: suite, key: key)
        // Must not throw — fail-soft contract documented on `load()`.
        let loaded = try await store.load()
        #expect(loaded == .defaults)
    }

    @Test("custom key parameter is honored for both read and write")
    func customKeyIsHonored() async throws {
        let (suite, name) = makeSuite()
        defer { suite.removePersistentDomain(forName: name) }

        let customKey = "app.cairn.settings.custom-\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(defaults: suite, key: customKey)

        let custom = CairnSettings(
            maxDeletePercent: 2.0,
            minDeleteFloor: 7,
            notifyOnAbort: true,
            verboseLogging: false,
            deletionStrictness: .strict,
            quarantineDays: 3
        )
        try await store.save(custom)

        // The store reads back what it wrote.
        let loaded = try await store.load()
        #expect(loaded == custom)

        // Sanity: the data really did land under the custom key, not the default.
        #expect(suite.data(forKey: customKey) != nil)
        #expect(suite.data(forKey: "app.cairn.settings") == nil)

        // And a sibling store pointed at the default key sees a fresh-install
        // load — confirming the key parameter, not the type, is what scopes reads.
        let defaultKeyStore = UserDefaultsSettingsStore(defaults: suite)
        #expect(try await defaultKeyStore.load() == .defaults)
    }
}
