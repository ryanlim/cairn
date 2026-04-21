import Foundation
import Testing
@testable import CairnCore

@Suite("ImmichClient.normalize")
struct ImmichClientURLTests {
    @Test("bare host gets /api appended")
    func bareHost() {
        #expect(ImmichClient.normalize(URL(string: "https://photos.example.com")!).absoluteString == "https://photos.example.com/api")
    }

    @Test("trailing slash gets /api appended")
    func trailingSlash() {
        #expect(ImmichClient.normalize(URL(string: "https://photos.example.com/")!).absoluteString == "https://photos.example.com/api")
    }

    @Test("URL already ending in /api is unchanged")
    func alreadyApi() {
        let url = URL(string: "https://photos.example.com/api")!
        #expect(ImmichClient.normalize(url) == url)
    }

    @Test("URL ending in /api/ is unchanged")
    func alreadyApiTrailingSlash() {
        let url = URL(string: "https://photos.example.com/api/")!
        #expect(ImmichClient.normalize(url) == url)
    }

    @Test("subpath install with /api gets preserved")
    func subpathInstall() {
        let url = URL(string: "https://example.com/immich/api")!
        #expect(ImmichClient.normalize(url) == url)
    }
}
