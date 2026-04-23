import Foundation

/// Canonical tag namespace cairn writes onto the Immich server as a
/// breadcrumb after each trash run. Versioned at the path level so a future
/// schema change can bump to `v2` without breaking tools reading old tags.
///
///   Shape:   cairn/v1/run/<run_id>
///   run_id:  <iso-8601 timestamp>-<short device id>
///
/// One tag per run; every asset the run trashed (including linked Live Photo
/// motion videos) receives that single tag. Downstream tools use the tag to
/// reconstruct runs server-side — `cairn history` lists them, `cairn restore`
/// can look them up when the local journal is gone. See the plan doc's "Tag
/// schema" section for what is deliberately NOT captured in the schema.
public enum TagSchema {
    /// Top-level namespace. Lowercase to match the product name and to keep
    /// tag paths case-predictable across tooling.
    public static let root = "cairn"
    /// Schema version. Bump to `v2` only for breaking changes; additive
    /// evolution should happen inside v1.
    public static let version = "v1"
    /// Category under which per-run tags live. Leaves room for other
    /// categories (e.g. `cairn/v1/exclusion/...`) without a schema bump.
    public static let runCategory = "run"

    /// Build the full tag value for a given `runId`. This is the string
    /// handed to `POST /api/tags` and later queried by `cairn history`.
    public static func runTagValue(runId: String) -> String {
        "\(root)/\(version)/\(runCategory)/\(runId)"
    }

    /// Path prefix covering every v1 run tag. Used by `cairn history` to
    /// filter the server's tag list down to "all cairn runs ever".
    public static let runsPrefix = "\(root)/\(version)/\(runCategory)/"

    /// Parse a tag value back to its run ID, or return nil if the value
    /// isn't a v1 run tag. Tolerant of a trailing slash because the Immich
    /// server occasionally echoes one.
    public static func runId(fromTagValue value: String) -> String? {
        guard value.hasPrefix(runsPrefix) else { return nil }
        let suffix = value.dropFirst(runsPrefix.count)
        let trimmed = suffix.hasSuffix("/") ? String(suffix.dropLast()) : String(suffix)
        return trimmed.isEmpty ? nil : trimmed
    }
}
