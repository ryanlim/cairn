import SwiftUI

/// Layer 1 of the cairn color system: raw palette values, role-keyed.
///
/// Mirrors the prototype's `palette.js`. Editing a value here propagates
/// through every component that reads `CairnTokens` — components must
/// **never** reach for a raw `.red` / `.gray` SwiftUI color. Keep all
/// color decisions semantic, not literal.
///
/// Values are HEX strings rendered into SwiftUI `Color` via `Color(hex:)`.
/// Light/dark adaptation is handled by `CairnTokens` selecting different
/// shade/tint variants depending on `colorScheme`, not here — this layer
/// is purely the catalog of "what red is OUR red."
public struct CairnPalette: Sendable, Equatable {

    // MARK: - Accent roles (from prototype's palette.js)

    public var destructive: Color // Flag Red — the hero mark
    public var danger: Color      // Strawberry Red — actionable warnings
    public var warn: Color        // Atomic Tangerine
    public var accent: Color      // Carrot Orange
    public var pending: Color     // Tuscan Sun — amber
    public var success: Color     // Willow Green
    public var verified: Color    // Seaweed — passed safety checks
    public var info: Color        // Dark Cyan — informational nudges
    public var muted: Color       // Blue Slate
    public var quiet: Color       // Air Force Blue

    // MARK: - Neutral ramp (warm gray — stone family)

    public var ink: Color
    public var graphite: Color
    public var charcoal: Color
    public var slate: Color
    public var pebble: Color
    public var sand: Color
    public var linen: Color
    public var paper: Color
    public var bone: Color
    public var white: Color

    public init(
        destructive: Color = Color(hex: "#d52023"),
        danger: Color      = Color(hex: "#f94144"),
        warn: Color        = Color(hex: "#f3722c"),
        accent: Color      = Color(hex: "#f8961e"),
        pending: Color     = Color(hex: "#f9c74f"),
        success: Color     = Color(hex: "#90be6d"),
        verified: Color    = Color(hex: "#46af8f"),
        info: Color        = Color(hex: "#478583"),
        muted: Color       = Color(hex: "#577590"),
        quiet: Color       = Color(hex: "#7890a5"),
        ink: Color         = Color(hex: "#111111"),
        graphite: Color    = Color(hex: "#2a2722"),
        charcoal: Color    = Color(hex: "#4a4640"),
        slate: Color       = Color(hex: "#76716a"),
        pebble: Color      = Color(hex: "#a8a194"),
        sand: Color        = Color(hex: "#d6cfc1"),
        linen: Color       = Color(hex: "#e8e3d9"),
        paper: Color       = Color(hex: "#f2eee7"),
        bone: Color        = Color(hex: "#faf8f4"),
        white: Color       = Color(hex: "#ffffff")
    ) {
        self.destructive = destructive
        self.danger = danger
        self.warn = warn
        self.accent = accent
        self.pending = pending
        self.success = success
        self.verified = verified
        self.info = info
        self.muted = muted
        self.quiet = quiet
        self.ink = ink
        self.graphite = graphite
        self.charcoal = charcoal
        self.slate = slate
        self.pebble = pebble
        self.sand = sand
        self.linen = linen
        self.paper = paper
        self.bone = bone
        self.white = white
    }

    public static let defaults = CairnPalette()
}

// MARK: - Hex helper

extension Color {
    /// Initialize from a `#rrggbb` hex string. Panics on malformed input
    /// — palette values are in-tree constants, not user input.
    public init(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        precondition(s.count == 6, "CairnPalette hex must be 6 chars: \(hex)")
        let v = UInt32(s, radix: 16)!
        self.init(
            red:   Double((v >> 16) & 0xFF) / 255.0,
            green: Double((v >>  8) & 0xFF) / 255.0,
            blue:  Double( v        & 0xFF) / 255.0
        )
    }

    /// Lighten by mixing toward white. `amount` 0…1.
    public func tinted(_ amount: Double) -> Color {
        mix(with: .white, amount: amount)
    }

    /// Darken by mixing toward black. `amount` 0…1.
    public func shaded(_ amount: Double) -> Color {
        mix(with: .black, amount: amount)
    }

    /// Linear interpolation in sRGB (close enough for UI tinting; we don't
    /// need OKLab-perceptual accuracy for the soft/ink variants).
    public func mix(with other: Color, amount: Double) -> Color {
        let t = max(0, min(1, amount))
        let a = self.rgbaComponents
        let b = other.rgbaComponents
        return Color(
            red:   a.r + (b.r - a.r) * t,
            green: a.g + (b.g - a.g) * t,
            blue:  a.b + (b.b - a.b) * t,
            opacity: a.a + (b.a - a.a) * t
        )
    }

    fileprivate var rgbaComponents: (r: Double, g: Double, b: Double, a: Double) {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
        #else
        // macOS fallback via NSColor
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.black
        return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent))
        #endif
    }
}

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
