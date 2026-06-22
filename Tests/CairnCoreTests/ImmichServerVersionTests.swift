import Foundation
import Testing
@testable import CairnCore

@Suite("ServerVersion + supported-range advisory")
struct ImmichServerVersionTests {

    // MARK: - Decode (across Immich versions)

    @Test("decodes the 2.x shape (major/minor/patch, no prerelease)")
    func decode2x() throws {
        let json = Data(#"{"major":2,"minor":7,"patch":5}"#.utf8)
        let v = try JSONDecoder().decode(ServerVersion.self, from: json)
        #expect(v == ServerVersion(major: 2, minor: 7, patch: 5))
        #expect(v.prerelease == nil)
        #expect(v.description == "2.7.5")
        #expect(v.majorMinor == "2.7")
    }

    @Test("decodes the 3.0 shape with the new nullable prerelease field")
    func decode3xPrerelease() throws {
        let json = Data(#"{"major":3,"minor":0,"patch":0,"prerelease":2}"#.utf8)
        let v = try JSONDecoder().decode(ServerVersion.self, from: json)
        #expect(v == ServerVersion(major: 3, minor: 0, patch: 0, prerelease: 2))
        #expect(v.description == "3.0.0")
    }

    @Test("tolerates a null prerelease and unknown future fields")
    func decodeTolerant() throws {
        let json = Data(#"{"major":3,"minor":1,"patch":0,"prerelease":null,"somethingNew":"ignored"}"#.utf8)
        let v = try JSONDecoder().decode(ServerVersion.self, from: json)
        #expect(v == ServerVersion(major: 3, minor: 1, patch: 0))
    }

    // MARK: - Ordering

    @Test("Comparable orders by major, then minor, then patch (prerelease ignored)")
    func ordering() {
        #expect(ServerVersion(major: 2, minor: 7, patch: 5) < ServerVersion(major: 3, minor: 0, patch: 0))
        #expect(ServerVersion(major: 2, minor: 7, patch: 5) < ServerVersion(major: 2, minor: 8, patch: 0))
        #expect(ServerVersion(major: 2, minor: 7, patch: 5) < ServerVersion(major: 2, minor: 7, patch: 6))
        #expect(!(ServerVersion(major: 2, minor: 7, patch: 5) < ServerVersion(major: 2, minor: 7, patch: 5)))
        // prerelease is not part of ordering
        #expect(!(ServerVersion(major: 3, minor: 0, patch: 0, prerelease: 2) < ServerVersion(major: 3, minor: 0, patch: 0)))
    }

    // MARK: - Advisory policy

    @Test("advisory fires only for a newer major than verified")
    func advisoryNewerMajor() {
        let advisory = ImmichVersionSupport.advisory(for: ServerVersion(major: 3, minor: 0, patch: 0))
        #expect(advisory != nil)
        #expect(advisory?.contains("3.0.0") == true)
        // References the verified major.minor so the copy is concrete.
        #expect(advisory?.contains(ImmichVersionSupport.lastVerified.majorMinor) == true)
    }

    @Test("no advisory for the verified version, an older one, or a newer minor/patch")
    func noAdvisoryWithinMajor() {
        #expect(ImmichVersionSupport.advisory(for: ImmichVersionSupport.lastVerified) == nil)
        #expect(ImmichVersionSupport.advisory(for: ServerVersion(major: 1, minor: 130, patch: 0)) == nil)
        // Newer minor/patch on the same major is frequent + safe → no nag.
        #expect(ImmichVersionSupport.advisory(for: ServerVersion(major: 2, minor: 9, patch: 0)) == nil)
        #expect(ImmichVersionSupport.advisory(for: ServerVersion(major: 2, minor: 7, patch: 9)) == nil)
    }
}

@Suite("ImmichClient.serverVersion over mocked HTTP", .serialized)
struct ImmichServerVersionHTTPTests {
    private func makeClient() -> (client: ImmichClient, mock: MockSession) {
        let mock = MockURLProtocol.session()
        let client = ImmichClient(baseURL: URL(string: "https://photos.example.com")!, apiKey: "K", session: mock.session)
        return (client, mock)
    }

    @Test("GETs /api/server/version and decodes the counts")
    func serverVersionSuccess() async throws {
        let (client, mock) = makeClient()
        let seenURL = Ref<URL?>(nil)
        mock.handler = { req in
            seenURL.value = req.url
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"major":2,"minor":7,"patch":5}"#.utf8))
        }
        let v = try await client.serverVersion()
        #expect(seenURL.value?.absoluteString == "https://photos.example.com/api/server/version")
        #expect(v == ServerVersion(major: 2, minor: 7, patch: 5))
    }
}

@Suite("AssetItemDTO decode resilience")
struct AssetItemDTODecodeTests {
    private func decode(_ json: String) throws -> AssetItemDTO {
        try JSONDecoder().decode(AssetItemDTO.self, from: Data(json.utf8))
    }

    @Test("decodes a full asset and maps to ServerAsset")
    func fullAsset() throws {
        let dto = try decode(#"""
        {"id":"abc","checksum":"y+base64=","livePhotoVideoId":"vid1","isTrashed":false,
         "originalFileName":"IMG_1.HEIC","fileCreatedAt":"2026-01-02T03:04:05.000Z",
         "thumbhash":"TH","deviceAssetId":"local-1"}
        """#)
        #expect(dto.id == "abc")
        let asset = dto.asServerAsset
        #expect(asset.originalFileName == "IMG_1.HEIC")
        #expect(asset.thumbhash == "TH")
        #expect(asset.fileCreatedAt != nil)
        #expect(asset.deviceAssetId == "local-1")
    }

    @Test("tolerates absent optional fields — incl. deviceAssetId removed in a future Immich")
    func missingOptionals() throws {
        // Only the required id/checksum/isTrashed present.
        let dto = try decode(#"{"id":"x","checksum":"c=","isTrashed":true}"#)
        let asset = dto.asServerAsset
        #expect(asset.id == "x")
        #expect(asset.isTrashed == true)
        #expect(asset.originalFileName == nil)
        #expect(asset.fileCreatedAt == nil)
        #expect(asset.deviceAssetId == nil)
    }

    @Test("ignores unknown future fields (additive upstream change is a non-event)")
    func ignoresUnknownFields() throws {
        let dto = try decode(#"""
        {"id":"y","checksum":"c=","isTrashed":false,"someNewField":{"nested":true},"ocr":"text"}
        """#)
        #expect(dto.id == "y")
    }

    @Test("parses fileCreatedAt both with and without fractional seconds")
    func fractionalAndPlainDates() throws {
        let frac = try decode(#"{"id":"a","checksum":"c=","isTrashed":false,"fileCreatedAt":"2026-01-02T03:04:05.123Z"}"#)
        let plain = try decode(#"{"id":"b","checksum":"c=","isTrashed":false,"fileCreatedAt":"2026-01-02T03:04:05Z"}"#)
        #expect(frac.asServerAsset.fileCreatedAt != nil)
        #expect(plain.asServerAsset.fileCreatedAt != nil)
    }
}
