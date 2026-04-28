import SwiftUI

/// Layer 2 of the cairn color system: semantic tokens that views read.
///
/// Components reference `CairnTokens` properties by their *role* in the UI
/// (`primary`, `dangerSoft`, `verifiedInk`) — never the raw palette colors.
/// This is the key abstraction from the prototype's two-layer `--c-*` /
/// `--ui-*` system: when the user (or designer) tweaks a palette value,
/// every dependent component repaints automatically because they all
/// reference the semantic token.
///
/// Tokens are derived from the underlying `CairnPalette` via tint/shade
/// math at construction time (matches the prototype's `softInk` derivation
/// in palette.js). Light and dark schemes get different derivations so a
/// `dangerSoft` reads as a soft pinkish wash on light mode and a low-
/// chroma muted red on dark mode — consistent semantic meaning, different
/// pixels.
public struct CairnTokens: Sendable {

    // MARK: - Surfaces

    /// The base background for a screen.
    public let bg: Color
    /// A surface that sits "on" the background (cards, sheets).
    public let surface: Color
    /// A surface that contrasts with `surface` (footer, secondary card).
    public let surfaceAlt: Color
    /// A subtle divider line; honors hairline conventions.
    public let divider: Color

    // MARK: - Text

    /// The dominant text color.
    public let text: Color
    /// One step softer than `text` — body copy that's not the hero.
    public let textBody: Color
    /// Muted / secondary text.
    public let textMuted: Color
    /// A faint hint — placeholders, footnotes.
    public let textHint: Color

    // MARK: - Brand / primary

    /// The hero brand color (also drives primary CTA fill).
    public let primary: Color
    /// Ink-on-`primary` for legible text on the hero color.
    public let primaryInk: Color

    // MARK: - Role colors (background + ink + soft)

    public let danger: Color
    public let dangerSoft: Color
    public let dangerInk: Color

    public let pending: Color
    public let pendingSoft: Color
    public let pendingInk: Color

    public let verified: Color
    public let verifiedSoft: Color
    public let verifiedInk: Color

    public let info: Color
    public let infoSoft: Color
    public let infoInk: Color

    /// Warm-orange accent role — surfaces a hue distinct from danger
    /// (red), pending (amber), and verified (green) so the UI has
    /// somewhere to land when none of those semantics fit but a
    /// color-keyed accent reads better than another shade of gray.
    /// Drawn from the palette's `accent` (Carrot Orange).
    public let accent: Color
    public let accentSoft: Color
    public let accentInk: Color

    // MARK: - Construction

    /// Build tokens from a palette + a color scheme. Soft variants are
    /// `mix(palette, surface, ~0.85)` (mostly the surface color, lightly
    /// tinted toward the role); ink variants shade the role darker on
    /// light scheme, lighter on dark scheme — exactly the prototype's
    /// `softInk` math, adapted for SwiftUI.
    public init(palette p: CairnPalette = .defaults, scheme: ColorScheme = .light) {
        // Treat anything that isn't `.dark` as `.light`. Future ColorScheme
        // cases default to the light path; better than throwing or shipping
        // with a partial initialization.
        let isDark = (scheme == .dark)

        if isDark {
            bg          = p.ink
            surface     = p.graphite
            surfaceAlt  = p.charcoal
            divider     = p.charcoal.tinted(0.10)
            text        = p.bone
            textBody    = p.linen
            textMuted   = p.pebble
            textHint    = p.slate
            primary     = p.destructive.tinted(0.10)
            primaryInk  = p.bone

            danger       = p.danger.tinted(0.06)
            dangerSoft   = p.danger.mix(with: p.graphite, amount: 0.78)
            dangerInk    = p.danger.tinted(0.18)

            pending      = p.pending
            pendingSoft  = p.pending.mix(with: p.graphite, amount: 0.78)
            pendingInk   = p.pending.tinted(0.10)

            verified     = p.verified.tinted(0.05)
            verifiedSoft = p.verified.mix(with: p.graphite, amount: 0.78)
            verifiedInk  = p.verified.tinted(0.18)

            info         = p.info.tinted(0.05)
            infoSoft     = p.info.mix(with: p.graphite, amount: 0.78)
            infoInk      = p.info.tinted(0.20)

            accent       = p.accent.tinted(0.05)
            accentSoft   = p.accent.mix(with: p.graphite, amount: 0.78)
            accentInk    = p.accent.tinted(0.18)
        } else {
            bg          = p.paper
            surface     = p.bone
            surfaceAlt  = p.linen
            divider     = p.sand
            text        = p.ink
            textBody    = p.charcoal
            textMuted   = p.slate
            textHint    = p.pebble
            primary     = p.destructive
            primaryInk  = p.bone

            danger       = p.danger
            dangerSoft   = p.danger.mix(with: p.bone, amount: 0.86)
            dangerInk    = p.danger.shaded(0.32)

            pending      = p.pending
            pendingSoft  = p.pending.mix(with: p.bone, amount: 0.82)
            pendingInk   = p.pending.shaded(0.40)

            verified     = p.verified
            verifiedSoft = p.verified.mix(with: p.bone, amount: 0.85)
            verifiedInk  = p.verified.shaded(0.32)

            info         = p.info
            infoSoft     = p.info.mix(with: p.bone, amount: 0.85)
            infoInk      = p.info.shaded(0.30)

            accent       = p.accent
            accentSoft   = p.accent.mix(with: p.bone, amount: 0.85)
            accentInk    = p.accent.shaded(0.18)
        }
    }
}

// MARK: - Environment integration

private struct CairnTokensKey: EnvironmentKey {
    static let defaultValue: CairnTokens = CairnTokens(palette: .defaults, scheme: .light)
}

extension EnvironmentValues {
    /// Access the active token set. Top-level `CairnAppRoot` injects this
    /// based on the current `colorScheme`. Views read it like:
    /// ```
    /// @Environment(\.cairnTokens) private var t
    /// ```
    public var cairnTokens: CairnTokens {
        get { self[CairnTokensKey.self] }
        set { self[CairnTokensKey.self] = newValue }
    }
}

/// View modifier that resolves tokens from the current color scheme and a
/// palette, then injects them into the environment for descendant views.
public struct CairnThemeModifier: ViewModifier {
    public let palette: CairnPalette
    @Environment(\.colorScheme) private var scheme

    public func body(content: Content) -> some View {
        content
            .environment(\.cairnTokens, CairnTokens(palette: palette, scheme: scheme))
    }
}

extension View {
    /// Apply the cairn theme to a subtree. Typically called once at the
    /// app root; nested calls re-resolve tokens from the (possibly
    /// overridden) palette.
    public func cairnTheme(_ palette: CairnPalette = .defaults) -> some View {
        modifier(CairnThemeModifier(palette: palette))
    }
}
