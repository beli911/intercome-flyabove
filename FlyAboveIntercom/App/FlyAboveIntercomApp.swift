import SwiftUI

@main
struct FlyAboveIntercomApp: App {
    @StateObject private var environment = AppEnvironment.live()

    /// Only offered once there is a session: redeeming needs a token.
    private var invitePresented: Binding<Bool> {
        Binding(
            get: {
                environment.pendingInviteCode != nil
                    && environment.phase != .signedOut
                    && environment.phase != .launching
            },
            set: { if !$0 { environment.pendingInviteCode = nil } }
        )
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch environment.phase {
                case .launching:
                    ProgressView("Indulás…")
                case .signedOut:
                    LoginView(environment: environment)
                case .choosingProduction:
                    ProductionPickerView(
                        environment: environment,
                        onSignOut: { await environment.signOut() }
                    )
                case let .unavailable(message):
                    UnavailableView(message: message) {
                        await environment.retryBootstrap()
                    }
                case .ready:
                    if let intercom = environment.intercom {
                        RootView(
                            viewModel: intercom,
                            isDemoMode: environment.isDemoMode,
                            crew: environment.crew,
                            onChangeProduction: environment.productions.count > 1
                                ? { await environment.leaveProduction() }
                                : nil,
                            // No session in demo mode, so nothing to sign out of.
                            onSignOut: environment.isDemoMode
                                ? nil
                                : { await environment.signOut() }
                        )
                    } else {
                        ProgressView()
                    }
                }
            }
            .task { await environment.bootstrap() }
            .onOpenURL { url in environment.handle(inviteURL: url) }
            // Presented over whatever is on screen, because an invite can
            // arrive at any point — including while already in a production.
            .sheet(isPresented: invitePresented) {
                InviteRedeemView(
                    environment: environment,
                    initialCode: environment.pendingInviteCode ?? "",
                    onCancel: { environment.pendingInviteCode = nil }
                )
            }
        }
    }
}

/// Shown when the stored session is intact but the server could not be reached.
/// Deliberately not a sign-out: the user's credentials are not the problem.
private struct UnavailableView: View {
    let message: String
    let onRetry: () async -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("A szerver nem érhető el")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Újra") { Task { await onRetry() } }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}
