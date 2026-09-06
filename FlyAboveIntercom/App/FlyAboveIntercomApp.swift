import SwiftUI

@main
struct FlyAboveIntercomApp: App {
    @StateObject private var environment = AppEnvironment.live()

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
