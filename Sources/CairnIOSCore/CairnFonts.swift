import Foundation
import SwiftUI
import CoreText
import OSLog
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Bundles the Fira Code variable font with `CairnIOSCore` and
/// exposes a safe way to reach it from SwiftUI.
///
/// SPM bundles fonts as resources, but iOS **doesn't** auto-register
/// them the way `UIAppFonts` in a main target's Info.plist does.
/// `CTFontManagerRegisterFontsForURL` has to run manually at app
/// launch — see `registerBundledFonts()` — before the first `View`
/// renders. Without registration, `Font.custom("FiraCode", …)`
/// silently falls back to the default font, which is hard to
/// diagnose.
///
/// Usage:
///
/// ```swift
/// // At app launch (@main App init):
/// CairnFonts.registerBundledFonts()
///
/// // In a View:
/// Text("cairn").font(.cairnMono(size: 28, weight: .semibold))
/// ```
///
/// Best-effort: registration failures (missing .ttf, malformed,
/// name conflict) fall through to the system's default monospace
/// design so the app still renders.
public enum CairnFonts {

    /// PostScript family name the variable font registers under.
    /// Confirmed from Fira Code v6.2's `FiraCode-VariableFont_wght.ttf`
    /// name table.
    public static let monoFamilyName = "FiraCode"

    /// Fonts-registration diagnostics logger so failures show up in
    /// Console.app instead of silently falling back.
    private static let log = Logger(subsystem: "app.cairn.ios", category: "fonts")

    /// Latched registration result. Exposed for tests and
    /// diagnostics. Safe to read concurrently — `static let` runs
    /// the closure exactly once.
    public static let registrationResult: RegistrationResult = register()

    /// Force `registrationResult` to evaluate. Call from the `@main App`
    /// init, before any view renders. Idempotent — subsequent calls
    /// return the latched value.
    @discardableResult
    public static func registerBundledFonts() -> RegistrationResult {
        registrationResult
    }

    /// Outcome of the one-shot Fira Code registration attempt.
    public enum RegistrationResult: Sendable, Equatable {
        /// Registered successfully; `Font.custom("FiraCode", …)`
        /// resolves to Fira Code.
        case registered
        /// The .ttf wasn't in `Bundle.module` — check Package.swift's
        /// `resources:` list.
        case resourceMissing
        /// CoreText rejected the file. Error details are in Console.app.
        case registrationFailed
    }

    private static func register() -> RegistrationResult {
        guard let url = Bundle.module.url(
            forResource: "FiraCode-VariableFont_wght",
            withExtension: "ttf"
        ) else {
            log.error("Fira Code TTF not found in Bundle.module — SPM resources out of sync?")
            return .resourceMissing
        }

        var cfError: Unmanaged<CFError>?
        // `.process` scope keeps the font private to this app —
        // good default. Don't use `.persistent` (system-wide) or
        // `.user` (user's Fonts folder).
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &cfError)
        if ok {
            log.notice("Registered Fira Code variable font from Bundle.module")
            return .registered
        }
        if let error = cfError?.takeRetainedValue() {
            let message = CFErrorCopyDescription(error) as String? ?? "unknown error"
            // `kCTFontManagerErrorAlreadyRegistered` is harmless —
            // fires when CoreText state survives across app launches
            // (rare but seen in unit tests sharing a lifecycle).
            // Treat as success.
            let code = CFErrorGetCode(error)
            let alreadyRegistered = 105  // CTFontManagerError.alreadyRegistered.rawValue
            if code == alreadyRegistered {
                log.notice("Fira Code already registered — reusing existing registration")
                return .registered
            }
            log.error("CTFontManagerRegisterFontsForURL failed: \(message, privacy: .public)")
        }
        return .registrationFailed
    }
}

// MARK: - SwiftUI font helpers

public extension Font {
    /// Monospaced font for cairn-branded surfaces. Backed by Fira
    /// Code when the bundled font registered, SF Mono otherwise.
    ///
    /// **Variable-font weight handling.** SwiftUI's `Font.weight(...)`
    /// modifier does **not** drive the `wght` axis on a custom
    /// variable font — it tries a traits-based transform on a
    /// non-variable descriptor and fails with runtime warnings
    /// ("Unable to update Font Descriptor's weight"). The supported
    /// path builds a `UIFontDescriptor` with the variation attribute
    /// set to the target `wght` value (300–700 for Fira Code),
    /// materializes a `UIFont`, and wraps it in `Font(_:)`.
    ///
    /// `weight` clamps to Fira Code's supported axis range — a
    /// `.black` request collapses to 700 rather than skipping to an
    /// unsupported axis position.
    static func cairnMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch CairnFonts.registrationResult {
        case .registered:
            #if canImport(UIKit)
            return CairnFonts.variableFont(size: size, weight: weight)
            #elseif canImport(AppKit)
            // macOS path — same variation-attribute trick via
            // `NSFontDescriptor` so screenshot-generating tests render
            // Fira Code instead of falling back to SF Mono.
            return CairnFonts.variableFontAppKit(size: size, weight: weight)
            #else
            return Font.system(size: size, weight: weight, design: .monospaced)
            #endif
        case .resourceMissing, .registrationFailed:
            // Graceful fallback so UI never breaks on registration
            // failure (missing resource, malformed font, etc.). SF
            // Mono is close enough that layout doesn't reflow.
            return Font.system(size: size, weight: weight, design: .monospaced)
        }
    }
}

