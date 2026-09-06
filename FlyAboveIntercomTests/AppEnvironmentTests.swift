import XCTest
@testable import FlyAboveIntercom

@MainActor
final class AppEnvironmentTests: XCTestCase {
    private func makeEnvironment(api: StubAPI, store: InMemoryTokenStore) -> AppEnvironment {
        AppEnvironment(
            api: api,
            auth: AuthService(api: api, store: store, deviceName: "Teszt")
        )
    }

    private func storedSession() -> InMemoryTokenStore {
        InMemoryTokenStore(tokens: AuthTokens(
            accessToken: "access",
            refreshToken: "refresh",
            accessTokenExpiresAt: Date().addingTimeInterval(3_600)
        ))
    }

    func testServerOutageAtLaunchKeepsTheStoredSession() async {
        let api = StubAPI()
        await api.setProductionsResult(.failure(APIError.http(status: 503, code: nil, message: "Karbantartás")))
        let store = storedSession()
        let subject = makeEnvironment(api: api, store: store)

        await subject.bootstrap()

        // A 503 says nothing about the credentials. Signing the user out would
        // cost a password entry in the middle of a show, over the server's
        // problem.
        guard case .unavailable = subject.phase else {
            return XCTFail("Váratlan fázis: \(subject.phase)")
        }
        XCTAssertNotNil(try? store.load() ?? nil)
    }

    func testNetworkTimeoutAtLaunchKeepsTheStoredSession() async {
        let api = StubAPI()
        let timeout = URLError(.timedOut)
        await api.setProductionsResult(.failure(APIError.transport(timeout)))
        let store = storedSession()
        let subject = makeEnvironment(api: api, store: store)

        await subject.bootstrap()

        guard case .unavailable = subject.phase else {
            return XCTFail("Váratlan fázis: \(subject.phase)")
        }
        XCTAssertNotNil(try? store.load() ?? nil)
    }

    func testRejectedCredentialsAtLaunchClearTheSession() async {
        let api = StubAPI()
        await api.setProductionsResult(.failure(APIError.unauthorized(code: nil, message: nil)))
        let store = storedSession()
        let subject = makeEnvironment(api: api, store: store)

        await subject.bootstrap()

        XCTAssertEqual(subject.phase, .signedOut)
        XCTAssertNil(try? store.load() ?? nil)
    }

    func testRetryAfterOutageSucceeds() async {
        let api = StubAPI()
        await api.setProductionsResult(.failure(APIError.http(status: 503, code: nil, message: nil)))
        let subject = makeEnvironment(api: api, store: storedSession())
        await subject.bootstrap()

        await api.setProductionsResult(.success([
            ProductionSummary(id: UUID(), name: "Teszt produkció", role: "operator")
        ]))
        await subject.retryBootstrap()

        XCTAssertEqual(subject.phase, .ready)
        XCTAssertNotNil(subject.intercom)
    }

    func testDemoModeNeedsNoServer() async {
        let subject = AppEnvironment(api: nil, auth: nil)

        await subject.bootstrap()

        XCTAssertTrue(subject.isDemoMode)
        XCTAssertEqual(subject.phase, .ready)
        XCTAssertNotNil(subject.intercom)
    }

    func testAccountWithoutProductionsReportsItRatherThanSigningOut() async {
        let api = StubAPI()
        await api.setProductionsResult(.success([]))
        let store = storedSession()
        let subject = makeEnvironment(api: api, store: store)

        await subject.bootstrap()

        guard case .unavailable = subject.phase else {
            return XCTFail("Váratlan fázis: \(subject.phase)")
        }
        XCTAssertNotNil(try? store.load() ?? nil)
    }
}

private actor StubAPI: IntercomAPI {
    private var productionsResult: Result<[ProductionSummary], any Error> = .success([])

    func setProductionsResult(_ result: Result<[ProductionSummary], any Error>) {
        productionsResult = result
    }

    func login(email: String, password _: String, deviceName _: String) async throws -> AuthSessionResponse {
        throw APIError.unauthorized(code: nil, message: nil)
    }

    func refresh(refreshToken _: String) async throws -> AuthSessionResponse {
        throw APIError.unauthorized(code: nil, message: nil)
    }

    func logout(accessToken _: String) async throws {}

    func productions(accessToken _: String) async throws -> [ProductionSummary] {
        try productionsResult.get()
    }

    func channels(productionID _: UUID, accessToken _: String) async throws -> [ChannelDescriptor] {
        [
            ChannelDescriptor(
                id: UUID(),
                name: "Mindenki",
                detail: "Teljes produkció",
                colorHex: "5B8CFF",
                canTalk: true,
                canListen: true,
                defaultListening: true,
                participantCount: 0
            )
        ]
    }

    func crew(productionID _: UUID, accessToken _: String) async throws -> [CrewMemberDescriptor] { [] }

    func invitePreview(code _: String, accessToken _: String) async throws -> InvitePreview {
        throw APIError.http(status: 404, code: "invite_not_found", message: nil)
    }

    func redeemInvite(code _: String, accessToken _: String) async throws -> ProductionSummary {
        throw APIError.http(status: 404, code: "invite_not_found", message: nil)
    }

    func realtimeTokens(
        productionID _: UUID,
        channelIDs _: [UUID],
        accessToken _: String
    ) async throws -> RealtimeTokensResponse {
        RealtimeTokensResponse(url: URL(string: "wss://example.invalid")!, grants: [])
    }
}
