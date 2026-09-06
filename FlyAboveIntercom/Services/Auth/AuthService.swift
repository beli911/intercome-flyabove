import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum AuthError: LocalizedError, Equatable {
    case notAuthenticated

    var errorDescription: String? {
        "Nincs érvényes bejelentkezés."
    }
}

/// The name the server shows in the session list, so a user can revoke a lost
/// phone. Main-actor isolated because `UIDevice` is.
@MainActor
enum DeviceNaming {
    static var current: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        "iOS"
        #endif
    }
}

/// Owns the session: the only component that reads and writes the token store,
/// and the only one that decides when an access token needs refreshing.
///
/// An actor because a refresh must happen exactly once even when several callers
/// (channel fetch, realtime token mint, reconnect) notice the expiry at the same
/// moment.
actor AuthService {
    private let api: any IntercomAPI
    private let store: any TokenStoring
    private let deviceName: String
    private let now: @Sendable () -> Date

    private var tokens: AuthTokens?
    private var didLoadFromStore = false
    private var refreshTask: Task<AuthSessionResponse, any Error>?

    private(set) var currentUser: AuthenticatedUser?

    init(
        api: any IntercomAPI,
        store: any TokenStoring,
        deviceName: String,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.api = api
        self.store = store
        self.deviceName = deviceName
        self.now = now
    }

    /// True when a previous session was found in the Keychain. It does not prove
    /// the refresh token is still accepted — only `validAccessToken()` can.
    func hasStoredSession() -> Bool {
        ((try? loadedTokens()) ?? nil) != nil
    }

    @discardableResult
    func login(email: String, password: String) async throws -> AuthenticatedUser {
        let session = try await api.login(email: email, password: password, deviceName: deviceName)
        try persist(session)
        return session.user
    }

    /// Returns a token that is valid right now, refreshing first if needed.
    func validAccessToken() async throws -> String {
        guard let current = try loadedTokens() else { throw AuthError.notAuthenticated }
        guard current.isExpired(now: now()) else { return current.accessToken }
        return try await refresh(using: current).accessToken
    }

    func logout() async {
        refreshTask?.cancel()
        refreshTask = nil
        if let accessToken = tokens?.accessToken {
            // Best effort: a server that never hears about the logout expires
            // the refresh token on its own.
            try? await api.logout(accessToken: accessToken)
        }
        discardSession()
    }

    // MARK: - Internals

    private func refresh(using current: AuthTokens) async throws -> AuthTokens {
        // A refresh is already in flight: ride along instead of burning the
        // refresh token a second time (most servers rotate it on use).
        if let inFlight = refreshTask {
            let session = try await inFlight.value
            return session.tokens(now: now())
        }

        let api = api
        let refreshToken = current.refreshToken
        let task = Task<AuthSessionResponse, any Error> {
            try await api.refresh(refreshToken: refreshToken)
        }
        refreshTask = task
        defer { refreshTask = nil }

        do {
            let session = try await task.value
            try persist(session)
            return session.tokens(now: now())
        } catch {
            if case APIError.unauthorized = error {
                // The refresh token itself was rejected; nothing stored is
                // usable any more.
                discardSession()
            }
            throw error
        }
    }

    private func persist(_ session: AuthSessionResponse) throws {
        let newTokens = session.tokens(now: now())
        tokens = newTokens
        currentUser = session.user
        didLoadFromStore = true
        try store.save(newTokens)
    }

    private func discardSession() {
        tokens = nil
        currentUser = nil
        didLoadFromStore = true
        try? store.clear()
    }

    private func loadedTokens() throws -> AuthTokens? {
        if !didLoadFromStore {
            tokens = try store.load()
            didLoadFromStore = true
        }
        return tokens
    }
}
