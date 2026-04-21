import Foundation
import Testing
@testable import CairnCore

@Suite("Hashing")
struct HashingTests {

    // Known SHA1 test vectors, base64-encoded to match Immich's AssetResponseDto.checksum format.

    @Test("SHA1 of empty input matches canonical value")
    func emptySha1() {
        #expect(Hashing.sha1Base64(of: Data()).base64 == "2jmj7l5rSw0yVb/vlWAYkK/YBwk=")
    }

    @Test(#"SHA1 of "abc" matches RFC 3174 test vector"#)
    func abcSha1() {
        #expect(Hashing.sha1Base64(of: Data("abc".utf8)).base64 == "qZk+NkcGgWq6PiVxeFDCbJzQ2J0=")
    }

    @Test("SHA1 of the pangram matches canonical value")
    func pangramSha1() {
        let data = Data("The quick brown fox jumps over the lazy dog".utf8)
        #expect(Hashing.sha1Base64(of: data).base64 == "L9ThxnotKPzthJ7hu3bnORuT6xI=")
    }

    @Test("file-streamed SHA1 equals in-memory SHA1 for the same bytes")
    func fileEqualsData() throws {
        let bytes = Data((0..<5 * 1024 * 1024).map { UInt8($0 & 0xFF) })
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "hash-test-\(UUID().uuidString).bin")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let inMemory = Hashing.sha1Base64(of: bytes)
        let streamed = try Hashing.sha1Base64(ofFileAt: url)
        #expect(inMemory == streamed)
    }

    @Test("streaming across chunk boundaries produces the same digest as a single-shot hash")
    func smallBufferStillCorrect() throws {
        let bytes = Data((0..<100_000).map { UInt8($0 & 0xFF) })
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "hash-boundary-\(UUID().uuidString).bin")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let expected = Hashing.sha1Base64(of: bytes)
        let smallBuffer = try Hashing.sha1Base64(ofFileAt: url, bufferSize: 7919) // prime, crosses every chunk boundary oddly
        #expect(smallBuffer == expected)
    }

    @Test("empty file hashes to the canonical empty-SHA1 value")
    func emptyFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "hash-empty-\(UUID().uuidString).bin")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Hashing.sha1Base64(ofFileAt: url).base64 == "2jmj7l5rSw0yVb/vlWAYkK/YBwk=")
    }

    @Test("missing file throws")
    func missingFileThrows() {
        let url = URL(fileURLWithPath: "/this/path/should/not/exist-\(UUID().uuidString)")
        #expect(throws: (any Error).self) {
            _ = try Hashing.sha1Base64(ofFileAt: url)
        }
    }
}
