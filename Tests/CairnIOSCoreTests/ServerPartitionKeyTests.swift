import Testing
@testable import CairnIOSCore
import Foundation

@Suite("ServerPartitionKey")
struct ServerPartitionKeyTests {

    @Test("Basic HTTPS URL")
    func basicHTTPS() {
        let key = ServerPartitionKey(from: URL(string: "https://photos.example.com")!)
        #expect(key.directoryName == "https_photos.example.com")
    }

    @Test("HTTP URL preserved")
    func httpPreserved() {
        let key = ServerPartitionKey(from: URL(string: "http://immich.local")!)
        #expect(key.directoryName == "http_immich.local")
    }

    @Test("Non-default port included")
    func nonDefaultPort() {
        let key = ServerPartitionKey(from: URL(string: "http://immich.local:2283")!)
        #expect(key.directoryName == "http_immich.local_2283")
    }

    @Test("Default port 443 omitted")
    func defaultHTTPSPort() {
        let key = ServerPartitionKey(from: URL(string: "https://photos.example.com:443")!)
        let keyNoPort = ServerPartitionKey(from: URL(string: "https://photos.example.com")!)
        #expect(key == keyNoPort)
    }

    @Test("Default port 80 omitted")
    func defaultHTTPPort() {
        let key = ServerPartitionKey(from: URL(string: "http://photos.example.com:80")!)
        let keyNoPort = ServerPartitionKey(from: URL(string: "http://photos.example.com")!)
        #expect(key == keyNoPort)
    }

    @Test("Scheme case insensitive")
    func schemeCaseInsensitive() {
        let upper = ServerPartitionKey(from: URL(string: "HTTPS://Photos.Example.Com")!)
        let lower = ServerPartitionKey(from: URL(string: "https://photos.example.com")!)
        #expect(upper == lower)
    }

    @Test("Host case insensitive")
    func hostCaseInsensitive() {
        let a = ServerPartitionKey(from: URL(string: "https://IMMICH.HOME.ARPA")!)
        let b = ServerPartitionKey(from: URL(string: "https://immich.home.arpa")!)
        #expect(a == b)
    }

    @Test("Path stripped")
    func pathStripped() {
        let withPath = ServerPartitionKey(from: URL(string: "https://photos.example.com/api")!)
        let withoutPath = ServerPartitionKey(from: URL(string: "https://photos.example.com")!)
        #expect(withPath == withoutPath)
    }

    @Test("Trailing slash stripped")
    func trailingSlashStripped() {
        let withSlash = ServerPartitionKey(from: URL(string: "https://photos.example.com/")!)
        let withoutSlash = ServerPartitionKey(from: URL(string: "https://photos.example.com")!)
        #expect(withSlash == withoutSlash)
    }

    @Test("Different servers produce different keys")
    func differentServers() {
        let a = ServerPartitionKey(from: URL(string: "https://server-a.example.com")!)
        let b = ServerPartitionKey(from: URL(string: "https://server-b.example.com")!)
        #expect(a != b)
    }

    @Test("Same server different ports produce different keys")
    func differentPorts() {
        let a = ServerPartitionKey(from: URL(string: "http://immich.local:2283")!)
        let b = ServerPartitionKey(from: URL(string: "http://immich.local:8080")!)
        #expect(a != b)
    }

    @Test("Directory name is filesystem safe")
    func filesystemSafe() {
        let key = ServerPartitionKey(from: URL(string: "https://photos.example.com:8443")!)
        let forbidden: [Character] = ["/", ":", "?", "*", "<", ">", "|", "\"", "\\"]
        for char in forbidden {
            #expect(!key.directoryName.contains(char), "Contains forbidden char: \(char)")
        }
    }

    @Test("Stable across calls")
    func stableAcrossCalls() {
        let url = URL(string: "https://photos.example.com:2283")!
        let a = ServerPartitionKey(from: url)
        let b = ServerPartitionKey(from: url)
        #expect(a == b)
        #expect(a.directoryName == b.directoryName)
    }

