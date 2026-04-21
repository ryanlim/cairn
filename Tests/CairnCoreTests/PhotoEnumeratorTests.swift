import Foundation
import Testing
@testable import CairnCore

@Suite("ChecksumFilePhotoEnumerator")
struct ChecksumFilePhotoEnumeratorTests {

    private func writeTemp(_ content: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "photo-\(UUID().uuidString).txt")
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("reads one base64 SHA1 per line as a Set<Checksum>")
    func readsLines() async throws {
        let url = writeTemp("""
        2jmj7l5rSw0yVb/vlWAYkK/YBwk=
        qZk+NkcGgWq6PiVxeFDCbJzQ2J0=
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let cks = try await ChecksumFilePhotoEnumerator(path: url).currentChecksums()
        #expect(cks == Set([
            Checksum(base64: "2jmj7l5rSw0yVb/vlWAYkK/YBwk="),
            Checksum(base64: "qZk+NkcGgWq6PiVxeFDCbJzQ2J0="),
        ]))
    }

    @Test("ignores blank lines and # comments")
    func ignoresCommentsAndBlanks() async throws {
        let url = writeTemp("""
        # intro comment
        2jmj7l5rSw0yVb/vlWAYkK/YBwk=

        # middle comment
        qZk+NkcGgWq6PiVxeFDCbJzQ2J0=
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let cks = try await ChecksumFilePhotoEnumerator(path: url).currentChecksums()
        #expect(cks.count == 2)
    }

    @Test("missing file throws")
    func missingThrows() async throws {
        let url = URL(fileURLWithPath: "/no/such/path-\(UUID().uuidString)")
        await #expect(throws: (any Error).self) {
            _ = try await ChecksumFilePhotoEnumerator(path: url).currentChecksums()
        }
    }

    @Test("empty file yields empty set")
    func emptyFile() async throws {
        let url = writeTemp("")
        defer { try? FileManager.default.removeItem(at: url) }
        let cks = try await ChecksumFilePhotoEnumerator(path: url).currentChecksums()
        #expect(cks.isEmpty)
    }
}
