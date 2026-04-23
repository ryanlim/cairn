import Foundation
import SwiftUI
import Testing
@testable import CairnIOSCore

// Screenshot generator for the two hero-logo arrangements under both
// theme modalities. Runs as a normal Swift test (so `swift test`
// picks it up) but writes PNGs to disk as a side effect. Paths are
// printed in the test output; remove or disable by setting the
// `CAIRN_SKIP_HERO_SCREENSHOTS=1` env var.
//
// Eight images per run:
//   iconPrefix-adaptive-{light,dark}.png  →  CairnMark + "cairn"
//   iconPrefix-rich-{light,dark}.png      →  CairnHeroMark + "cairn"
//   splitI-adaptive-{light,dark}.png      →  "ca" + CairnMark + "rn"
//   splitI-rich-{light,dark}.png          →  "ca" + CairnHeroMark + "rn"
//
// macOS-only — ImageRenderer requires a rendering-capable platform
// and `swift test` runs on the host. The AppKit-side font-registration
// path in `CairnFonts` ensures Fira Code actually renders here rather
// than falling back to SF Mono.
@Suite("HeroWordmarkScreenshots")
struct HeroWordmarkScreenshotsTests {

    @Test("render hero-wordmark variants to PNG")
    @MainActor
    func renderAllHeroVariants() throws {
        try skipIfOptedOut()

        // Force font registration before the first render. Without
        // this, the first `Text` evaluation would trigger registration
        // but subsequent renders race with the async registration on
        // some macOS versions. Calling up-front is deterministic.
        _ = CairnFonts.registerBundledFonts()

        let outDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "cairn-hero-screenshots-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let arrangements: [(id: String, size: CGFloat, makeContent: (MarkVariant) -> AnyView)] = [
            ("iconPrefix", 40, { variant in
                AnyView(IconPrefixWordmark(size: 40, markVariant: variant))
            }),
            ("splitI", 40, { variant in
                AnyView(CairnWordmark(
                    size: 40,
                    weight: .semibold,
                    variant: variant == .adaptive ? .adaptive : .hero
                ))
            }),
        ]

        let schemes: [(name: String, scheme: ColorScheme)] = [
            ("light", .light),
            ("dark", .dark),
        ]
        let variants: [MarkVariant] = [.adaptive, .rich]

        var written: [URL] = []
        for (arrangementId, _, makeContent) in arrangements {
            for variant in variants {
                for (schemeName, scheme) in schemes {
                    let content = makeContent(variant)
                    let url = outDir.appending(path: "\(arrangementId)-\(variant.fileTag)-\(schemeName).png")
                    try render(content: content, scheme: scheme, to: url)
                    written.append(url)
                }
            }
        }

        // Print a nice summary so the path is obvious in the test
        // output. `print` flows to the test log, not assertions.
        print("--- hero-wordmark screenshots ---")
        for url in written {
            print("  \(url.path)")
        }
        print("--- \(written.count) files in \(outDir.path) ---")

        #expect(written.count == 8)
    }

    // MARK: - Helpers

    /// Mark variant enum local to the screenshot test. Maps onto
    /// either `CairnMark` (adaptive template) or `CairnHeroMark`
    /// (rich multi-color) for the icon-prefix arrangement, and onto
    /// `CairnWordmark.Variant` for the split-I arrangement.
    private enum MarkVariant {
        case adaptive
        case rich
        var fileTag: String {
            switch self {
            case .adaptive: return "adaptive"
            case .rich:     return "rich"
            }
        }
    }

    /// Icon-prefix arrangement — same visual treatment as the
    /// StatusScreen top bar / SetupScreen hero: mark on the left,
    /// full "cairn" text on the right.
    private struct IconPrefixWordmark: View {
        let size: CGFloat
        let markVariant: MarkVariant
        @Environment(\.cairnTokens) private var t

        var body: some View {
            HStack(spacing: size * 0.35) {
                Group {
                    switch markVariant {
                    case .adaptive: CairnMark(size: size * 1.6, crowned: true)
                    case .rich:     CairnHeroMark(size: size * 1.6)
                    }
                }
                Text("cairn")
                    .font(.cairnMono(size: size, weight: .semibold))
                    .tracking(-0.8)
                    .foregroundStyle(t.text)
            }
        }
    }

    @MainActor
    private func render(content: AnyView, scheme: ColorScheme, to url: URL) throws {
        // Order matters: set colorScheme *outside* cairnTheme so the
        // token resolver reads the overridden value from the env.
        let wrapped = content
            .padding(32)
            .background(canvasBackground(for: scheme))
            .cairnTheme()
            .environment(\.colorScheme, scheme)

        let renderer = ImageRenderer(content: wrapped)
        renderer.scale = 3.0          // @3x for crisp previews
        renderer.isOpaque = true      // PNG stays small, no alpha channel needed

        #if canImport(AppKit)
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            Issue.record("ImageRenderer failed to produce a PNG for \(url.lastPathComponent)")
            return
        }
        try data.write(to: url, options: .atomic)
        #else
        Issue.record("Non-AppKit host is not supported for screenshot generation")
        #endif
    }

    /// Pulls a theme-consistent background color without having to
    /// reach into the environment (the caller sets the env on the
    /// content view below this point). Approximate values that match
    /// the tokens' `bg` for each scheme — not identical, but close
    /// enough for a screenshot swatch.
    private func canvasBackground(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light: return Color(red: 0.976, green: 0.969, blue: 0.957)
        case .dark:  return Color(red: 0.094, green: 0.086, blue: 0.071)
        @unknown default: return Color.white
        }
    }

    /// Opt-out for CI / situations where writing PNGs to the temp
    /// dir is undesirable. Uses Swift Testing's skip mechanism so
    /// the test reports as skipped rather than passing silently.
    private func skipIfOptedOut() throws {
        if ProcessInfo.processInfo.environment["CAIRN_SKIP_HERO_SCREENSHOTS"] == "1" {
            try #require(Bool(false), "CAIRN_SKIP_HERO_SCREENSHOTS=1 — screenshot test opted out")
        }
    }
}
