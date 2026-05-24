import SwiftUI

/// Text input tuned for long secret keys — API tokens, bearer secrets,
/// anything pasted from a manager. Three features that plain
/// `SecureField` / `TextField` don't combine out of the box:
///
///   1. **Last-character preview** while typing: when masked, the trailing
///      `visibleTail` characters render in clear text so a live typist can
///      spot transpositions without fully unmasking.
///   2. **Toggleable reveal** via an inline eye / eye-slash button (44×44
///      hit target, per Apple HIG).
///   3. **Proper paste / cursor / autofill** — uses a standard `TextField`
///      underneath (not `SecureField`), so password managers and
///      long-press → Paste behave exactly as expected.
///
/// Implementation trick: a transparent `TextField` keeps the real
/// cursor, selection, and keyboard behavior; a `Text` overlay renders the
/// masked string on top. Because both use the same monospaced font, glyph
/// widths line up and the caret stays visually aligned with the masked
/// characters. Hit-testing is disabled on the overlay so taps fall through
/// to the TextField.
public struct ApiKeyInput: View {
    @Binding public var text: String
    public let placeholder: String
    /// How many trailing characters to leave unmasked. `1` mirrors the
    /// classic "show the last character you typed" affordance.
    public let visibleTail: Int
    public let onChange: () -> Void

    @State private var revealed: Bool = false
    @FocusState private var focused: Bool
    @Environment(\.cairnTokens) private var t

    public init(
        text: Binding<String>,
        placeholder: String,
        visibleTail: Int = 1,
        onChange: @escaping () -> Void = {}
    ) {
        self._text = text
        self.placeholder = placeholder
        self.visibleTail = visibleTail
        self.onChange = onChange
    }

    public var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "key")
                .font(.cairnScaled(size: 14))
                .foregroundStyle(t.textMuted)
                .padding(.leading, 14)

            ZStack(alignment: .leading) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.cairnScaled(size: 14, design: .monospaced))
                    .accessibilityLabel("API key")
                    // Single-line + horizontal scroll. Without this, a
                    // long pasted key wraps to a second line, which
                    // would poke out below the masking overlay since the
                    // overlay is one-line-only.
                    .lineLimit(1)
                    // Clear text (but leave placeholder alone) when the
                    // mask overlay is on top. Note: on iOS this alone
                    // doesn't suppress the paste animation, which can
                    // briefly show the real characters — the solid-
                    // backed overlay below closes that gap.
                    .foregroundColor(revealed || text.isEmpty ? t.textBody : .clear)
                    .tint(t.textBody)
                    .focused($focused)
                    .autocorrectionDisabled(true)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onChange(of: text) { _, _ in onChange() }

                if !revealed && !text.isEmpty {
                    // Overlay the masked rendering directly on top of
                    // the TextField's (transparent) characters. No
                    // full-row cover: the monospace glyph widths match
                    // the underlying TextField's character positions
                    // exactly, so the overlay Text terminates at the
                    // same x as the TextField's text would — leaving a
                    // clear lane for the caret, which TextField draws
                    // just past its text's right edge.
                    //
                    // `.lineLimit(1)` + `.truncationMode(.head)` keeps
                    // the unmasked tail visible when the key overflows;
                    // the trailing `t.surface` stripe is a narrow
                    // cushion that masks the paste-animation flash
                    // without swallowing the caret region.
                    Text(maskedDisplay)
                        .font(.cairnScaled(size: 14, design: .monospaced))
                        .foregroundStyle(t.textBody)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .background(t.surface)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            // Defensive: even with lineLimit(1), clip anything that
            // tries to grow beyond the row bounds so a hypothetical
            // rendering edge case can't poke secret characters out
            // past the frame.
            .clipped()

            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .font(.cairnScaled(size: 15, weight: .regular))
                    .foregroundStyle(t.textMuted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .accessibilityLabel(revealed ? "Hide API key" : "Show API key")
        }
    }

    /// Render the masked form. While the field is actively focused we
    /// leave the last `visibleTail` characters unmasked so the typist
    /// can spot transpositions. When focus moves away, every character
    /// is masked — matches iOS's own password-field idiom where the
    /// last-char preview is a typing affordance, not a persistent state.
    /// Uses the same `•` glyph as `ApiKeyRow` in Settings for visual
    /// continuity.
    private var maskedDisplay: String {
        let count = text.count
        let tailCount = focused ? min(visibleTail, count) : 0
        let maskedCount = max(0, count - tailCount)
        let masked = String(repeating: "•", count: maskedCount)
        let tail = String(text.suffix(tailCount))
        return masked + tail
    }
}

#if DEBUG
#Preview("ApiKeyInput — empty") {
    @Previewable @State var key = ""
    return CairnCard {
        ApiKeyInput(text: $key, placeholder: "paste key from Immich account settings")
    }
    .padding()
    .cairnTheme()
}

#Preview("ApiKeyInput — typed (masked with tail)") {
    @Previewable @State var key = "iad8f7sdf9asd7f_abc"
    return CairnCard {
        ApiKeyInput(text: $key, placeholder: "paste key from Immich account settings")
    }
    .padding()
    .cairnTheme()
}

#Preview("ApiKeyInput — typed (short)") {
    @Previewable @State var key = "a"
    return CairnCard {
        ApiKeyInput(text: $key, placeholder: "paste key")
    }
    .padding()
    .cairnTheme()
}

#Preview("ApiKeyInput — dark") {
    @Previewable @State var key = "long-sample-key-value-here"
    return CairnCard {
        ApiKeyInput(text: $key, placeholder: "paste key")
    }
    .padding()
    .cairnTheme()
    .preferredColorScheme(.dark)
}
#endif
