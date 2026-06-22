import Foundation

/// Immich's reported server version (`GET /api/server/version` →
/// `{ major, minor, patch }`). `prerelease` was added in Immich 3.0 and
/// is decoded optionally so the same struct round-trips on 2.x and 3.x.
public struct ServerVersion: Sendable, Codable, Equatable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Present from Immich 3.0 onward; `nil` on a stable release and on
    /// every 2.x server. Not part of ordering — a prerelease of an
    /// otherwise-newer version still sorts newer.
    public let prerelease: Int?

    public init(major: Int, minor: Int, patch: Int, prerelease: Int? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    /// `2.7` — the major.minor pair, for "verified against 2.7.x" copy.
    public var majorMinor: String { "\(major).\(minor)" }

    public static func < (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// Which Immich versions cairn has been validated against, and the
/// advisory shown when a user's server is outside that.
///
/// This is deliberately a *soft* signal, not a gate: cairn decodes
/// tolerantly and degrades gracefully, so an unverified server usually
/// works fine. The advisory only fires on the high-signal case — a
/// **newer major** than we've verified — because that's where Immich
/// clusters breaking changes (e.g. the 2.x → 3.0 wave). Newer minor /
/// patch releases are not flagged: they're frequent and almost always
/// safe, and nagging on every point release would train users to ignore
/// the banner.
///
/// `lastVerified` is bumped (alongside refreshing the contract snapshot
/// in `immich-contract/`) whenever cairn is validated against a new
/// Immich release.
public enum ImmichVersionSupport {
    /// The newest Immich version cairn has been verified against. Keep in
    /// sync with `immich-contract/contract-snapshot.json`'s source version.
    public static let lastVerified = ServerVersion(major: 2, minor: 7, patch: 5)

    /// A short advisory string when `server` warrants one, else `nil`.
    /// Currently fires only when the server's major exceeds the verified
    /// major.
    public static func advisory(for server: ServerVersion) -> String? {
        guard server.major > lastVerified.major else { return nil }
        return "cairn has been verified against Immich \(lastVerified.majorMinor).x. "
            + "Your server is \(server) — it should work, but if something looks off, check for a cairn update."
    }
}