#if canImport(AppKit) && !canImport(UIKit)
extension CairnFonts {
    /// AppKit copy of the `wght` axis tag — see the UIKit variant
    /// for the encoding rationale.
    private static let weightAxisTagMac: Int = 0x77676874
    /// AppKit copy of the variation-attribute key. `NSFontDescriptor`
    /// accepts the same raw-string attribute as `UIFontDescriptor`.
    private static let variationAttributeNameMac = NSFontDescriptor.AttributeName(
        rawValue: "NSCTFontVariationAttribute"
    )

    /// AppKit equivalent of `variableFont(size:weight:)`. Only used
    /// by macOS test runs and screenshot generation so those render
    /// Fira Code rather than SF Mono.
    static func variableFontAppKit(size: CGFloat, weight: Font.Weight) -> Font {
        let wght = wghtAxisValue(for: weight)
        guard let base = NSFont(name: monoFamilyName, size: size) else {
            return Font.system(size: size, weight: weight, design: .monospaced)
        }
        let tweaked = base.fontDescriptor.addingAttributes([
            variationAttributeNameMac: [weightAxisTagMac: wght] as [Int: CGFloat],
        ])
        if let resolved = NSFont(descriptor: tweaked, size: size) {
            return Font(resolved as CTFont)
        }
        return Font.system(size: size, weight: weight, design: .monospaced)
    }

    private static func wghtAxisValue(for weight: Font.Weight) -> CGFloat {
        switch weight {
        case .ultraLight, .thin, .light: return 300
        case .regular:                   return 400
        case .medium:                    return 500
        case .semibold:                  return 600
        case .bold, .heavy, .black:      return 700
        default:                         return 400
        }
    }
}
#endif

#if canImport(UIKit)
extension CairnFonts {
    /// FourCharCode for the `wght` variable-font axis tag, computed
    /// as `('w'<<24)|('g'<<16)|('h'<<8)|'t'` = `0x77676874`. Hard-
    /// coded because the tag is part of the OpenType spec and
    /// doesn't move.
    private static let weightAxisTag: Int = 0x77676874  // 2_003_265_652

    /// The stable-but-private CoreText attribute key that
    /// `UIFontDescriptor` accepts for variation axes.
    /// `NSCTFontVariationAttribute` is documented at the CoreText
    /// level (`kCTFontVariationAttribute`); `UIFontDescriptor`
    /// accepts it verbatim, which is why we route through a
    /// raw-string attribute name rather than a typed enum case.
    private static let variationAttributeName = UIFontDescriptor.AttributeName(
        rawValue: "NSCTFontVariationAttribute"
    )

    static func variableFont(size: CGFloat, weight: Font.Weight) -> Font {
        let wght = wghtAxisValue(for: weight)
        // Resolve the base `UIFont` by PostScript name. An earlier
        // `UIFontDescriptor(fontAttributes: [.family: ...])` path
        // didn't always resolve to our bundled font — whether
        // "FiraCode" is the *family* or the *name* depends on how
        // the variable font registered, and PostScript-name
        // resolution is the reliable route. System mono fallback on
        // a name miss keeps the UI rendering regardless.
        guard let baseFont = UIFont(name: monoFamilyName, size: size) else {
            log.error("UIFont(name: \"\(monoFamilyName, privacy: .public)\", size: \(size)) returned nil — registration reported success but name doesn't resolve")
            return Font.system(size: size, weight: weight, design: .monospaced)
        }

        // Pin the `wght` axis to our target weight. Variation
        // attributes carry through `fontDescriptor.addingAttributes`
        // cleanly — the returned descriptor represents "this specific
        // variable-font instance."
        let tweaked = baseFont.fontDescriptor.addingAttributes([
            variationAttributeName: [weightAxisTag: wght] as [Int: CGFloat],
        ])
        let uiFont = UIFont(descriptor: tweaked, size: size)
        return Font(uiFont)
    }

    /// Map SwiftUI's symbolic weights onto Fira Code's `wght` axis
    /// values (300–700). SwiftUI's `.weight` range is wider than
    /// Fira Code ships, so we clamp at the endpoints — `.black`
    /// renders at Bold rather than no-op'ing.
    private static func wghtAxisValue(for weight: Font.Weight) -> CGFloat {
        switch weight {
        case .ultraLight, .thin, .light: return 300
        case .regular:                   return 400
        case .medium:                    return 500
        case .semibold:                  return 600
        case .bold, .heavy, .black:      return 700
        default:                         return 400
        }
    }
}
#endif
