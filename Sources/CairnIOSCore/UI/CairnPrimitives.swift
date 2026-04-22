import SwiftUI

// Shared SwiftUI primitives — the mark, headers, list rows, callouts.
//
// Each one mirrors a component from the prototype's parts.jsx (see file
// for vocabulary). Microcopy and visual patterns are deliberately faithful
// — see HANDOFF.md "Keep these copies verbatim" and "Visual language".

// MARK: - Brand mark

/// The 3-stone cairn brand mark, rendered as Swift-native vectors so we
/// don't ship a PNG/SVG asset for something so small.
///
/// Stack: a small stone on top, mid stone beneath, wide base stone.
/// Optionally crowned by a small "trash bin" cap (the destructive accent)
/// to match the prototype's `assets/cairn-mark.svg` lockup.
public struct CairnMark: View {
    public var size: CGFloat = 22
    public var crowned: Bool = false

    @Environment(\.cairnTokens) private var t

    public init(size: CGFloat = 22, crowned: Bool = false) {
        self.size = size
        self.crowned = crowned
    }

    public var body: some View {
        ZStack {
            VStack(spacing: size * 0.04) {
                if crowned {
                    Capsule()
                        .fill(t.primary)
                        .frame(width: size * 0.40, height: size * 0.10)
                }
                Capsule()
                    .fill(t.textBody)
                    .frame(width: size * 0.32, height: size * 0.18)
                Capsule()
                    .fill(t.textBody)
                    .frame(width: size * 0.55, height: size * 0.22)
                Capsule()
                    .fill(t.textBody)
                    .frame(width: size * 0.80, height: size * 0.26)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("cairn")
    }
}

// MARK: - App header

/// The screen header used at the top of every primary screen. Matches
/// prototype `parts.jsx::AppHeader` — title + optional subtitle, optional
/// leading and trailing slots.
public struct AppHeader<Leading: View, Trailing: View>: View {
    public let title: String
    public let subtitle: String?
    public let leading: Leading
    public let trailing: Trailing

    @Environment(\.cairnTokens) private var t

    public init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder leading: () -> Leading = { EmptyView() },
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if !(leading is EmptyView) {
                    leading
                }
                Text(title)
                    .font(.system(size: 28, weight: .semibold, design: .default))
                    .tracking(-0.6)
                    .foregroundStyle(t.text)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(t.textMuted)
                }
            }
            Spacer(minLength: 0)
            if !(trailing is EmptyView) {
                trailing
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }
}

// MARK: - Section keyline

/// The all-caps section header used between cards. Matches prototype's
/// `<div class="keyline">` block.
public struct KeylineSection: View {
    public let title: String
    public let trailing: AnyView?

    @Environment(\.cairnTokens) private var t

    public init(_ title: String) {
        self.title = title
        self.trailing = nil
    }

    public init<V: View>(_ title: String, @ViewBuilder trailing: () -> V) {
        self.title = title
        self.trailing = AnyView(trailing())
    }

    public var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(t.textMuted)
            Spacer()
            trailing
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 8)
    }
}

// MARK: - Card

/// The standard card container. Most settings rows and stat blocks live
/// inside one. Bone background on light, graphite on dark.
public struct CairnCard<Content: View>: View {
    public let content: Content

    @Environment(\.cairnTokens) private var t

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(t.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(t.divider, lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
    }
}

// MARK: - Rows

/// Label-on-left, value-on-right list row with optional chevron + tap.
/// Matches prototype `KeyValRow`.
public struct KeyValRow: View {
    public let label: String
    public let value: AnyView
    public let mono: Bool
    public let chevron: Bool
    public let onTap: (() -> Void)?

    @Environment(\.cairnTokens) private var t

    public init<V: View>(
        _ label: String,
        @ViewBuilder value: () -> V,
        mono: Bool = false,
        chevron: Bool = false,
        onTap: (() -> Void)? = nil
    ) {
        self.label = label
        self.value = AnyView(value())
        self.mono = mono
        self.chevron = chevron
        self.onTap = onTap
    }

    public init(
        _ label: String,
        value: String,
        mono: Bool = false,
        chevron: Bool = false,
        onTap: (() -> Void)? = nil
    ) {
        self.init(label, value: { Text(value) }, mono: mono, chevron: chevron, onTap: onTap)
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(t.textBody)
            Spacer(minLength: 12)
            value
                .font(.system(size: mono ? 13 : 15, design: mono ? .monospaced : .default))
                .foregroundStyle(t.textBody)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(t.textHint)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
    }
}

/// Toggle row: label on the left (with optional sublabel), switch on the
/// right. Mirrors prototype `ToggleRow`.
public struct ToggleRow: View {
    public let label: String
    public let sub: String?
    @Binding public var value: Bool

    @Environment(\.cairnTokens) private var t

    public init(_ label: String, sub: String? = nil, value: Binding<Bool>) {
        self.label = label
        self.sub = sub
        self._value = value
    }

