import SwiftUI

struct LoginView: View {
    @ObservedObject var environment: AppEnvironment

    @State private var email = ""
    @State private var password = ""
    @FocusState private var focusedField: Field?

    private enum Field { case email, password }

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && !environment.isBusy
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text("FlyAbove Intercom")
                        .font(.title2.bold())
                    Text("Jelentkezz be a produkciós fiókoddal.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    TextField("E-mail", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }

                    SecureField("Jelszó", text: $password)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { submit() }
                }
                .textFieldStyle(.roundedBorder)

                if let errorMessage = environment.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: submit) {
                    if environment.isBusy {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Bejelentkezés").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canSubmit)

                Spacer()
            }
            .padding(24)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        focusedField = nil
        Task { await environment.signIn(email: email, password: password) }
    }
}
