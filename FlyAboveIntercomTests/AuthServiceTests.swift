import XCTest
@testable import FlyAboveIntercom

final class AuthServiceTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 10_000)

    private func makeService(
        api: StubAPI,
        store: any TokenStoring = InMemoryTokenStore(),
        now: @escaping @Sendable () -> Date
    ) -> AuthService {
        AuthService(api: api, store: store, deviceName: "Test iPhone", now: now)
    }

    func testLoginStoresTokens() async throws {
        let api = StubAPI()
        let store = InMemoryTokenStore()
        let epoch = epoch
        let subject = makeService(api: api, store: store, now: { epoch })

        let user = try await subject.login(email: "a@b.hu", password: "secret")

        XCTAssertEqual(user.email, "a@b.hu")
        let stored = try XCTUnwrap(try store.load())
        XCTAssertEqual(stored.accessToken, "access-1")
        XCTAssertEqual(stored.accessTokenExpiresAt, epoch.addingTimeInterval(900))
        let deviceName = await api.lastDeviceName()
        XCTAssertEqual(deviceName, "Test iPhone")
    }

    func testValidAccessTokenReusesUnexpiredToken() async throws {
        let api = StubAPI()
        let epoch = epoch
        let subject = makeService(api: api, store: InMemoryTokenStore(), now: { epoch })
        try await subject.login(email: "a@b.hu", password: "secret")

        let token = try await subject.validAccessToken()

        XCTAssertEqual(token, "access-1")
        let refreshCount = await api.refreshCount()
        XCTAssertEqual(refreshCount, 0)
    }

    func testExpiredTokenIsRefreshed() async throws {
        let api = StubAPI()
        let clock = Clock(value: epoch)
        let subject = makeService(api: api, store: InMemoryTokenStore(), now: { clock.value })
        try await subject.login(email: "a@b.hu", password: "secret")

        clock.value = epoch.addingTimeInterval(1_000) // past the 900s lifetime
        let token = try await subject.validAccessToken()

        XCTAssertEqual(token, "access-2")
        let refreshCount = await api.refreshCount()
        XCTAssertEqual(refreshCount, 1)
    }

    func testConcurrentExpiredCallsRefreshOnlyOnce() async throws {
        let api = StubAPI()
        await api.setRefreshDelay(.milliseconds(50))
        let clock = Clock(value: epoch)
        let subject = makeService(api: api, store: InMemoryTokenStore(), now: { clock.value })
        try await subject.login(email: "a@b.hu", password: "secret")
        clock.value = epoch.addingTimeInterval(1_000)

        async let first = subject.validAccessToken()
        async let second = subject.validAccessToken()
        async let third = subject.validAccessToken()
        let tokens = try await [first, second, third]

        XCTAssertEqual(tokens, ["access-2", "access-2", "access-2"])
        // Rotating refresh tokens make a second call fatal, not merely wasteful.
        let refreshCount = await api.refreshCount()
        XCTAssertEqual(refreshCount, 1)
    }

    func testRejectedRefreshClearsStoredSession() async throws {
        let api = StubAPI()
        await api.setRefreshResult(.failure(APIError.unauthorized(code: nil, message: nil)))
        let store = InMemoryTokenStore()
        let clock = Clock(value: epoch)
        let subject = makeService(api: api, store: store, now: { clock.value })
        try await subject.login(email: "a@b.hu", password: "secret")
        clock.value = epoch.addingTimeInterval(1_000)

        do {
            _ = try await subject.validAccessToken()
            XCTFail("A visszautasított refresh nem dobott hibát.")
        } catch {
            guard case APIError.unauthorized = error else {
                return XCTFail("Váratlan hiba: \(error)")
            }
        }

        XCTAssertNil(try store.load())
        let hasSession = await subject.hasStoredSession()
        XCTAssertFalse(hasSession)
    }

    func testTransientRefreshFailureKeepsSession() async throws {
        let api = StubAPI()
        await api.setRefreshResult(.failure(APIError.http(status: 503, code: nil, message: nil)))
        let store = InMemoryTokenStore()
        let clock = Clock(value: epoch)
        let subject = makeService(api: api, store: store, now: { clock.value })
        try await subject.login(email: "a@b.hu", password: "secret")
        clock.value = epoch.addingTimeInterval(1_000)

        _ = try? await subject.validAccessToken()

        // A 503 says nothing about our credentials; losing them would force an
        // unnecessary re-login in the middle of a show.
        XCTAssertNotNil(try store.load())
    }

    func testValidAccessTokenWithoutSessionThrows() async {
        let subject = makeService(api: StubAPI(), now: { Date() })
        do {
            _ = try await subject.validAccessToken()
            XCTFail("Bejelentkezés nélkül nem szabad tokent adnia.")
        } catch {
            XCTAssertEqual(error as? AuthError, .notAuthenticated)
        }
    }

    func testProfileIsRestoredFromTheStoreWithoutARefresh() async throws {
        // Relaunch with a token that has not expired: there is no refresh
        // response to learn the profile from, so it has to come off disk.
        let api = StubAPI()
        let epoch = epoch
        let store = InMemoryTokenStore()
        let first = makeService(api: api, store: store, now: { epoch })
        try await first.login(email: "a@b.hu", password: "secret")

        let second = makeService(api: api, store: store, now: { epoch })
        let user = await second.restoredUser()

        XCTAssertEqual(user?.email, "a@b.hu")
        XCTAssertEqual(user?.displayName, "Teszt Oper\u{00E1}tor")
        let refreshCount = await api.refreshCount()
        XCTAssertEqual(refreshCount, 0)
    }

    func testStoredSessionFromAnOlderBuildStillLoads() throws {
        // An item written before the profile was stored must not force a
        // re-login; it simply has no user yet.
        let json = #"{"accessToken":"a","refreshToken":"r","accessTokenExpiresAt":"2026-09-06T10:00:00.000Z"}"#
        let tokens = try JSONDecoder.intercom.decode(AuthTokens.self, from: Data(json.utf8))
        XCTAssertEqual(tokens.accessToken, "a")
        XCTAssertNil(tokens.user)
    }

    func testLogoutClearsStore() async throws {
        let api = StubAPI()
        let store = InMemoryTokenStore()
        let epoch = epoch
        let subject = makeService(api: api, store: store, now: { epoch })
        try await subject.login(email: "a@b.hu", password: "secret")

        await subject.logout()

        XCTAssertNil(try store.load())
        let logoutCount = await api.logoutCount()
        XCTAssertEqual(logoutCount, 1)
    }
}

