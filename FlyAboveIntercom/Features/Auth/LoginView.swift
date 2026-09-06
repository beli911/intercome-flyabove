import SwiftUI

/// Sign-in, in the same equipment language as the intercom itself.
struct LoginView: View {
    @ObservedObject var environment: AppEnvironment

    @State private var email = ""
    @State private var password = ""
    @State private var isPasswordVisible = false
    @FocusState private var focusedField: Field?

    private enum Field { case email, password }

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && !environment.isBusy
    }

    var body: some View {
        ZStack {
            DS.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    wordmark
                    heading
                    fields
                    if let errorMessage = environment.errorMessage { errorStrip(errorMessage) }
                    submit
                }
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(.dark)
    }

    private var wordmark: some View {
        HStack(spacing: 10) {
            MonoLabel(text: "FA", size: 15, weight: .bold, color: DS.onAccent)
                .frame(width: 40, height: 40)
                .background(DS.accent)

            VStack(alignment: .leading, spacing: 2) {
                MonoLabel(text: "FLYABOVE", size: 12, weight: .bold, color: DS.ink)
                MonoLabel(text: "INTERCOM", size: 12, weight: .regular, color: DS.ink3)
            }
        }
        .padding(.top, 40)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Beléptetés\na produkcióba")
                .font(DS.display(30, .bold))
                .foregroundStyle(DS.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("A hozzáférést a produkciós admin adja ki.")
                .font(DS.display(13, .regular))
                .foregroundStyle(DS.ink3)
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                MonoLabel(text: "E-MAIL", size: 11, color: DS.ink2)
                TextField("", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }
                    .fieldChrome()
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    MonoLabel(text: "JELSZÓ", size: 11, color: DS.ink2)
                    Spacer()
                    Button { isPasswordVisible.toggle() } label: {
                        MonoLabel(
                            text: isPasswordVisible ? "REJT" : "MUTAT",
                            size: 11,
                            color: DS.accentText
                        )
                    }
                    .buttonStyle(.plain)
                }

                Group {
                    if isPasswordVisible {
                        TextField("", text: $password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        SecureField("", text: $password)
                    }
                }
                .textContentType(.password)
                .focused($focusedField, equals: .password)
                .submitLabel(.go)
                .onSubmit(submitLogin)
                .fieldChrome()
            }
        }
    }

    private func errorStrip(_ message: String) -> some View {
        Text(message)
            .font(DS.display(12, .regular))
            .foregroundStyle(DS.live)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(DS.live.opacity(0.12))
            .overlay(alignment: .leading) {
                Rectangle().frame(width: 3).foregroundStyle(DS.live)
            }
    }

    private var submit: some View {
        Group {
            if environment.isBusy {
                ProgressView()
                    .tint(DS.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: DS.actionHeight)
                    .background(DS.accent)
            } else {
                BlockButton(
                    title: "BEJELENTKEZÉS",
                    isPrimary: true,
                    isEnabled: canSubmit,
                    action: submitLogin
                )
            }
        }
    }

    private func submitLogin() {
        guard canSubmit else { return }
        focusedField = nil
        Task { await environment.signIn(email: email, password: password) }
    }
}

private extension View {
    /// Square, bordered input. The design has no rounded fields anywhere.
    func fieldChrome() -> some View {
        font(DS.display(16, .regular))
            .foregroundStyle(DS.ink)
            .tint(DS.accentText)
            .padding(.horizontal, 12)
            .frame(height: DS.actionHeight)
            .background(DS.surface)
            .overlay { Rectangle().stroke(DS.line, lineWidth: DS.hairline) }
    }
}
