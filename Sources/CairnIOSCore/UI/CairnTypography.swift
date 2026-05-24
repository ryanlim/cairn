import SwiftUI

// MARK: - Dynamic-Type-aware system font
//
// `Font.system(size:)` does NOT scale with Dynamic Type. Apple's
// design point is that callers who want scaling should use a
// semantic TextStyle (`.body`, `.headline`, `.caption`). Cairn's
// UI tokens are point-precise (11, 12, 13.5, etc.) by design — the
// typographic hierarchy was hand-tuned in the prototype and we
// want to preserve those exact relationships. So we need a way to
// keep arbitrary point sizes AND honor the user's Dynamic Type
// preference.
//
// `Font.custom("", size:, relativeTo:)` is the API that does this.
// When the PostScript name is empty (or unknown), the font system
// falls back to the system font; the `relativeTo:` parameter
// anchors the scaling curve to the named TextStyle. The result
// scales reactively with the user's Dynamic Type setting.
//
// Migration pattern (from the audit):
//   Before:  `.font(.system(size: 13, weight: .semibold))`
//   After:   `.font(.cairnScaled(size: 13, weight: .semibold))`
//
// Pick `relativeTo:` based on the font's role:
//   - prose / body text → `.body` (default)
//   - small / caption / hint → `.caption` or `.footnote`
//   - emphasized headings → `.headline` or `.title3`
// The default `.body` is appropriate for the vast majority of
// cairn's call sites.

extension Font {
    /// Dynamic-Type-aware variant of `Font.system(size:weight:design:)`.
    /// See file header for the rationale and `relativeTo:` selection
    /// guidance.
    public static func cairnScaled(
        size: CGFloat,
        weight: Weight = .regular,
        design: Design = .default,
        relativeTo style: TextStyle = .body
    ) -> Font {
        // `.custom("", size:, relativeTo:)` returns the system font
        // scaled relative to `style`. Apple's documented behavior for
        // an unrecognized PostScript name is "fall back to system."
        var font = Font.custom("", size: size, relativeTo: style).weight(weight)
        // SwiftUI's Font lacks a fluent `design()` method but offers
        // `.monospaced()` for the most common ask. Cairn uses only
        // `.default` and `.monospaced` in practice (verified with
        // grep across UI/*); other designs would need a different
        // path.
        if design == .monospaced {
            font = font.monospaced()
        }
        return font
    }
}
