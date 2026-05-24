import SwiftUI

// Xcode-only preview catalogue for the hero wordmark in both
// arrangements (icon-prefix / split-I) and both mark variants
// (adaptive template / rich multi-color), rendered side-by-side
// under light and dark schemes.
//
// **Why this file exists.** The macOS `swift test`-driven screenshot
// generator can't resolve `Bundle.module` asset catalogs (SPM's
// resource compilation is iOS-focused), so the mark shows as empty
// there. Xcode Previews run on the iOS simulator where assets +
// Fira Code resolve correctly. Open this file in Xcode, wait for
// the canvas to render, and you'll see the actual on-device look.
//
// To preview a specific arrangement in isolation, use the focused
// `#Preview` blocks at the bottom.

#if DEBUG

// MARK: - Tweak knobs

/// Size of the mark relative to the font size in the split-I
/// arrangement. `1.0` = mark side length equals font size; `1.2` =
/// 20% taller than the glyphs. Change this constant and the
/// canvas re-renders every split-I preview below.
///
/// The baseline alignment inside `CairnWordmark` was tuned at 0.9;
/// past roughly 1.3 the mark starts to float above or crash into
/// neighbouring glyphs' descenders. If you push beyond that range,
/// tweak the `alignmentGuide` epsilon in `CairnPrimitives.swift`
/// as well.
private let splitIMarkScale: CGFloat = 1.0

/// Font size for both arrangements. Change this to see how the
/// wordmark scales as a whole — the icon-prefix row also uses a
/// mark sized at `splitIFontSize * 1.6` (the same ratio the
/// production Setup hero uses).
private let splitIFontSize: CGFloat = 40

/// Side-by-side grid of all four combinations. Column = arrangement,
/// row = mark variant. Labels above each cell describe the combination.
private struct HeroWordmarkGrid: View {
    var body: some View {
        VStack(spacing: 28) {
            Text("cairn hero wordmark — preview matrix")
                .font(.cairnScaled(size: 14, weight: .semibold))
                .opacity(0.7)

            // Icon-prefix arrangement (current production treatment).
            // Ratio + spacing defaults live in
            // `CairnWordmark.defaultMarkScale(style:variant:)` etc. —
            // change those to tune the whole app at once.
            labelledRow(title: "Icon prefix · adaptive mark") {
                CairnWordmark(size: splitIFontSize, variant: .adaptive, style: .iconPrefix)
            }
            labelledRow(title: "Icon prefix · rich mark") {
                CairnWordmark(size: splitIFontSize, variant: .hero, style: .iconPrefix)
            }

            Divider().padding(.vertical, 4)

            // Split-I arrangement. `markScale` is driven by the
            // `splitIMarkScale` knob at the top of this file.
            labelledRow(title: "Split-I · adaptive mark  ·  markScale=\(String(format: "%.2f", splitIMarkScale))") {
                CairnWordmark(
                    size: splitIFontSize,
                    variant: .adaptive,
                    style: .splitI,
                    markScale: splitIMarkScale
                )
            }
            labelledRow(title: "Split-I · rich mark  ·  markScale=\(String(format: "%.2f", splitIMarkScale))") {
                CairnWordmark(
                    size: splitIFontSize,
                    variant: .hero,
                    style: .splitI,
                    markScale: splitIMarkScale
                )
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func labelledRow<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.cairnScaled(size: 11, weight: .semibold))
                .tracking(0.8)
                .opacity(0.5)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Previews

#Preview("All variants — light") {
    HeroWordmarkGrid()
        .cairnTheme()
        .preferredColorScheme(.light)
}

#Preview("All variants — dark") {
    HeroWordmarkGrid()
        .cairnTheme()
        .preferredColorScheme(.dark)
}

// Focused previews — useful when iterating on proportions of a
// specific variant without the others' visual noise.

#Preview("Icon prefix — adaptive") {
    CairnWordmark(size: splitIFontSize, variant: .adaptive, style: .iconPrefix)
        .padding(32)
        .cairnTheme()
}

#Preview("Icon prefix — rich") {
    CairnWordmark(size: splitIFontSize, variant: .hero, style: .iconPrefix)
        .padding(32)
        .cairnTheme()
}

#Preview("Split-I — adaptive") {
    CairnWordmark(
        size: splitIFontSize,
        variant: .adaptive,
        style: .splitI,
        markScale: splitIMarkScale
    )
    .padding(32)
    .cairnTheme()
}

#Preview("Split-I — rich") {
    CairnWordmark(
        size: splitIFontSize,
        variant: .hero,
        style: .splitI,
        markScale: splitIMarkScale
    )
    .padding(32)
    .cairnTheme()
}

// MARK: - markScale sweep

/// Renders the split-I wordmark at several `markScale` values
/// stacked vertically, so you can eyeball which proportion reads
/// best without editing and re-running between values. Labels
/// include the scale so you know what you're seeing. Tweak the
/// `sweepValues` array to change the lineup.
private struct MarkScaleSweep: View {
    let variant: CairnWordmark.Variant
    let sweepValues: [CGFloat] = [0.75, 0.90, 1.00, 1.10, 1.20, 1.35]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("markScale sweep · \(variant == .adaptive ? "adaptive" : "rich") mark")
                .font(.cairnScaled(size: 12, weight: .semibold))
                .opacity(0.6)
            ForEach(sweepValues, id: \.self) { scale in
                HStack(spacing: 18) {
                    Text(String(format: "%.2f", scale))
                        .font(.cairnScaled(size: 11, weight: .medium, design: .monospaced))
                        .opacity(0.5)
                        .frame(width: 38, alignment: .trailing)
                    CairnWordmark(
                        size: splitIFontSize,
                        variant: variant,
                        style: .splitI,
                        markScale: scale
                    )
                }
            }
        }
        .padding(28)
    }
}

#Preview("markScale sweep — adaptive") {
    MarkScaleSweep(variant: .adaptive)
        .cairnTheme()
}

#Preview("markScale sweep — rich") {
    MarkScaleSweep(variant: .hero)
        .cairnTheme()
}

#Preview("markScale sweep — dark") {
    MarkScaleSweep(variant: .adaptive)
        .cairnTheme()
        .preferredColorScheme(.dark)
}

#endif
