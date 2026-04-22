import Foundation
import CairnCore

/// `SettingsStore` backed by `UserDefaults` — the natural home for app-level
/// user prefs on iOS. UserDefaults is small, atomic, KVO-observable, and
/// already handled by the system across launches and (with the right
/// suite/App Group) across an app + extension pair.
///
/// We considered SwiftData but rejected it: a flat struct of five prefs
/// doesn't justify a model container, schema migrations, or a `ModelContext`
/// dependency. UserDefaults is the right tool for this size of state.
///
/// ## Storage layout
///
/// The entire `CairnSettings` struct is JSON-encoded and written under a
/// single key as `Data`. We deliberately do **not** spread fields across
/// many UserDefaults keys:
///
/// - Coupled writes across multiple keys aren't atomic — a crash mid-save
///   could leave the prefs internally inconsistent.
/// - A future schema change (rename a field, add one with a non-default
///   value, drop one) is a one-line `Codable` migration on a blob; with
///   spread-out keys it's a hand-rolled per-key migration matrix.
/// - The `Codable` round-trip is identical to `JSONFileSettingsStore`'s,
///   so the two backings are interchangeable for tests and the CLI.
///
/// ## Concurrency
///
/// `UserDefaults` is documented thread-safe for its primitive accessors, so
/// this type is a `Sendable` struct rather than an `actor`. The async
/// signatures on `SettingsStore` are honored without actually suspending —
/// callers that `await` get correct behavior, no extra hop is needed.
public struct UserDefaultsSettingsStore: SettingsStore, Sendable {

    /// The defaults database to read/write. Inject a custom suite for
    /// tests (`UserDefaults(suiteName:)`) or for App Group sharing between
    /// the main app and an extension/widget (`UserDefaults(suiteName:
    /// "group.app.cairn")`). Defaults to `.standard`.
    ///
    /// `nonisolated(unsafe)` because `UserDefaults` (an `NSObject` subclass)
    /// is not declared `Sendable` in its ObjC headers, but Apple documents
    /// its primitive accessors as thread-safe. We promise the compiler what
    /// the framework already guarantees so this struct can stay `Sendable`
    /// without an actor wrapper.
    public nonisolated(unsafe) let defaults: UserDefaults

    /// The single key under which the JSON-encoded `CairnSettings` blob
    /// lives. One key per logical settings document — see the type-level
    /// doc comment for why we don't spread fields.
    public let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = "app.cairn.settings"
    ) {
        self.defaults = defaults
        self.key = key
    }

    /// Load the stored settings.
    ///
    /// Fail-soft semantics — this method only returns, never throws:
    ///
    /// - **Key absent** (fresh install, or first launch after a settings
    ///   reset): return `CairnSettings.defaults`. This matches the
    ///   `SettingsStore` contract — "nothing saved yet" is not an error
    ///   the caller has to special-case on every startup.
    /// - **Data present but JSON-decode fails** (corruption on disk, a
    ///   downgrade from a future schema, an external process scribbling
    ///   on our key): also return `.defaults` and log via `print`. For
    ///   user prefs we'd much rather recover gracefully and let the user
    ///   re-tune than throw and lock them out of the app's settings
    ///   surface — the worst case is they have to re-enable a non-default
    ///   pref, the best case is they never notice. The fields here are
    ///   tunables, not state we can't reconstruct.
    ///
    /// `throws` is kept on the signature to satisfy the protocol and to
    /// leave room for a future variant that surfaces errors loudly.
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

    /// Encode the settings as JSON and write under `key`. The write is
    /// atomic at the UserDefaults layer — no merging with prior contents,
    /// the new blob completely replaces the old one. Callers that want
    /// to mutate a single field should `load()`, mutate, then `save()`.
    public func save(_ settings: CairnSettings) async throws {
        let encoder = JSONEncoder()
        // Sorted keys keep the on-disk plist diff-friendly when developers
        // inspect via `defaults read`. Pretty-printing isn't worth the
        // bytes here — UserDefaults isn't a place humans typically read.
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(settings)
        defaults.set(data, forKey: key)
    }
}
