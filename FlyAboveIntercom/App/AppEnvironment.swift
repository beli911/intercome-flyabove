import Foundation
import SwiftUI

/// Composition root.
///
/// Without `FlyAboveAPIBaseURL` in `Info.plist` the app runs the offline demo:
/// the preview transport, the demo channel list, no login. That keeps the
/// project runnable for UI work without a server, and makes it obvious in one
/// place which mode is active.
@MainActor
final class AppEnvironment: ObservableObject {
    enum Phase: Equatable {
        case launching
        case signedOut
        /// The stored session is still good, but the server could not be
        /// reached. Signing the user out here would cost them a password entry
        /// over a problem that is not theirs.
        case unavailable(message: String)
        case ready
    }

    @Published private(set) var phase: Phase = .launching
    @Published private(set) var user: AuthenticatedUser?
    @Published private(set) var intercom: IntercomViewModel?
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?

    private let api: (any IntercomAPI)?
    private let auth: AuthService?
    private let audioSession: AudioSessionController

    var isDemoMode: Bool { api == nil }

    init(api: (any IntercomAPI)?, auth: AuthService?) {
        audioSession = AudioSessionController()
        self.api = api
        self.auth = auth
    }

    convenience init(baseURL: URL?, deviceName: String) {
        guard let baseURL else {
            self.init(api: nil, auth: nil)
            return
        }
        let api = HTTPIntercomAPI(baseURL: baseURL)
        self.init(
            api: api,
            auth: AuthService(api: api, store: KeychainTokenStore(), deviceName: deviceName)
        )
    }

    static func live() -> AppEnvironment {
        let raw = Bundle.main.object(forInfoDictionaryKey: "FlyAboveAPIBaseURL") as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = (trimmed?.isEmpty == false) ? URL(string: trimmed!) : nil
        return AppEnvironment(baseURL: baseURL, deviceName: DeviceNaming.current)
    }

    /// Called once at launch. Restores a Keychain session if there is one.
    func bootstrap() async {
        guard let auth else {
            intercom = IntercomViewModel(
                configuration: .demo,
                transport: PreviewIntercomTransport(),
                audioSession: audioSession
            )
            phase = .ready
            return
        }

        guard await auth.hasStoredSession() else {
            phase = .signedOut
            return
        }

        do {
            _ = try await auth.validAccessToken()
            try await loadProduction()
        } catch {
            if error.isAuthenticationFailure {
                // The credentials themselves were rejected; asking for the
                // password again is the only way forward.
                await auth.logout()
                phase = .signedOut
            } else {
                phase = .unavailable(message: error.readableMessage)
            }
        }
    }

    /// Retry after a transient failure, without touching the stored session.
    func retryBootstrap() async {
        phase = .launching
        await bootstrap()
    }

    func signIn(email: String, password: String) async {
        guard let auth else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            user = try await auth.login(email: email, password: password)
            try await loadProduction()
        } catch {
            errorMessage = error.readableMessage
        }
    }

    func signOut() async {
        if let intercom { await intercom.disconnect() }
        await auth?.logout()
        intercom = nil
        user = nil
        phase = .signedOut
    }

    /// Loads the first production the user belongs to. Choosing between several
    /// is M2; until then the client picks the only sensible default.
    private func loadProduction() async throws {
        guard let api, let auth else { return }
        let accessToken = try await auth.validAccessToken()

        let productions = try await api.productions(accessToken: accessToken)
        guard let production = productions.first else {
            throw AppEnvironmentError.noProductions
        }

        let descriptors = try await api.channels(productionID: production.id, accessToken: accessToken)
        let configuration = IntercomConfiguration(
            displayName: await auth.currentUser?.displayName ?? production.name,
            productionID: production.id,
            serverURL: nil,
            channels: descriptors.map(IntercomChannel.init(descriptor:))
        )

        user = await auth.currentUser
        intercom = IntercomViewModel(
            configuration: configuration,
            transport: LiveKitIntercomTransport(api: api, auth: auth),
            audioSession: audioSession
        )
        phase = .ready
    }
}

extension Error {
    /// True only when the server said our credentials are no good. A timeout or
    /// a 5xx says nothing about them.
    var isAuthenticationFailure: Bool {
        if let apiError = self as? APIError, case .unauthorized = apiError { return true }
        if let authError = self as? AuthError, case .notAuthenticated = authError { return true }
        return false
    }
}

enum AppEnvironmentError: LocalizedError {
    case noProductions

    var errorDescription: String? {
        "Ehhez a fiókhoz nincs produkció rendelve."
    }
}

extension Error {
    var readableMessage: String {
        (self as? LocalizedError)?.errorDescription ?? localizedDescription
    }
}