    public var body: some View {
        HStack(alignment: sub == nil ? .center : .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 15))
                    .foregroundStyle(t.textBody)
                if let sub {
                    Text(sub)
                        .font(.system(size: 12))
                        .foregroundStyle(t.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Toggle("", isOn: $value)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }
}

/// Hairline divider used between rows inside a card.
public struct RowDivider: View {
    @Environment(\.cairnTokens) private var t
    public init() {}
    public var body: some View {
        Rectangle()
            .fill(t.divider)
            .frame(height: 0.5)
            .padding(.leading, 14)
    }
}

// MARK: - Stats

/// A single labeled stat in a row of stats. Tabular-numeral large display
/// number above a small sub-caption. Mirrors prototype `Stat`.
public struct Stat: View {
    public let label: String
    public let value: String
    public let sub: String?
    public let color: Color?

    @Environment(\.cairnTokens) private var t

    public init(label: String, value: String, sub: String? = nil, color: Color? = nil) {
        self.label = label
        self.value = value
        self.sub = sub
        self.color = color
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(t.textMuted)
            Text(value)
                .font(.system(size: 24, weight: .semibold).monospacedDigit())
                .tracking(-0.5)
                .foregroundStyle(color ?? t.text)
            if let sub {
                Text(sub)
                    .font(.system(size: 12))
                    .foregroundStyle(t.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Callouts

/// Inline-message block with a soft fill and a left-border accent.
/// Mirrors prototype `.callout-*` styles. Tone drives both the fill and
/// the accent ink.
public enum CalloutTone: Sendable {
    case info       // accent-info / blue
    case verified   // moss
    case pending    // amber
    case danger     // rust
}

public struct Callout<Content: View>: View {
    public let tone: CalloutTone
    public let icon: String?  // SF Symbol name
    public let content: Content

    @Environment(\.cairnTokens) private var t

    public init(_ tone: CalloutTone, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.tone = tone
        self.icon = icon
        self.content = content()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(inkColor)
            }
            content
                .font(.system(size: 13))
                .foregroundStyle(inkColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(softColor)
        .overlay(
            Rectangle()
                .fill(inkColor.opacity(0.55))
                .frame(width: 3)
                .padding(.vertical, -0.5),
            alignment: .leading
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var softColor: Color {
        switch tone {
        case .info: t.infoSoft
        case .verified: t.verifiedSoft
        case .pending: t.pendingSoft
        case .danger: t.dangerSoft
        }
    }

    private var inkColor: Color {
        switch tone {
        case .info: t.infoInk
        case .verified: t.verifiedInk
        case .pending: t.pendingInk
        case .danger: t.dangerInk
        }
    }
}

// MARK: - Tab bar

public struct CairnTab: Hashable, Sendable {
    public let id: String
    public let label: String
    public let systemImage: String?

    public init(id: String, label: String, systemImage: String?) {
        self.id = id
        self.label = label
        self.systemImage = systemImage
    }

    public static let status   = CairnTab(id: "status",   label: "Status",   systemImage: nil) // uses CairnMark
    public static let runs     = CairnTab(id: "runs",     label: "Runs",     systemImage: "list.bullet")
    public static let settings = CairnTab(id: "settings", label: "Settings", systemImage: "gearshape")
    public static let all: [CairnTab] = [.status, .runs, .settings]
}

/// Bottom tab bar matching the prototype's three-tab layout.
public struct CairnTabBar: View {
    @Binding public var active: CairnTab
    public let onChange: ((CairnTab) -> Void)?

    @Environment(\.cairnTokens) private var t

    public init(active: Binding<CairnTab>, onChange: ((CairnTab) -> Void)? = nil) {
        self._active = active
        self.onChange = onChange
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(CairnTab.all, id: \.id) { tab in
                Button {
                    active = tab
                    onChange?(tab)
                } label: {
                    VStack(spacing: 4) {
                        Group {
                            if tab.id == "status" {
                                CairnMark(size: 22)
                            } else if let sym = tab.systemImage {
                                Image(systemName: sym)
                                    .font(.system(size: 18))
                            }
                        }
                        .frame(height: 22)
                        Text(tab.label)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(active.id == tab.id ? t.text : t.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
        .background(t.surface)
        .overlay(
            Rectangle()
                .fill(t.divider)
                .frame(height: 0.5),
            alignment: .top
        )
    }
}

// MARK: - Mock thumbnail

/// Deterministic gradient-tile placeholder until real Immich thumbnails
/// land. Matches the prototype's `thumb.jsx` approach: hash the filename
/// to a stable hue, render as a soft gradient. Lets the layouts feel
/// populated without HTTP plumbing.
public struct MockAssetThumb: View {
    public let filename: String
    public let size: CGFloat
    public let isLivePair: Bool

    @Environment(\.cairnTokens) private var t

    public init(filename: String, size: CGFloat = 76, isLivePair: Bool = false) {
        self.filename = filename
        self.size = size
        self.isLivePair = isLivePair
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [color1, color2],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            if isLivePair {
                Image(systemName: "livephoto")
                    .font(.system(size: max(10, size * 0.18), weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.45), in: Circle())
                    .padding(4)
            }
        }
    }

    private var hue: Double {
        // Stable hash → 0…1 hue.
        var h: UInt64 = 1469598103934665603
        for byte in filename.utf8 {
            h ^= UInt64(byte)
            h &*= 1099511628211
        }
        return Double(h % 360) / 360.0
    }

    private var color1: Color { Color(hue: hue, saturation: 0.30, brightness: 0.85) }
    private var color2: Color { Color(hue: hue, saturation: 0.55, brightness: 0.55) }
}
