import Foundation

/// User-tunable configuration the iOS app (and CLI) persists between runs.
///
/// Intentionally excludes secrets (server URL, API key) — those have a
/// different security story and live in `SecretStore`, backed by Keychain
/// on iOS. Also excludes iOS-only concepts (Photos permission state,
/// Background Refresh state) which belong in the iOS target — `CairnCore`
/// stays pure Foundation + CryptoKit so the Kotlin port stays tractable.
///
/// Every field has a sensible default; a fresh install should be safe
/// without the user touching settings. See the plan doc's "Safety rails"
/// section for the rationale behind these specific defaults.
public struct CairnSettings: Sendable, Codable, Equatable {
    /// Abort a run if it would trash more than this percent of matched
    /// assets. 1.0 means 1%. Defense against a bug, permission regression,
    /// or library-wipe event cascading into a mass delete on the server.
    public var maxDeletePercent: Double

    /// Floor below which the percent rail is bypassed — on a small library
    /// (say 200 photos) 1% is 2 photos, which is noise. This sets the
    /// minimum run size that triggers the threshold check.
    public var minDeleteFloor: Int

    /// When true, every sync records a preview run without touching the
    /// server. Useful during onboarding and after a big library change.
    public var dryRunByDefault: Bool

    /// Local notification when a safety rail trips and a run is aborted.
    /// Default on — silently skipping a destructive-intent run that the
    /// user opted into is worse than one extra notification.
    public var notifyOnAbort: Bool

    /// Whether the journal records every API request or just headline
    /// events. Off by default because verbose journals grow quickly and
    /// can leak checksums into support bundles users share.
    public var verboseLogging: Bool

    /// How aggressively cairn acts on deletion candidates. See the plan
    /// doc's "Confirmed-deletion signal (Wave 4)" section for the full
    /// rationale.
    public var deletionStrictness: DeletionStrictness

    public init(
        maxDeletePercent: Double = 1.0,
        minDeleteFloor: Int = 5,
        dryRunByDefault: Bool = false,
        notifyOnAbort: Bool = true,
        verboseLogging: Bool = false,
        deletionStrictness: DeletionStrictness = .strict
    ) {
        self.maxDeletePercent = maxDeletePercent
        self.minDeleteFloor = minDeleteFloor
        self.dryRunByDefault = dryRunByDefault
        self.notifyOnAbort = notifyOnAbort
        self.verboseLogging = verboseLogging
        self.deletionStrictness = deletionStrictness
    }

    /// The factory defaults. Kept as a single constant so tests and the
    /// "reset to defaults" UI path reference the same source of truth.
    public static let defaults: CairnSettings = CairnSettings()
}

/// How aggressively cairn translates "no longer in the local library"
/// into "trash on the server."
///
/// `.strict` requires a positive deletion signal — the checksum has been
/// observed in iOS's Recently Deleted album — before any candidate is
/// trashed. Diff-discovered candidates that lack the positive signal are
/// held in a "pending review" set the user manually approves or skips.
/// This is the safe default and the right choice for any user with iCloud
/// Photo Library, iCloud-Optimized Storage, or a possibility of partial
/// library restores.
///
/// `.trusting` skips the confirmed-deletion gate. Any diff-discovered
/// candidate flows through the normal trash pipeline. Faster operationally
/// but vulnerable to gradual library-loss failure modes (sync degradation,
/// "Remove from this iPhone," partial restores).
public enum DeletionStrictness: String, Sendable, Codable, Equatable, CaseIterable {
    case strict
    case trusting
}

/// Narrow protocol over settings persistence. The iOS target may back
/// this with a SwiftData-adjacent store or UserDefaults; the CLI uses
/// `JSONFileSettingsStore`. `load()` never errors on "nothing saved yet" —
/// a fresh install gets `.defaults`, not a thrown error the caller has to
/// handle specially on every startup.
public protocol SettingsStore: Sendable {
    func load() async throws -> CairnSettings
    func save(_ settings: CairnSettings) async throws
}

/// Default file-backed implementation: one JSON blob at a fixed path.
/// Writes are atomic (write-to-temp + rename) so an interrupted save
/// can't produce a half-written file that fails to decode on next launch.
/// Missing file is not an error — it yields `.defaults`.
public actor JSONFileSettingsStore: SettingsStore {
    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    public init(filePath: String) {
        self.path = URL(fileURLWithPath: filePath)
    }

    public func load() async throws -> CairnSettings {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return .defaults
        }
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(CairnSettings.self, from: data)
    }

    public func save(_ settings: CairnSettings) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        // `.atomic` is write-to-temp + rename; a crash mid-write leaves
        // the previous good file intact. No merging with prior contents —
        // the struct is the complete state, callers load/mutate/save.
        try data.write(to: path, options: .atomic)
    }
}
