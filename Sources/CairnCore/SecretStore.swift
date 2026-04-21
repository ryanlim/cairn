import Foundation

/// Narrow protocol over the two secrets cairn needs: the Immich server URL
/// and the API key. The iOS target will back this with Keychain; the CLI
/// reads from process environment (populated from a `.env` file).
public protocol SecretStore: Sendable {
    func serverURL() throws -> URL
    func apiKey() throws -> String
}

public enum SecretStoreError: Error, CustomStringConvertible, Equatable {
    case missing(name: String)
    case invalidURL(value: String)

    public var description: String {
        switch self {
        case .missing(let name):
            return "missing required secret: \(name)"
        case .invalidURL(let value):
            return "not a valid URL: \(value)"
        }
    }
}

/// Reads from process environment under the usual variable names.
/// Populate via `.env` file before constructing, e.g. through `EnvFileLoader`.
public struct EnvSecretStore: SecretStore {
    public let urlVariable: String
    public let keyVariable: String

    public init(urlVariable: String = "IMMICH_URL", keyVariable: String = "IMMICH_API_KEY") {
        self.urlVariable = urlVariable
        self.keyVariable = keyVariable
    }

    public func serverURL() throws -> URL {
        let raw = ProcessInfo.processInfo.environment[urlVariable] ?? ""
        guard !raw.isEmpty else { throw SecretStoreError.missing(name: urlVariable) }
        guard let url = URL(string: raw) else { throw SecretStoreError.invalidURL(value: raw) }
        return url
    }

    public func apiKey() throws -> String {
        let raw = ProcessInfo.processInfo.environment[keyVariable] ?? ""
        guard !raw.isEmpty else { throw SecretStoreError.missing(name: keyVariable) }
        return raw
    }
}

/// Parses `KEY=VALUE` pairs from a `.env` file into process environment.
/// Existing environment variables take precedence; quoted values have
/// surrounding quotes stripped; lines beginning with `#` are ignored.
/// No-op if the file doesn't exist.
public enum EnvFileLoader {
    public static func load(fromPath path: String) {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2 {
                let first = value.first!, last = value.last!
                if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                    value = String(value.dropFirst().dropLast())
                }
            }
            if ProcessInfo.processInfo.environment[key] == nil {
                setenv(key, value, 1)
            }
        }
    }
}