    @Test("IP address works")
    func ipAddress() {
        let key = ServerPartitionKey(from: URL(string: "http://192.168.1.100:2283")!)
        #expect(key.directoryName == "http_192.168.1.100_2283")
    }

    @Test("Query and fragment stripped")
    func queryAndFragmentStripped() {
        let withQuery = ServerPartitionKey(from: URL(string: "https://photos.example.com?foo=bar#baz")!)
        let clean = ServerPartitionKey(from: URL(string: "https://photos.example.com")!)
        #expect(withQuery == clean)
    }

    // MARK: - Per-user partitioning (Wave 5+)

    @Test("nil userId matches legacy URL-only directoryName for backward compat")
    func nilUserIdIsBackwardCompat() {
        let url = URL(string: "https://photos.example.com")!
        let nilUser = ServerPartitionKey(from: url, userId: nil)
        let noArg = ServerPartitionKey(from: url)
        #expect(nilUser.directoryName == "https_photos.example.com")
        #expect(nilUser == noArg)
    }

    @Test("Empty userId is treated identically to nil")
    func emptyUserIdIsBackwardCompat() {
        let url = URL(string: "https://photos.example.com")!
        let emptyUser = ServerPartitionKey(from: url, userId: "")
        let nilUser = ServerPartitionKey(from: url, userId: nil)
        #expect(emptyUser.directoryName == nilUser.directoryName)
    }

    @Test("Non-nil userId produces a distinct partition from URL-only")
    func userIdProducesDistinctPartition() {
        let url = URL(string: "https://photos.example.com")!
        let withUser = ServerPartitionKey(from: url, userId: "abc-123-def")
        let withoutUser = ServerPartitionKey(from: url, userId: nil)
        #expect(withUser != withoutUser)
        #expect(withUser.directoryName == "https_photos.example.com__abc-123-def")
    }

    @Test("Different userIds on same URL produce different partitions")
    func differentUsersDifferentPartitions() {
        let url = URL(string: "https://photos.example.com")!
        let userA = ServerPartitionKey(from: url, userId: "user-a-uuid")
        let userB = ServerPartitionKey(from: url, userId: "user-b-uuid")
        #expect(userA != userB)
        #expect(userA.directoryName != userB.directoryName)
    }

    @Test("Same userId on different URLs produces different partitions")
    func sameUserDifferentURLs() {
        let userId = "abc-123-def"
        let serverA = ServerPartitionKey(from: URL(string: "https://server-a.example.com")!, userId: userId)
        let serverB = ServerPartitionKey(from: URL(string: "https://server-b.example.com")!, userId: userId)
        #expect(serverA != serverB)
    }

    @Test("userId with filesystem-unsafe characters is sanitized")
    func userIdSanitization() {
        let url = URL(string: "https://photos.example.com")!
        // PhotoKit / Immich UUIDs don't contain these, but defend
        // against future API changes that might include slashes,
        // path separators, etc.
        let key = ServerPartitionKey(from: url, userId: "user/with:bad*chars")
        let forbidden: [Character] = ["/", ":", "*", "?", "<", ">", "|", "\"", "\\"]
        for char in forbidden {
            #expect(!key.directoryName.contains(char), "Sanitization missed: \(char)")
        }
    }

    @Test("Codable round-trip preserves userId")
    func codableRoundTripPreservesUserId() throws {
        let original = ServerPartitionKey(from: URL(string: "https://photos.example.com")!, userId: "user-uuid")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ServerPartitionKey.self, from: data)
        #expect(decoded == original)
        #expect(decoded.userId == "user-uuid")
    }

    @Test("userId is exposed as a property for downstream use")
    func userIdExposed() {
        let key = ServerPartitionKey(from: URL(string: "https://photos.example.com")!, userId: "uuid-123")
        #expect(key.userId == "uuid-123")
        let nilKey = ServerPartitionKey(from: URL(string: "https://photos.example.com")!, userId: nil)
        #expect(nilKey.userId == nil)
    }
}
