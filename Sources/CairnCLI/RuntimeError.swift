import Foundation

/// CLI-local error for surfacing user-facing messages via ArgumentParser's
/// exit-code-with-message mechanism.
///
/// Use this when the CLI itself has something to say (e.g. "run not found in
/// journal", "--file-name-matches requires tag.read"). Domain errors from
/// CairnCore (e.g. `RestoreError`, `SafetyDecision.AbortReason`) carry their
/// own descriptions and surface directly — wrap only when the CLI needs to
/// add context the core can't know.
struct RuntimeError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
