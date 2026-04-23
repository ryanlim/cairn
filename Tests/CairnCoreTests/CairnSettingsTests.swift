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
        #expect(d.notifyOnAbort == true)
        #expect(d.verboseLogging == false)
        #expect(d.deletionStrictness == .trusting)
        #expect(d.quarantineDays == 14)
        #expect(d.iCloudDownloadLimitMB == 100)
        #expect(d.iCloudMaxEverBytesMB == nil)
    }

    @Test("quarantineDaysRange covers the documented 0...90 span")
    func quarantineDaysRangeIsDocumented() {
        #expect(CairnSettings.quarantineDaysRange == 0...90)
        #expect(CairnSettings.quarantineDaysRange.contains(CairnSettings.defaults.quarantineDays))
    }

    @Test("DeletionStrictness encodes as its raw string for stable on-disk format")
    func strictnessRawValueIsStable() throws {
        let strict = try JSONEncoder().encode(DeletionStrictness.strict)
        let trusting = try JSONEncoder().encode(DeletionStrictness.trusting)
        #expect(String(data: strict, encoding: .utf8) == #""strict""#)
        #expect(String(data: trusting, encoding: .utf8) == #""trusting""#)
    }

    @Test("round-trip encode-decode preserves every field, including new ones")
    func roundTripPreservesEveryField() throws {
        let original = CairnSettings(
            maxDeletePercent: 2.5,
            minDeleteFloor: 11,
            notifyOnAbort: false,
            verboseLogging: true,
            deletionStrictness: .strict,
            quarantineDays: 30,
            iCloudDownloadLimitMB: 250,
            iCloudMaxEverBytesMB: 2048
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CairnSettings.self, from: data)
        #expect(decoded == original)
        #expect(decoded.quarantineDays == 30)
        #expect(decoded.deletionStrictness == .strict)
        #expect(decoded.iCloudDownloadLimitMB == 250)
        #expect(decoded.iCloudMaxEverBytesMB == 2048)
    }

    @Test("legacy JSON without iCloudMaxEverBytesMB decodes as nil (hard ceiling off)")
    func legacyJSONMissingHardCeilingUsesDefault() throws {
        // A settings blob written before the hard-ceiling field existed.
        // Must decode without throwing and keep the feature disabled.
        let legacyJSON = """
        {
            "maxDeletePercent": 1.0,
            "minDeleteFloor": 5,
            "notifyOnAbort": true,
            "verboseLogging": false,
            "deletionStrictness": "trusting",
            "quarantineDays": 14,
            "iCloudDownloadLimitMB": 50
        }
        """
        let decoded = try JSONDecoder().decode(CairnSettings.self, from: Data(legacyJSON.utf8))
        #expect(decoded.iCloudMaxEverBytesMB == nil)
        #expect(decoded.iCloudDownloadLimitMB == 50)
    }

    @Test("legacy JSON without quarantineDays decodes with the default value")
    func legacyJSONMissingQuarantineDaysUsesDefault() throws {
        // A settings blob written before the quarantine field existed. The
        // custom init(from:) must tolerate the missing key.
        let legacyJSON = """
        {
            "maxDeletePercent": 1.0,
            "minDeleteFloor": 5,
            "notifyOnAbort": true,
            "verboseLogging": false,
            "deletionStrictness": "strict"
        }
        """
        let decoded = try JSONDecoder().decode(CairnSettings.self, from: Data(legacyJSON.utf8))
        #expect(decoded.quarantineDays == CairnSettings.defaults.quarantineDays)
        #expect(decoded.deletionStrictness == .strict)
        #expect(decoded.maxDeletePercent == 1.0)
    }

    @Test("legacy JSON without deletionStrictness falls back to the current default")
    func legacyJSONMissingStrictnessUsesDefault() throws {
        let legacyJSON = """
        {
            "maxDeletePercent": 1.0,
            "minDeleteFloor": 5,
            "notifyOnAbort": true,
            "verboseLogging": false
        }
        """
        let decoded = try JSONDecoder().decode(CairnSettings.self, from: Data(legacyJSON.utf8))
        #expect(decoded.deletionStrictness == CairnSettings.defaults.deletionStrictness)
        #expect(decoded.quarantineDays == CairnSettings.defaults.quarantineDays)
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
        #expect(loaded.deletionStrictness == .strict)
        #expect(loaded.quarantineDays == 21)
    }

    @Test("saved settings survive across store instances at the same path")
    func survivesAcrossInstances() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let first = JSONFileSettingsStore(path: path)
        let custom = CairnSettings(
            maxDeletePercent: 2.25,
            minDeleteFloor: 10,
            notifyOnAbort: false,
            verboseLogging: true,
            deletionStrictness: .strict,
            quarantineDays: 7
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
            notifyOnAbort: false,
            verboseLogging: true,
            deletionStrictness: .strict,
            quarantineDays: 60
        )
        try await store.save(first)

        // Second save flips everything back toward defaults; the expectation
        // is that load() returns exactly `second`, not a field-wise merge
        // with `first`.
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
}
