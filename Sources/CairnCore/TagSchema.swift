import Foundation

/// Canonical tag-namespace schema for the server-side breadcrumbs cairn writes
/// into Immich. The schema is versioned at the path level — if we ever need
/// to change semantics, we bump to `v2` and old tooling understands old tags.
///
///   Shape:   cairn/v1/run/<run_id>
///   Where:   run_id = <iso-8601 timestamp>-<short device id>
///
/// One tag per trash run. Every trashed asset in that run (including linked
/// Live Photo motion videos) gets this single tag. See the plan doc's
/// "Tag schema" section for the full rationale and what's deliberately NOT
/// in the schema.
public enum TagSchema {
    public static let root = "cairn"
    public static let version = "v1"
    public static let runCategory = "run"

    /// Full tag value applied to every asset trashed in `runId`.
    public static func runTagValue(runId: String) -> String {
        "\(root)/\(version)/\(runCategory)/\(runId)"
    }

    /// Path prefix under which all v1 runs live. Useful for server-side
    /// queries that want "all cairn runs ever" (e.g., the `history` command).
    public static let runsPrefix = "\(root)/\(version)/\(runCategory)/"

    /// Extract the run ID out of a `cairn/v1/run/<id>` tag value, or nil if
    /// the value isn't a v1 run tag. Tolerant of trailing slashes.
    public static func runId(fromTagValue value: String) -> String? {
        guard value.hasPrefix(runsPrefix) else { return nil }
        let suffix = value.dropFirst(runsPrefix.count)
        let trimmed = suffix.hasSuffix("/") ? String(suffix.dropLast()) : String(suffix)
        return trimmed.isEmpty ? nil : trimmed
    }
}
