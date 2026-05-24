import SwiftUI
import CairnCore

/// Email + password form for acquiring an Immich session token. Lives
/// under Settings → Advanced → "Session sign-in for incremental sync."
/// Immich's `/sync/*` endpoints reject API-key auth, so until cairn
/// presents a session-derived Bearer token, the streaming coordinator
/// stays unreachable. This sheet is the user's path to enable it.
///
/// The form is intentionally minimal: email, password, "Sign in".
/// Failure renders inline; success dismisses the sheet and flips
/// `model.hasSessionToken` so the Settings row re-renders as
/// "Signed in."
public struct SessionSignInSheet: View {
    public let signIn: @Sendable (_ email: String, _ password: String) async -> CairnAppActions.SessionSignInResult
    public let onDismiss: () -> Void

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isSubmitting: Bool = false
    @State private var inlineError: String?

    @Environment(\.cairnTokens) private var t
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case email, password }

    public init(
        signIn: @escaping @Sendable (String, String) async -> CairnAppActions.SessionSignInResult,
        onDismiss: @escaping () -> Void
    ) {
        self.signIn = signIn
        self.onDismiss = onDismiss
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                explainer
                emailField
                passwordField
                signInButton
                if let inlineError {
                    Text(inlineError)
                        .font(.system(size: 13))
                        .foregroundStyle(t.dangerInk)
                        .padding(.top, 4)
                        .accessibilityAddTraits(.isStaticText)
                }
                Spacer(minLength: 32)
            }
            .padding(20)
        }
        .background(t.bg)
        .scrollDismissesKeyboard(.interactively)
    }

    private var header: some View {
        HStack {
            Text("Sign in for incremental sync")
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.45)
                .foregroundStyle(t.text)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(t.textMuted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    private var explainer: some View {
        Text("Incremental sync talks to an Immich endpoint that doesn't accept API keys. Signing in with your Immich email and password gives cairn a session token, stored locally in your iPhone's Keychain. Cairn uses it only for that one streaming path — every other request still uses your API key. Sign out anytime to drop the token; everything else keeps working.")
            .font(.system(size: 13))
            .foregroundStyle(t.textMuted)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var emailField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Email")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(t.textBody)
            TextField("you@example.com", text: $email)
                .autocorrectionDisabled(true)
                #if os(iOS)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .submitLabel(.next)
                #endif
                .focused($focusedField, equals: .email)
                .onSubmit { focusedField = .password }
                .padding(10)
                .background(t.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(t.divider, lineWidth: 0.5)
                )
                .accessibilityLabel("Email")
        }
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Password")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(t.textBody)
            SecureField("", text: $password)
                #if os(iOS)
                .textContentType(.password)
                .submitLabel(.go)
                #endif
                .focused($focusedField, equals: .password)
                .onSubmit { Task { await submit() } }
                .padding(10)
                .background(t.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(t.divider, lineWidth: 0.5)
                )
                .accessibilityLabel("Password")
        }
    }

    private var signInButton: some View {
        Button {
            Task { await submit() }
        } label: {
            HStack(spacing: 8) {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(t.primaryInk)
                }
                Text(isSubmitting ? "Signing in…" : "Sign in")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(t.primaryInk)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(canSubmit ? t.primary : t.primary.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit || isSubmitting)
        .accessibilityLabel(isSubmitting ? "Signing in" : "Sign in")
        .accessibilityHint("Calls /api/auth/login on your Immich server")
    }

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty
    }

    @MainActor
    private func submit() async {
        guard canSubmit, !isSubmitting else { return }
        isSubmitting = true
        inlineError = nil
        let result = await signIn(
            email.trimmingCharacters(in: .whitespaces),
            password
        )
        isSubmitting = false
        switch result {
        case .success:
            // Sheet host listens for hasSessionToken changes and
            // dismisses; we close locally too for snappier UX in case
            // the host's reconciliation runs a hair later.
            onDismiss()
        case .invalidCredentials:
            inlineError = "Invalid email or password. Check your Immich credentials and try again."
        case .serverError(let code, let body):
            inlineError = "Immich returned HTTP \(code): \(body)"
        case .networkError(let message):
            inlineError = message
        }
    }
}

#if DEBUG
#Preview("Session sign-in — light") {
    SessionSignInSheet(
        signIn: { _, _ in .success },
        onDismiss: {}
    )
    .cairnTheme()
}

#Preview("Session sign-in — invalid credentials") {
    SessionSignInSheet(
        signIn: { _, _ in .invalidCredentials },
        onDismiss: {}
    )
    .cairnTheme()
}
#endif