// MARK: - Doubles

/// A mutable clock the tests move by hand, so nothing depends on wall time.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Date

    init(value: Date) { storage = value }

    var value: Date {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private actor StubAPI: IntercomAPI {
    private var refreshCalls = 0
    private var logoutCalls = 0
    private var deviceName: String?
    private var refreshDelay: Duration = .zero
    private var refreshResult: Result<AuthSessionResponse, any Error>?

    func setRefreshDelay(_ delay: Duration) { refreshDelay = delay }
    func setRefreshResult(_ result: Result<AuthSessionResponse, any Error>) { refreshResult = result }
    func refreshCount() -> Int { refreshCalls }
    func logoutCount() -> Int { logoutCalls }
    func lastDeviceName() -> String? { deviceName }

    private static func session(accessToken: String, refreshToken: String, email: String) -> AuthSessionResponse {
        let json = """
        {
          "accessToken": "\(accessToken)",
          "refreshToken": "\(refreshToken)",
          "expiresIn": 900,
          "user": {
            "id": "8B2B8A5C-1B7C-4E1E-9C1F-1E6C2E5C4A11",
            "displayName": "Teszt Operátor",
            "email": "\(email)"
          }
        }
        """
        // Decoded rather than constructed so the tests also cover the wire shape.
        return try! JSONDecoder.intercom.decode(AuthSessionResponse.self, from: Data(json.utf8))
    }

    func login(email: String, password _: String, deviceName: String) async throws -> AuthSessionResponse {
        self.deviceName = deviceName
        return Self.session(accessToken: "access-1", refreshToken: "refresh-1", email: email)
    }

    func refresh(refreshToken _: String) async throws -> AuthSessionResponse {
        refreshCalls += 1
        if refreshDelay > .zero { try? await Task.sleep(for: refreshDelay) }
        if let refreshResult { return try refreshResult.get() }
        return Self.session(accessToken: "access-2", refreshToken: "refresh-2", email: "a@b.hu")
    }

    func logout(accessToken _: String) async throws { logoutCalls += 1 }

    func productions(accessToken _: String) async throws -> [ProductionSummary] { [] }

    func channels(productionID _: UUID, accessToken _: String) async throws -> [ChannelDescriptor] { [] }

    func crew(productionID _: UUID, accessToken _: String) async throws -> [CrewMemberDescriptor] { [] }

    func invitePreview(code _: String, accessToken _: String) async throws -> InvitePreview {
        throw APIError.http(status: 404, code: "invite_not_found", message: nil)
    }

    func redeemInvite(code _: String, accessToken _: String) async throws -> ProductionSummary {
        throw APIError.http(status: 404, code: "invite_not_found", message: nil)
    }

    func startPrivateCall(
        productionID _: UUID,
        peerID _: UUID,
        accessToken _: String
    ) async throws -> ChannelDescriptor {
        throw APIError.http(status: 404, code: "not_found", message: nil)
    }

    func endPrivateCall(productionID _: UUID, channelID _: UUID, accessToken _: String) async throws {}

    func realtimeTokens(
        productionID _: UUID,
        channelIDs _: [UUID],
        accessToken _: String
    ) async throws -> RealtimeTokensResponse {
        RealtimeTokensResponse(url: URL(string: "wss://example.invalid")!, grants: [])
    }
}
