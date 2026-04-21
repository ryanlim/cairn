import Foundation

/// CLI-local error type for surfacing user-facing messages via ArgumentParser's
/// exit-code-with-message mechanism. Domain errors from CairnCore (e.g.
/// `RestoreError`, `SafetyDecision.AbortReason`) carry their own descriptions.
struct RuntimeError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
