import Foundation
import Testing
@testable import CairnCore

@Suite("CairnExportPayload")
struct CairnExportPayloadTests {

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func samplePayload() -> CairnExportPayload {
        let exclusion = CairnExportPayload.ServerPayload.ExclusionRecord(
            checksum: "ck1",
            addedAt: date("2026-04-20T12:00:00Z"),
            fromRunId: "R1",
            reason: "user excluded"
        )
        let server = CairnExportPayload.ServerPayload(
            partitionKey: "host:abcd1234",
            normalizedURL: "https://immich.example.com/api",
            observed: ["aaaa", "bbbb", "cccc"],
            exclusions: [exclusion],
            journal: [
                #"{"runId":"R1","event":"runStarted"}"#,
                #"{"runId":"R1","event":"runCompleted"}"#,
            ]
        )
        return CairnExportPayload(
            exportedAt: date("2026-04-25T00:00:00Z"),
            exportedFrom: "iPhone 15 Pro",
            servers: [server],
            settings: CairnSettings.defaults
        )
    }

    @Test("a fully-populated payload round-trips through encode/decode unchanged")
    func roundTripFullyPopulated() throws {
        let original = samplePayload()
        let data = try CairnExportPayload.encode(original)
        let decoded = try CairnExportPayload.decode(from: data)
        #expect(decoded == original)
        #expect(decoded.version == CairnExportPayload.currentVersion)
    }

    @Test("a minimal payload (no settings, no exportedFrom, no servers) round-trips")
    func roundTripMinimal() throws {
        let original = CairnExportPayload(
            exportedAt: date("2026-04-25T00:00:00Z"),
            exportedFrom: nil,
            servers: [],
            settings: nil
        )
        let data = try CairnExportPayload.encode(original)
        let decoded = try CairnExportPayload.decode(from: data)
        #expect(decoded == original)
        #expect(decoded.servers.isEmpty)
        #expect(decoded.settings == nil)
        #expect(decoded.exportedFrom == nil)
    }

    @Test("decoding a payload with a future version throws .unsupportedVersion")
    func futureVersionRejected() throws {
        let json = """
        {
          "version": 999,
          "exportedAt": "2026-04-25T00:00:00Z",
          "servers": []
        }
        """
        let data = Data(json.utf8)
        #expect(throws: CairnExportPayload.ExportError.self) {
            _ = try CairnExportPayload.decode(from: data)
        }
        do {
            _ = try CairnExportPayload.decode(from: data)
            Issue.record("expected throw")
        } catch let error as CairnExportPayload.ExportError {
            switch error {
            case .unsupportedVersion(let v):
                #expect(v == 999)
            }
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test("a payload with an older or current version (≤ currentVersion) decodes successfully")
    func olderVersionAccepted() throws {
        // Older version (0) — tolerated; the decoder only rejects strictly
        // newer versions. Older payloads decode and the recipient is
        // expected to migrate them in-place if needed.
        let json = """
        {
          "version": 0,
          "exportedAt": "2026-04-25T00:00:00Z",
          "servers": []
        }
        """
        let data = Data(json.utf8)
        let decoded = try CairnExportPayload.decode(from: data)
        #expect(decoded.version == 0)
        #expect(decoded.servers.isEmpty)
    }

    @Test("optional top-level fields (exportedFrom, settings) absent from JSON decode as nil")
    func missingOptionalFieldsDecodeAsNil() throws {
        let json = """
        {
          "version": 1,
          "exportedAt": "2026-04-25T00:00:00Z",
          "servers": []
        }
        """
        let data = Data(json.utf8)
        let decoded = try CairnExportPayload.decode(from: data)
        #expect(decoded.exportedFrom == nil)
        #expect(decoded.settings == nil)
    }

    @Test("optional fields on ExclusionRecord (fromRunId, reason) absent from JSON decode as nil")
    func missingOptionalExclusionFieldsDecodeAsNil() throws {
        let json = """
        {
          "version": 1,
          "exportedAt": "2026-04-25T00:00:00Z",
          "servers": [
            {
              "partitionKey": "host:abcd1234",
              "normalizedURL": "https://immich.example.com/api",
              "observed": [],
              "exclusions": [
                {
                  "checksum": "ck1",
                  "addedAt": "2026-04-20T12:00:00Z"
                }
              ],
              "journal": []
            }
          ]
        }
        """
        let data = Data(json.utf8)
        let decoded = try CairnExportPayload.decode(from: data)
        #expect(decoded.servers.count == 1)
        let exclusion = decoded.servers[0].exclusions[0]
        #expect(exclusion.checksum == "ck1")
        #expect(exclusion.fromRunId == nil)
        #expect(exclusion.reason == nil)
    }

    @Test("unknown fields in the JSON are ignored (forward-compatible decode)")
    func unknownFieldsIgnored() throws {
        let json = """
        {
          "version": 1,
          "exportedAt": "2026-04-25T00:00:00Z",
          "exportedFrom": "iPhone",
          "servers": [],
          "settings": null,
          "futureField": "tolerate me",
          "anotherUnknown": { "nested": [1, 2, 3] }
        }
        """
        let data = Data(json.utf8)
        let decoded = try CairnExportPayload.decode(from: data)
        #expect(decoded.exportedFrom == "iPhone")
        #expect(decoded.servers.isEmpty)
    }

    @Test("encoded JSON sorts keys (sortedKeys output formatting is stable)")
    func encodingProducesSortedKeys() throws {
        let payload = CairnExportPayload(
            exportedAt: date("2026-04-25T00:00:00Z"),
            exportedFrom: "iPhone",
            servers: [],
            settings: nil
        )
        let data = try CairnExportPayload.encode(payload)
        let json = String(data: data, encoding: .utf8) ?? ""
        // exportedAt < exportedFrom < servers < version, alphabetically.
        let exportedAtIdx = json.range(of: "\"exportedAt\"")!.lowerBound
        let exportedFromIdx = json.range(of: "\"exportedFrom\"")!.lowerBound
        let serversIdx = json.range(of: "\"servers\"")!.lowerBound
        let versionIdx = json.range(of: "\"version\"")!.lowerBound
        #expect(exportedAtIdx < exportedFromIdx)
        #expect(exportedFromIdx < serversIdx)
        #expect(serversIdx < versionIdx)
    }

    @Test("nested ServerPayload and ExclusionRecord round-trip correctly")
    func nestedTypesRoundTrip() throws {
        let original = samplePayload()
        let data = try CairnExportPayload.encode(original)
        let decoded = try CairnExportPayload.decode(from: data)
        #expect(decoded.servers.count == 1)
        #expect(decoded.servers[0] == original.servers[0])
        #expect(decoded.servers[0].exclusions.count == 1)
        #expect(decoded.servers[0].exclusions[0] == original.servers[0].exclusions[0])
        #expect(decoded.servers[0].journal == original.servers[0].journal)
        #expect(decoded.servers[0].observed == original.servers[0].observed)
    }
}
