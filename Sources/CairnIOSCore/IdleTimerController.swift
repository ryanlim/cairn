#if canImport(UIKit)
import UIKit

/// Thin wrapper over `UIApplication.shared.isIdleTimerDisabled` so
/// sync code can request "keep the screen awake while I'm running"
/// without sprinkling UIKit calls across the reconciliation path.
///
/// **What this controls.** When `disabled == true`, iOS suppresses
/// the Auto-Lock timer while cairn is the foreground app — the
/// screen won't dim or lock no matter how long the user lets it
/// sit untouched. Manual lock (side button) still works. Switching
/// to another app drops cairn out of foreground and iOS resumes
/// the normal Auto-Lock policy for whatever's foreground now.
///
/// **Why this exists.** A first-sync hashing pass on a 100k-asset
/// iCloud-Optimized library can run for hours; if the screen goes
/// dark and iOS suspends cairn after its ~30s background grace,
/// in-flight `PHAssetResourceManager.requestData` calls pause and
/// the user comes back to what looks like a stalled sync. Holding
/// the idle timer keeps cairn foreground-active until the sync
/// completes (or the user manually backgrounds the app), at which
/// point the wrapper restores the default.
///
/// **Lifecycle hygiene.** This wrapper is the single owner of the
/// flag inside cairn — every set goes through `setEnabled(_:)`.
/// On background transition the host clears it; on
/// success/cancel/error the sync orchestrator clears it. Keeping
/// the ownership narrow avoids the "left it enabled forever, now
/// the screen never sleeps in any cairn screen" bug.
@MainActor
public enum IdleTimerController {
    /// `true` when cairn has set the idle timer off; `false` when
    /// cairn isn't holding the flag (or has cleared it). Internal
    /// to the wrapper — callers shouldn't read `UIApplication`
    /// directly because some other code could have flipped it.
    public private(set) static var isHeld: Bool = false

    /// Idempotent: setting `true` while already true (or `false`
    /// while already false) is a no-op. Keeps the call sites
    /// noise-free — sync start can fire this on every sync, sync
    /// end on every cleanup, without bookkeeping.
    public static func setEnabled(_ keepAwake: Bool) {
        guard keepAwake != isHeld else { return }
        UIApplication.shared.isIdleTimerDisabled = keepAwake
        isHeld = keepAwake
    }

    /// Hard reset — always clears the flag regardless of cached
    /// state, then resets the cache to match. Used on the
    /// scene-phase → background path and in `signOut` so a flag
    /// that somehow got out of sync (e.g., set externally by some
    /// third-party SDK) doesn't strand the screen on.
    public static func forceClear() {
        UIApplication.shared.isIdleTimerDisabled = false
        isHeld = false
    }
}
#endif
