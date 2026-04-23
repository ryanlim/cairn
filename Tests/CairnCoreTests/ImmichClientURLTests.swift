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

@Suite("ImmichClient.parseServerURL")
struct ImmichClientParseServerURLTests {
    @Test("bare hostname gets https:// prepended")
    func bareHostname() {
        let url = ImmichClient.parseServerURL("immich.example.com")
        #expect(url?.absoluteString == "https://immich.example.com")
    }

    @Test("explicit https scheme preserved")
    func explicitHTTPS() {
        #expect(ImmichClient.parseServerURL("https://immich.example.com")?.absoluteString == "https://immich.example.com")
    }

    @Test("explicit http scheme preserved (for home-LAN installs)")
    func explicitHTTP() {
        #expect(ImmichClient.parseServerURL("http://immich.local:2283")?.absoluteString == "http://immich.local:2283")
    }

    @Test("leading + trailing whitespace is stripped")
    func whitespaceStripped() {
        #expect(ImmichClient.parseServerURL("  immich.example.com  ")?.absoluteString == "https://immich.example.com")
    }

    @Test("trailing slash is preserved (normalize handles it downstream)")
    func trailingSlashPreserved() {
        let url = ImmichClient.parseServerURL("https://immich.example.com/")
        #expect(url?.absoluteString == "https://immich.example.com/")
    }

    @Test("already-suffixed /api is preserved end-to-end")
    func suffixedAPI() {
        let parsed = ImmichClient.parseServerURL("https://immich.example.com/api")
        #expect(parsed?.absoluteString == "https://immich.example.com/api")
        // Full round-trip through normalize should be idempotent.
        #expect(ImmichClient.normalize(parsed!).absoluteString == "https://immich.example.com/api")
    }

    @Test("IP address input gets https:// prepended")
    func ipAddress() {
        #expect(ImmichClient.parseServerURL("192.168.1.10")?.absoluteString == "https://192.168.1.10")
    }

    @Test("IP address with explicit port")
    func ipAddressWithPort() {
        let url = ImmichClient.parseServerURL("192.168.1.10:2283")
        #expect(url?.absoluteString == "https://192.168.1.10:2283")
        #expect(url?.port == 2283)
    }

    @Test("empty string → nil")
    func emptyInput() {
        #expect(ImmichClient.parseServerURL("") == nil)
    }

    @Test("whitespace-only string → nil")
    func whitespaceOnly() {
        #expect(ImmichClient.parseServerURL("   ") == nil)
    }

    @Test("foreign scheme → nil")
    func foreignScheme() {
        #expect(ImmichClient.parseServerURL("ftp://immich.example.com") == nil)
        #expect(ImmichClient.parseServerURL("ws://immich.example.com") == nil)
        #expect(ImmichClient.parseServerURL("file:///etc/passwd") == nil)
    }

    @Test("pure garbage → nil")
    func garbage() {
        #expect(ImmichClient.parseServerURL("not a url at all") == nil)
    }

    @Test("https-prefixed garbage → nil (no host)")
    func schemeButNoHost() {
        #expect(ImmichClient.parseServerURL("https://") == nil)
    }
}
