import Foundation
import Testing
@testable import CairnCore

@Suite("EnvSecretStore", .serialized)
struct EnvSecretStoreTests {

    /// Save current values, overwrite, return a cleanup closure that restores.
    private func seed(_ values: [String: String?]) -> () -> Void {
        let originals: [String: String?] = Dictionary(uniqueKeysWithValues:
            values.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) })
        for (k, v) in values {
            if let v { setenv(k, v, 1) } else { unsetenv(k) }
        }
        return {
            for (k, v) in originals {
                if let v { setenv(k, v, 1) } else { unsetenv(k) }
            }
        }
    }

    @Test("reads canonical env vars")
    func reads() throws {
        let restore = seed(["IMMICH_URL": "https://photos.example.com", "IMMICH_API_KEY": "sekret"])
        defer { restore() }
        let s = EnvSecretStore()
        #expect(try s.serverURL().absoluteString == "https://photos.example.com")
        #expect(try s.apiKey() == "sekret")
    }

    @Test("missing URL throws .missing")
    func missingURL() throws {
        let restore = seed(["IMMICH_URL": nil, "IMMICH_API_KEY": "k"])
        defer { restore() }
        let s = EnvSecretStore()
        #expect(throws: SecretStoreError.self) { _ = try s.serverURL() }
    }

    @Test("empty values treated as missing")
    func emptyIsMissing() throws {
        let restore = seed(["IMMICH_URL": "", "IMMICH_API_KEY": ""])
        defer { restore() }
        let s = EnvSecretStore()
        #expect(throws: SecretStoreError.self) { _ = try s.serverURL() }
        #expect(throws: SecretStoreError.self) { _ = try s.apiKey() }
    }

    @Test("custom variable names override defaults")
    func customVarNames() throws {
        let restore = seed(["MY_URL": "https://other.example.com", "MY_KEY": "abc"])
        defer { restore() }
        let s = EnvSecretStore(urlVariable: "MY_URL", keyVariable: "MY_KEY")
        #expect(try s.serverURL().absoluteString == "https://other.example.com")
        #expect(try s.apiKey() == "abc")
    }
}

@Suite("EnvFileLoader", .serialized)
struct EnvFileLoaderTests {

    private func writeTemp(_ content: String) -> String {
        let path = NSTemporaryDirectory() + "env-\(UUID().uuidString).env"
        try! content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test("loads KEY=VALUE pairs, ignores comments and blank lines")
    func loadsValues() {
        let path = writeTemp("""
        # a comment
        FOO=bar

        BAZ=qux
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }
        unsetenv("FOO"); unsetenv("BAZ")
        defer { unsetenv("FOO"); unsetenv("BAZ") }

        EnvFileLoader.load(fromPath: path)
        #expect(ProcessInfo.processInfo.environment["FOO"] == "bar")
        #expect(ProcessInfo.processInfo.environment["BAZ"] == "qux")
    }

    @Test("existing env vars take precedence")
    func existingWins() {
        let path = writeTemp("FOO=from-file")
        defer { try? FileManager.default.removeItem(atPath: path) }
        setenv("FOO", "from-env", 1)
        defer { unsetenv("FOO") }

        EnvFileLoader.load(fromPath: path)
        #expect(ProcessInfo.processInfo.environment["FOO"] == "from-env")
    }

    @Test("quoted values strip surrounding quotes")
    func stripQuotes() {
        let path = writeTemp("A=\"double\"\nB='single'\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        unsetenv("A"); unsetenv("B")
        defer { unsetenv("A"); unsetenv("B") }

        EnvFileLoader.load(fromPath: path)
        #expect(ProcessInfo.processInfo.environment["A"] == "double")
        #expect(ProcessInfo.processInfo.environment["B"] == "single")
    }

    @Test("missing file is a silent no-op")
    func missingFile() {
        EnvFileLoader.load(fromPath: "/no/such/path-\(UUID().uuidString)")
    }
}
