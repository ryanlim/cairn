import Foundation
import CairnCore

/// `SettingsStore` backed by `UserDefaults` — the natural home for
/// app-level user prefs on iOS. Small, atomic, KVO-observable, and
/// handled by the system across launches and (with the right suite or
/// App Group) across an app + extension pair.
///
/// SwiftData was considered and rejected — a flat struct of a handful
/// of prefs doesn't justify a model container, schema migrations, or
/// a `ModelContext` dependency.
///
/// ## Storage layout
///
/// The entire `CairnSettings` struct is JSON-encoded and written under
/// one key as `Data`. Fields are **not** spread across many
/// UserDefaults keys:
///
/// - Coupled writes across multiple keys aren't atomic — a crash
///   mid-save could leave prefs internally inconsistent.
/// - A future schema change is a one-line `Codable` migration on a
///   blob; spread-out keys need a hand-rolled per-key migration
///   matrix.
/// - Round-trip matches `JSONFileSettingsStore`, so the two backings
///   are interchangeable for tests and the CLI.
///
/// ## Concurrency
///
/// `UserDefaults` documents its primitive accessors as thread-safe,
/// so this type is a `Sendable` struct rather than an `actor`. The
/// `async` signatures on `SettingsStore` are satisfied without
/// actually suspending.
public struct UserDefaultsSettingsStore: SettingsStore, Sendable {

    /// Defaults database to read and write. Inject a custom suite for
    /// tests (`UserDefaults(suiteName:)`) or for App Group sharing
    /// between the main app and an extension/widget
    /// (`UserDefaults(suiteName: "group.app.cairn")`). Defaults to
    /// `.standard`.
    ///
    /// `nonisolated(unsafe)` because `UserDefaults` (an `NSObject`
    /// subclass) isn't declared `Sendable` in its ObjC headers, but
    /// Apple documents its primitive accessors as thread-safe. We
    /// promise the compiler what the framework already guarantees so
    /// this struct stays `Sendable` without an actor wrapper.
    public nonisolated(unsafe) let defaults: UserDefaults

    /// Key under which the JSON-encoded `CairnSettings` blob lives.
    /// One key per logical settings document — see the type-level
    /// doc comment for why fields aren't spread.
    public let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = "app.cairn.settings"
    ) {
        self.defaults = defaults
        self.key = key
    }

    /// Load the stored settings. Fail-soft — returns in both cases
    /// below rather than throwing:
    ///
    /// - **Key absent** (fresh install, or first launch after reset):
    ///   return `CairnSettings.defaults`. Matches the `SettingsStore`
    ///   contract — "nothing saved yet" isn't an error the caller
    ///   has to special-case at every startup.
    /// - **Data present but JSON-decode fails** (disk corruption,
    ///   downgrade from a future schema, external process scribbling
    ///   on our key): return `.defaults` and log via `print`. These
    ///   fields are tunables, not state we can't reconstruct; the
    ///   worst case is the user re-enables a non-default pref. We'd
    ///   rather that than lock them out of the settings surface.
    ///
    /// `throws` stays on the signature to satisfy the protocol and
    /// leave room for a future loud-errors variant.
    public func load() async throws -> CairnSettings {
        guard let data = defaults.data(forKey: key) else {
            return .defaults
        }
        do {
            return try JSONDecoder().decode(CairnSettings.self, from: data)
        } catch {
            // Fail-soft: log and recover. See doc comment above for
            // rationale. `print` is intentional — CairnCore stays free of
            // OSLog/os_log so the same recovery message would surface
            // identically from the CLI test harness on macOS.
            print("UserDefaultsSettingsStore: failed to decode settings at key \"\(key)\" (\(error)); returning defaults.")
            return .defaults
        }
    }

    /// Encode `settings` as JSON and write under `key`. The write is
    /// atomic at the UserDefaults layer — no merging with prior
    /// contents; the new blob replaces the old. Mutate-single-field
    /// callers should `load`, mutate, then `save`.
    public func save(_ settings: CairnSettings) async throws {
        let encoder = JSONEncoder()
        // Sorted keys keep the on-disk plist diff-friendly when a
        // developer inspects via `defaults read`. Pretty-printing
        // isn't worth the bytes — UserDefaults isn't where humans
        // typically read.
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(settings)
        defaults.set(data, forKey: key)
    }
}
