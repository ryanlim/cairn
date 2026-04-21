import Foundation

enum EnvLoader {
    /// Reads `KEY=VALUE` pairs from a `.env` file at `path`, populating process
    /// environment for any keys not already set. Lines beginning with `#` and
    /// blank lines are ignored. Quoted values (single or double) have surrounding
    /// quotes stripped. Existing environment variables take precedence.
    static func load(from path: String) {
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

    static func require(_ key: String) throws -> String {
        guard let v = ProcessInfo.processInfo.environment[key], !v.isEmpty else {
            throw RuntimeError("missing required environment variable: \(key)")
        }
        return v
    }
}

struct RuntimeError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
