import XCTest
@testable import FlyAboveIntercom

/// End-to-end coverage for the real transport against a live LiveKit server and
/// the `dev-server/` API. It is the only test that proves the M1 media path,
/// rather than the client's own bookkeeping.
///
/// The whole suite skips itself when the dev stack is not reachable, so a normal
/// `xcodebuild test` on a machine without it still passes. To run it:
///
///     livekit-server --dev --bind 0.0.0.0
///     cd dev-server && npm start
///
/// See `dev-server/README.md`.
final class LiveKitTransportIntegrationTests: XCTestCase {
    private static let baseURL = URL(string: "http://127.0.0.1:8080/")!

    private var api: HTTPIntercomAPI!
    private var auth: AuthService!

    override func setUp() async throws {
        try await super.setUp()
        try await skipUnlessDevStackIsRunning()

        api = HTTPIntercomAPI(baseURL: Self.baseURL)
        auth = AuthService(
            api: api,
            store: InMemoryTokenStore(),
            deviceName: "IntegrationTest"
        )
    }

    // MARK: - REST

    func testLoginAndChannelListReflectPermissions() async throws {
        // The seeded camera operator may listen to the director line but not
        // talk on it, which is the case the UI has to render differently.
        try await auth.login(email: "kamera@flyabove.hu", password: "flyabove")
        let accessToken = try await auth.validAccessToken()

        let productions = try await api.productions(accessToken: accessToken)
        let production = try XCTUnwrap(productions.first)

        let descriptors = try await api.channels(
            productionID: production.id,
            accessToken: accessToken
        )
        let director = try XCTUnwrap(descriptors.first { $0.name == "Rendező" })

        XCTAssertTrue(director.canListen)
        XCTAssertFalse(director.canTalk)
        XCTAssertFalse(director.defaultListening)
    }

    func testRealtimeGrantWithheldWhereTalkIsNotAllowed() async throws {
        try await auth.login(email: "kamera@flyabove.hu", password: "flyabove")
        let accessToken = try await auth.validAccessToken()
        let productions = try await api.productions(accessToken: accessToken)
        let production = try XCTUnwrap(productions.first)
        let descriptors = try await api.channels(
            productionID: production.id,
            accessToken: accessToken
        )

        let response = try await api.realtimeTokens(
            productionID: production.id,
            channelIDs: descriptors.map(\.id),
            accessToken: accessToken
        )

        let director = try XCTUnwrap(descriptors.first { $0.name == "Rendező" })
        let grant = try XCTUnwrap(response.grants.first { $0.channelId == director.id })
        // The token is the enforcement point, not the client's `canTalk` flag.
        XCTAssertFalse(grant.canPublish)
        XCTAssertTrue(grant.canSubscribe)
        XCTAssertTrue(grant.roomName.hasPrefix("p_"))
    }

    func testExpiredAccessTokenIsRefreshedAgainstRealServer() async throws {
        // A clock far enough ahead that the 15-minute access token is stale,
        // forcing a real /v1/auth/refresh round trip.
        let future = Date().addingTimeInterval(3_600)
        let service = AuthService(
            api: api,
            store: InMemoryTokenStore(),
            deviceName: "IntegrationTest",
            now: { future }
        )
        try await service.login(email: "operator@flyabove.hu", password: "flyabove")

        let token = try await service.validAccessToken()

        // A refreshed token must still open a protected endpoint.
        let productions = try await api.productions(accessToken: token)
        XCTAssertFalse(productions.isEmpty)
    }

    // MARK: - Media

    func testTransportConnectsJoinsRoomAndPublishesOnTalk() async throws {
        let configuration = try await liveConfiguration(email: "operator@flyabove.hu")
        let transport = LiveKitIntercomTransport(api: api, auth: auth)
        let collector = EventCollector(stream: await transport.events())

        try await transport.connect(configuration: configuration)
        let connected = await collector.waitForConnected(timeout: 20)
        XCTAssertTrue(connected, "Nem érkezett .connected esemény.")

        let talkChannel = try XCTUnwrap(configuration.channels.first { $0.canTalk })
        do {
            try await withDeadline(20) {
                try await transport.setTalking(true, channelID: talkChannel.id)
                try await transport.setTalking(false, channelID: talkChannel.id)
            }
        } catch is IntegrationTimeout {
            await transport.disconnect()
            throw XCTSkip("A mikrofon publikálása nem fejeződött be — a szimulátornak nincs valódi felvevő eszköze. Futtasd fizikai iPhone-on.")
        }

        await transport.disconnect()
    }

    func testTalkIsRejectedWithoutPublishGrant() async throws {
        let configuration = try await liveConfiguration(email: "kamera@flyabove.hu")
        let transport = LiveKitIntercomTransport(api: api, auth: auth)
        let collector = EventCollector(stream: await transport.events())

        try await transport.connect(configuration: configuration)
        let connected = await collector.waitForConnected(timeout: 20)
        XCTAssertTrue(connected, "Nem érkezett .connected esemény.")

        let director = try XCTUnwrap(configuration.channels.first { !$0.canTalk })
        do {
            try await withDeadline(20) {
                try await transport.setTalking(true, channelID: director.id)
            }
            XCTFail("A szerver nem adott publish jogot, mégis engedte a Talkot.")
        } catch {
            guard case IntercomTransportError.notPermittedToTalk = error else {
                return XCTFail("Váratlan hiba: \(error)")
            }
        }

        await transport.disconnect()
    }

