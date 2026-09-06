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
                case .ready:
                    if let intercom = environment.intercom {
                        RootView(
                            viewModel: intercom,
                            isDemoMode: environment.isDemoMode,
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
