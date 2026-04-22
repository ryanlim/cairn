import Foundation
import Testing
@testable import CairnCore

@Suite("CairnSettings")
struct CairnSettingsTests {

    @Test("defaults match the documented factory values")
    func defaultsMatchDocumented() {
        let d = CairnSettings.defaults
        #expect(d.maxDeletePercent == 1.0)
        #expect(d.minDeleteFloor == 5)
        #expect(d.dryRunByDefault == false)
        #expect(d.notifyOnAbort == true)
        #expect(d.verboseLogging == false)
        #expect(d.deletionStrictness == .strict)
    }

    @Test("DeletionStrictness encodes as its raw string for stable on-disk format")
    func strictnessRawValueIsStable() throws {
        let strict = try JSONEncoder().encode(DeletionStrictness.strict)
        let trusting = try JSONEncoder().encode(DeletionStrictness.trusting)
        #expect(String(data: strict, encoding: .utf8) == #""strict""#)
        #expect(String(data: trusting, encoding: .utf8) == #""trusting""#)
    }
}

@Suite("JSONFileSettingsStore")
struct JSONFileSettingsStoreTests {

    private func tempPath() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "settings-\(UUID().uuidString).json")
    }

    @Test("missing file loads as defaults")
    func missingLoadsDefaults() async throws {
        let store = JSONFileSettingsStore(path: tempPath())
        let loaded = try await store.load()
        #expect(loaded == .defaults)
    }

    @Test("save + load round-trips every field")
    func roundTripPreservesFields() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileSettingsStore(path: path)
        let custom = CairnSettings(
            maxDeletePercent: 3.5,
            minDeleteFloor: 42,
            dryRunByDefault: true,
            notifyOnAbort: false,
            verboseLogging: true
        )
        try await store.save(custom)

        let loaded = try await store.load()
        #expect(loaded == custom)
        #expect(loaded.maxDeletePercent == 3.5)
        #expect(loaded.minDeleteFloor == 42)
        #expect(loaded.dryRunByDefault == true)
        #expect(loaded.notifyOnAbort == false)
        #expect(loaded.verboseLogging == true)
    }

    @Test("saved settings survive across store instances at the same path")
    func survivesAcrossInstances() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let first = JSONFileSettingsStore(path: path)
        let custom = CairnSettings(
            maxDeletePercent: 2.25,
            minDeleteFloor: 10,
            dryRunByDefault: true,
            notifyOnAbort: false,
            verboseLogging: true
        )
        try await first.save(custom)

        let second = JSONFileSettingsStore(path: path)
        #expect(try await second.load() == custom)
    }

    @Test("save replaces previous contents — no merging with prior state")
    func saveReplacesPrevious() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileSettingsStore(path: path)

        let first = CairnSettings(
            maxDeletePercent: 9.0,
            minDeleteFloor: 99,
            dryRunByDefault: true,
            notifyOnAbort: false,
            verboseLogging: true
        )
        try await store.save(first)

        // Second save flips everything back toward defaults; the expectation
        // is that load() returns exactly `second`, not a field-wise merge
        // with `first`.
        let second = CairnSettings(
            maxDeletePercent: 0.5,
            minDeleteFloor: 1,
            dryRunByDefault: false,
            notifyOnAbort: true,
            verboseLogging: false
        )
        try await store.save(second)

        let loaded = try await store.load()
        #expect(loaded == second)
        #expect(loaded != first)
    }
}
