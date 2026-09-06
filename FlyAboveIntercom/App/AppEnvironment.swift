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
        /// More than one production: the operator picks. With exactly one this
        /// step is skipped — a chooser with a single row is a speed bump.
        case choosingProduction
        case ready
    }

    @Published private(set) var phase: Phase = .launching
    @Published private(set) var user: AuthenticatedUser?
    @Published private(set) var intercom: IntercomViewModel?
    @Published private(set) var productions: [ProductionSummary] = []
    @Published private(set) var selectedProduction: ProductionSummary?
    @Published private(set) var crew: [CrewMember] = []
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    /// Set when `Info.plist` carries a base URL the app refuses to use.
    @Published private(set) var configurationFailure: String?

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
        let raw = Bundle.main.object(forInfoDictionaryKey: "FlyAboveAPIBaseURL") as? String ?? ""
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // No server configured: offline demo.
            return AppEnvironment(baseURL: nil, deviceName: DeviceNaming.current)
        }

        do {
            let baseURL = try APIBaseURL.normalised(raw)
            return AppEnvironment(baseURL: baseURL, deviceName: DeviceNaming.current)
        } catch {
            // A misconfigured build must say so, not quietly fall back to the
            // demo and look like it is working.
            let environment = AppEnvironment(baseURL: nil, deviceName: DeviceNaming.current)
            environment.reportConfigurationFailure(error.readableMessage)
            return environment
        }
    }

    private func reportConfigurationFailure(_ message: String) {
        configurationFailure = message
    }

    /// Called once at launch. Restores a Keychain session if there is one.
    func bootstrap() async {
        if let configurationFailure {
            phase = .unavailable(message: configurationFailure)
            return
        }

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

    private func loadProduction() async throws {
        guard let api, let auth else { return }
        let accessToken = try await auth.validAccessToken()

        let available = try await api.productions(accessToken: accessToken)
        guard !available.isEmpty else { throw AppEnvironmentError.noProductions }
        productions = available
        user = await auth.restoredUser()

        // One production is not a choice worth making the operator confirm.
        if available.count == 1 {
            try await enter(production: available[0])
        } else {
            phase = .choosingProduction
        }
    }

    func selectProduction(_ production: ProductionSummary) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await enter(production: production)
        } catch {
            errorMessage = error.readableMessage
        }
    }

    /// Back to the chooser. Only offered when there is something to choose.
    func leaveProduction() async {
        guard productions.count > 1 else { return }
        if let intercom { await intercom.disconnect() }
        intercom = nil
        selectedProduction = nil
        crew = []
        phase = .choosingProduction
    }

    private func enter(production: ProductionSummary) async throws {
        guard let api, let auth else { return }
        let accessToken = try await auth.validAccessToken()
        let descriptors = try await api.channels(productionID: production.id, accessToken: accessToken)
        let restoredUser = await auth.restoredUser()

        let configuration = IntercomConfiguration(
            displayName: restoredUser?.displayName ?? production.name,
            productionName: production.name,
            productionID: production.id,
            serverURL: nil,
            channels: descriptors.map(IntercomChannel.init(descriptor:))
        )

        selectedProduction = production
        user = restoredUser
        intercom = IntercomViewModel(
            configuration: configuration,
            transport: LiveKitIntercomTransport(api: api, auth: auth),
            audioSession: audioSession
        )
        phase = .ready

        // The roster is useful even before anyone connects, and a failure to
        // fetch it must not keep the operator off the line.
        await loadCrew(productionID: production.id)
    }

    func loadCrew(productionID: UUID) async {
        guard let api, let auth else { return }
        do {
            let accessToken = try await auth.validAccessToken()
            let descriptors = try await api.crew(productionID: productionID, accessToken: accessToken)
            crew = descriptors.map {
                CrewMember(
                    id: $0.id,
                    displayName: $0.displayName,
                    role: $0.role,
                    isOnline: false,
                    isSpeaking: false,
                    quality: .unknown,
                    activeChannelIDs: []
                )
            }
        } catch {
            crew = []
        }
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