    func testTwoClientsSeeEachOtherOnTheSharedChannel() async throws {
        // The party-line claim in one test: two identities in the same room
        // must show up in each other's participant count.
        let firstConfiguration = try await liveConfiguration(email: "operator@flyabove.hu")
        let firstTransport = LiveKitIntercomTransport(api: api, auth: auth)
        let firstEvents = EventCollector(stream: await firstTransport.events())
        try await firstTransport.connect(configuration: firstConfiguration)
        let firstConnected = await firstEvents.waitForConnected(timeout: 20)
        XCTAssertTrue(firstConnected, "Az első kliens nem csatlakozott.")

        let secondAuth = AuthService(
            api: api,
            store: InMemoryTokenStore(),
            deviceName: "IntegrationTest 2"
        )
        try await secondAuth.login(email: "kamera@flyabove.hu", password: "flyabove")
        let secondConfiguration = try await liveConfiguration(auth: secondAuth)
        let secondTransport = LiveKitIntercomTransport(api: api, auth: secondAuth)
        let secondEvents = EventCollector(stream: await secondTransport.events())
        try await secondTransport.connect(configuration: secondConfiguration)
        let secondConnected = await secondEvents.waitForConnected(timeout: 20)
        XCTAssertTrue(secondConnected, "A második kliens nem csatlakozott.")

        let sharedChannel = try XCTUnwrap(firstConfiguration.channels.first {
            $0.name == "Mindenki"
        })
        let sawSecondClient = await firstEvents.waitForParticipantCount(
            atLeast: 2,
            channelID: sharedChannel.id,
            timeout: 20
        )
        let seen = await firstEvents.describe()
        XCTAssertTrue(
            sawSecondClient,
            "Az első kliens nem látta a másodikat. Kapott események: \(seen)"
        )

        await secondTransport.disconnect()
        await firstTransport.disconnect()
    }

    // MARK: - Helpers

    private func liveConfiguration(email: String) async throws -> IntercomConfiguration {
        try await auth.login(email: email, password: "flyabove")
        return try await liveConfiguration(auth: auth)
    }

    private func liveConfiguration(auth: AuthService) async throws -> IntercomConfiguration {
        let accessToken = try await auth.validAccessToken()
        let productions = try await api.productions(accessToken: accessToken)
        let production = try XCTUnwrap(productions.first)
        let descriptors = try await api.channels(
            productionID: production.id,
            accessToken: accessToken
        )
        return IntercomConfiguration(
            displayName: "Integrációs teszt",
            productionID: production.id,
            serverURL: nil,
            channels: descriptors.map(IntercomChannel.init(descriptor:))
        )
    }

    /// Bounds a media step. LiveKit can wait indefinitely on a capture device
    /// the simulator does not have, and a hanging integration test is worse
    /// than a failing one.
    private func withDeadline(
        _ seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw IntegrationTimeout()
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func skipUnlessDevStackIsRunning() async throws {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("v1/productions"))
        request.timeoutInterval = 2
        let response: URLResponse
        do {
            (_, response) = try await URLSession.intercom.data(for: request)
        } catch {
            throw XCTSkip("A dev stack nem fut (dev-server + livekit-server), a teszt kimarad.")
        }
        // 401 is the healthy answer: the endpoint exists and demands a token.
        // Anything else on this port is some other service, not our dev API.
        guard (response as? HTTPURLResponse)?.statusCode == 401 else {
            throw XCTSkip("A 8080-as porton nem a fejlesztői intercom API válaszol, a teszt kimarad.")
        }
    }
}

private struct IntegrationTimeout: Error {}

/// Buffers transport events so a test can wait for one instead of sleeping.
private actor EventCollector {
    private var events: [IntercomTransportEvent] = []

    init(stream: AsyncStream<IntercomTransportEvent>) {
        // Ends on its own when the transport tears the stream down.
        Task { [weak self] in
            for await event in stream { await self?.append(event) }
        }
    }

    private func append(_ event: IntercomTransportEvent) { events.append(event) }

    @discardableResult
    func waitForConnected(timeout: TimeInterval) async -> Bool {
        await waitFor(timeout: timeout) { events in
            events.contains { event in
                if case .connectionStateChanged(.connected) = event { return true }
                return false
            }
        }
    }

    func waitForParticipantCount(
        atLeast minimum: Int,
        channelID: UUID,
        timeout: TimeInterval
    ) async -> Bool {
        await waitFor(timeout: timeout) { events in
            events.contains { event in
                if case let .participantCountChanged(id, count) = event {
                    return id == channelID && count >= minimum
                }
                return false
            }
        }
    }

    func describe() -> [String] {
        events.map { event in
            switch event {
            case let .connectionStateChanged(state): "state(\(state))"
            case let .participantCountChanged(_, count): "participants(\(count))"
            case let .remoteSpeakingChanged(_, speaking): "speaking(\(speaking))"
            case .talkStopped: "talkStopped"
            case .statistics: "stats"
            }
        }
    }

    private func waitFor(
        timeout: TimeInterval,
        _ predicate: ([IntercomTransportEvent]) -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(events) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}
