import LiveKit
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

        // By position, not by name: a channel's name is server-owned and can
        // change under the test.
        let sharedChannel = try XCTUnwrap(firstConfiguration.channels.first { $0.canListen })
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

    /// Concurrent leave/rejoin must leave the client with exactly one live
    /// connection, and nothing behind after a disconnect.
    ///
    /// A caveat worth stating: this does **not** prove the orphan-room guard in
    /// `performJoin`. LiveKit evicts an earlier participant with the same
    /// identity, so a room this client lost track of can never show up as a
    /// duplicate in the server's participant list. Verified by removing the
    /// guard: the test still passed six times out of six. The guard is reasoned
    /// and code-level; observing it needs a hook this suite does not have.
    func testJoinLeaveRejoinChurnLeavesExactlyOneConnection() async throws {
        let configuration = try await liveConfiguration(email: "operator@flyabove.hu")
        let transport = LiveKitIntercomTransport(api: api, auth: auth)
        let collector = EventCollector(stream: await transport.events())

        try await transport.connect(configuration: configuration)
        let connected = await collector.waitForConnected(timeout: 20)
        XCTAssertTrue(connected, "Nem érkezett .connected esemény.")

        let channel = try XCTUnwrap(configuration.channels.first { $0.canTalk && $0.canListen })
        let production = try XCTUnwrap(configuration.productionID)
        let roomName = "p_\(production.uuidString.lowercased()).c_\(channel.id.uuidString.lowercased())"

        // Concurrent leave and rejoin, which is what a jittery finger on LISTEN
        // and TALK produces. Sequential churn would not reproduce this: the race
        // needs a leave to land while a join is still suspended inside
        // `room.connect`, so the calls must genuinely overlap.
        for _ in 0 ..< 6 {
            async let leaving: Void = transport.setListening(false, channelID: channel.id)
            async let rejoining: Void = transport.setListening(true, channelID: channel.id)
            _ = try? await (leaving, rejoining)
        }
        // The churn's own outcome is order-dependent and therefore not something
        // to assert on. Settle it with one explicit join, so the invariant under
        // test is well defined: whatever happened, we end up with exactly one
        // connection — not zero, and crucially not an abandoned second one.
        try await transport.setListening(true, channelID: channel.id)
        try? await Task.sleep(for: .seconds(2))

        // Ask the server, not the client: an orphan connection is invisible to
        // the client that lost track of it.
        let identities = try await participantIdentities(inRoom: roomName)
        let currentUser = await auth.currentUser
        let user = try XCTUnwrap(currentUser)
        XCTAssertEqual(
            identities.filter { $0 == user.id.uuidString.lowercased() }.count,
            1,
            "A szoba több kapcsolatot lát tőlünk: \(identities)"
        )

        await transport.disconnect()

        // And nothing of ours may survive the disconnect.
        try? await Task.sleep(for: .seconds(1))
        let afterDisconnect = try await participantIdentities(inRoom: roomName)
        XCTAssertFalse(
            afterDisconnect.contains(user.id.uuidString.lowercased()),
            "Bontás után is bent maradt egy kapcsolat: \(afterDisconnect)"
        )
    }

    /// The one test that proves the permission is real.
    ///
    /// Every other check stops at the client's own `guard grant.canPublish`,
    /// which only shows that a cooperative client behaves. Here a bare LiveKit
    /// room joins with the very token the server minted and tries to publish
    /// anyway — the way a modified or hostile build would. The server has to be
    /// the thing that refuses.
    func testServerRefusesPublishEvenWhenTheClientIgnoresTheGrant() async throws {
        try await auth.login(email: "kamera@flyabove.hu", password: "flyabove")
        let accessToken = try await auth.validAccessToken()
        let productions = try await api.productions(accessToken: accessToken)
        let production = try XCTUnwrap(productions.first)
        let descriptors = try await api.channels(productionID: production.id, accessToken: accessToken)
        let director = try XCTUnwrap(descriptors.first { $0.name == "Rendez\u{0151}" })
        XCTAssertFalse(director.canTalk)

        let response = try await api.realtimeTokens(
            productionID: production.id,
            channelIDs: [director.id],
            accessToken: accessToken
        )
        let grant = try XCTUnwrap(response.grants.first { $0.channelId == director.id })
        XCTAssertFalse(grant.canPublish)

        // No FlyAbove code in the way: a raw room, the server's own token.
        let room = Room()
        try await room.connect(url: response.url.absoluteString, token: grant.token)

        var publishError: (any Error)?
        do {
            _ = try await room.localParticipant.setMicrophone(enabled: true)
        } catch {
            publishError = error
        }

        let published = !room.localParticipant.audioTracks.isEmpty
        // Tear the room down before asserting: a room left connected past the
        // end of the test drags its disconnect into the next one.
        await room.disconnect()

        XCTAssertFalse(
            published,
            "A szerver \u{00E1}tengedte a publish-t olyan tokennel, ami nem engedi."
        )
        XCTAssertNotNil(
            publishError,
            "A publish hiba n\u{00E9}lk\u{00FC}l futott le, pedig a token tiltja."
        )
    }

    /// Grants live an hour. A room re-joined after a long outage must not
    /// present a token the server has stopped honouring, so the transport
    /// renews them well ahead of expiry.
    func testGrantsAreRenewedBeforeTheyExpire() async throws {
        let configuration = try await liveConfiguration(email: "operator@flyabove.hu")
        let counting = CountingAPI(wrapping: api)
        // A lead time longer than the token's own life makes every grant look
        // "expiring soon", which is what a real one-hour-old grant would be.
        let transport = LiveKitIntercomTransport(
            api: counting,
            auth: auth,
            grantRenewalInterval: .milliseconds(300),
            grantRenewalLeadTime: 24 * 60 * 60
        )
        let collector = EventCollector(stream: await transport.events())

        try await transport.connect(configuration: configuration)
        let connected = await collector.waitForConnected(timeout: 20)
        XCTAssertTrue(connected)

        let initial = await counting.realtimeTokenCallCount()
        try? await Task.sleep(for: .seconds(2))
        let afterwards = await counting.realtimeTokenCallCount()

        await transport.disconnect()
        XCTAssertGreaterThan(
            afterwards,
            initial,
            "A transport nem \u{00FA}j\u{00ED}totta meg a lej\u{00E1}rathoz k\u{00F6}zeli granteket."
        )
    }

    /// A line the server drops must come back on its own.
    ///
    /// Evicting the participant is the only way to produce a disconnect the
    /// client did not ask for; LiveKit's own reconnect cannot recover from it,
    /// so this exercises the layer above it.
    func testAnEvictedChannelRecoversByItself() async throws {
        let configuration = try await liveConfiguration(email: "operator@flyabove.hu")
        let transport = LiveKitIntercomTransport(api: api, auth: auth, recoveryAttempts: 5)
        let collector = EventCollector(stream: await transport.events())

        try await transport.connect(configuration: configuration)
        let connected = await collector.waitForConnected(timeout: 20)
        XCTAssertTrue(connected)

        let channel = try XCTUnwrap(configuration.channels.first { $0.canListen })
        let production = try XCTUnwrap(configuration.productionID)
        let roomName = "p_\(production.uuidString.lowercased()).c_\(channel.id.uuidString.lowercased())"
        let currentUser = await auth.currentUser
        let identity = try XCTUnwrap(currentUser).id.uuidString.lowercased()

        try await evictParticipant(identity, fromRoom: roomName)

        // Recovery backs off, so give it room: re-mint, rejoin, settle.
        var recovered = false
        for _ in 0 ..< 40 {
            try? await Task.sleep(for: .seconds(1))
            if try await participantIdentities(inRoom: roomName).contains(identity) {
                recovered = true
                break
            }
        }

        await transport.disconnect()
        XCTAssertTrue(recovered, "A kil\u{00E9}ptetett vonal nem \u{00E1}llt helyre mag\u{00E1}t\u{00F3}l.")
    }

    /// The admin push, end to end.
    ///
    /// Nothing else in the suite covers the path from a REST change, through
    /// the LiveKit data channel, to the client noticing. The rename is
    /// incidental; what is under test is that the broadcast arrives at all.
    func testAServerSideChannelChangeReachesTheClient() async throws {
        // The second seed production is the one this account supervises, and
        // only a supervisor may change a channel.
        let configuration = try await liveConfiguration(
            email: "operator@flyabove.hu",
            productionNamed: "Reggeli stúdió — 4. blokk"
        )
        let transport = LiveKitIntercomTransport(api: api, auth: auth)
        let collector = EventCollector(stream: await transport.events())

        try await transport.connect(configuration: configuration)
        let connected = await collector.waitForConnected(timeout: 20)
        XCTAssertTrue(connected)

        let production = try XCTUnwrap(configuration.productionID)
        let channel = try XCTUnwrap(configuration.channels.first)
        let originalName = channel.name
        let renamed = "\(originalName) \(Int.random(in: 100 ... 999))"
        try await patchChannel(
            production: production,
            channel: channel.id,
            body: ["name": renamed]
        )

        let noticed = await collector.waitForConfigurationStale(timeout: 20)

        // The dev seed shares its channel list between productions, so a test
        // that leaves one renamed breaks whatever runs next.
        try? await patchChannel(
            production: production,
            channel: channel.id,
            body: ["name": originalName]
        )
        await transport.disconnect()

        XCTAssertTrue(noticed, "A szerver konfigurációs broadcastja nem ért el a klienshez.")
    }

    /// A private call as the client actually experiences it: a channel that
    /// appears at both ends, carried by the configuration push.
    func testAPrivateCallAppearsAsAChannelAndCanBeEnded() async throws {
        try await auth.login(email: "operator@flyabove.hu", password: "flyabove")
        let accessToken = try await auth.validAccessToken()
        let productions = try await api.productions(accessToken: accessToken)
        let production = try XCTUnwrap(productions.first)
        let before = try await api.channels(productionID: production.id, accessToken: accessToken)

        let crew = try await api.crew(productionID: production.id, accessToken: accessToken)
        let currentUser = await auth.currentUser
        let me = try XCTUnwrap(currentUser)
        let peer = try XCTUnwrap(crew.first { $0.id != me.id })

        let call = try await api.startPrivateCall(
            productionID: production.id,
            peerID: peer.id,
            accessToken: accessToken
        )
        XCTAssertEqual(call.isPrivate, true)
        // Named after the other person, so both ends see who they are talking to.
        XCTAssertEqual(call.name, peer.displayName)
        XCTAssertEqual(call.canTalk, true)

        let during = try await api.channels(productionID: production.id, accessToken: accessToken)
        XCTAssertEqual(during.count, before.count + 1)

        // Asking again must join the same line, not open a second one.
        _ = try await api.startPrivateCall(
            productionID: production.id,
            peerID: peer.id,
            accessToken: accessToken
        )
        let again = try await api.channels(productionID: production.id, accessToken: accessToken)
        XCTAssertEqual(again.count, during.count)

        try await api.endPrivateCall(
            productionID: production.id,
            channelID: call.id,
            accessToken: accessToken
        )
        let after = try await api.channels(productionID: production.id, accessToken: accessToken)
        XCTAssertEqual(after.count, before.count)
        XCTAssertFalse(after.contains { $0.id == call.id })
    }

    /// Starting a call must reach the client the same way any other channel
    /// change does — that is the whole reason it is modelled as a channel.
    func testAPrivateCallIsAnnouncedOverTheDataChannel() async throws {
        let configuration = try await liveConfiguration(email: "operator@flyabove.hu")
        let transport = LiveKitIntercomTransport(api: api, auth: auth)
        let collector = EventCollector(stream: await transport.events())
        try await transport.connect(configuration: configuration)
        let connected = await collector.waitForConnected(timeout: 20)
        XCTAssertTrue(connected)

        let accessToken = try await auth.validAccessToken()
        let production = try XCTUnwrap(configuration.productionID)
        let crew = try await api.crew(productionID: production, accessToken: accessToken)
        let currentUser = await auth.currentUser
        let me = try XCTUnwrap(currentUser)
        let peer = try XCTUnwrap(crew.first { $0.id != me.id })

        let call = try await api.startPrivateCall(
            productionID: production,
            peerID: peer.id,
            accessToken: accessToken
        )
        let noticed = await collector.waitForConfigurationStale(timeout: 20)

        try? await api.endPrivateCall(
            productionID: production,
            channelID: call.id,
            accessToken: accessToken
        )
        await transport.disconnect()
        XCTAssertTrue(noticed, "A privát hívás nem került kihirdetésre a klienshez.")
    }

    // MARK: - Helpers

    private struct DebugParticipants: Decodable {
        struct Participant: Decodable { let identity: String }
        let participants: [Participant]
    }

    private func evictParticipant(_ identity: String, fromRoom roomName: String) async throws {
        let accessToken = try await auth.validAccessToken()
        let encodedRoom = roomName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? roomName
        var request = URLRequest(
            url: Self.baseURL.appendingPathComponent(
                "v1/debug/rooms/\(encodedRoom)/participants/\(identity)/remove"
            )
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        _ = try await URLSession.intercom.data(for: request)
    }

    private func participantIdentities(inRoom roomName: String) async throws -> [String] {
        let accessToken = try await auth.validAccessToken()
        let encoded = roomName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? roomName
        var request = URLRequest(
            url: Self.baseURL.appendingPathComponent("v1/debug/rooms/\(encoded)/participants")
        )
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.intercom.data(for: request)
        return try JSONDecoder.intercom.decode(DebugParticipants.self, from: data)
            .participants
            .map(\.identity)
    }

    private func liveConfiguration(email: String) async throws -> IntercomConfiguration {
        try await auth.login(email: email, password: "flyabove")
        return try await liveConfiguration(auth: auth)
    }

    private func liveConfiguration(
        email: String,
        productionNamed name: String
    ) async throws -> IntercomConfiguration {
        try await auth.login(email: email, password: "flyabove")
        let accessToken = try await auth.validAccessToken()
        let productions = try await api.productions(accessToken: accessToken)
        let production = try XCTUnwrap(productions.first { $0.name == name })
        let descriptors = try await api.channels(
            productionID: production.id,
            accessToken: accessToken
        )
        return IntercomConfiguration(
            displayName: "Integrációs teszt",
            productionName: production.name,
            productionID: production.id,
            serverURL: nil,
            channels: descriptors.map(IntercomChannel.init(descriptor:))
        )
    }

    private func patchChannel(
        production: UUID,
        channel: UUID,
        body: [String: String]
    ) async throws {
        let accessToken = try await auth.validAccessToken()
        var request = URLRequest(
            url: Self.baseURL.appendingPathComponent(
                "v1/productions/\(production.uuidString.lowercased())/channels/\(channel.uuidString.lowercased())"
            )
        )
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await URLSession.intercom.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        XCTAssertEqual(status, 200, "A csatorna módosítása nem sikerült.")
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

/// Counts realtime-token mints without changing behaviour.
private actor CountingAPI: IntercomAPI {
    private let wrapped: any IntercomAPI
    private var realtimeTokenCalls = 0

    init(wrapping wrapped: any IntercomAPI) { self.wrapped = wrapped }

    func realtimeTokenCallCount() -> Int { realtimeTokenCalls }

    func login(email: String, password: String, deviceName: String) async throws -> AuthSessionResponse {
        try await wrapped.login(email: email, password: password, deviceName: deviceName)
    }

    func refresh(refreshToken: String) async throws -> AuthSessionResponse {
        try await wrapped.refresh(refreshToken: refreshToken)
    }

    func logout(accessToken: String) async throws {
        try await wrapped.logout(accessToken: accessToken)
    }

    func productions(accessToken: String) async throws -> [ProductionSummary] {
        try await wrapped.productions(accessToken: accessToken)
    }

    func channels(productionID: UUID, accessToken: String) async throws -> [ChannelDescriptor] {
        try await wrapped.channels(productionID: productionID, accessToken: accessToken)
    }

    func crew(productionID: UUID, accessToken: String) async throws -> [CrewMemberDescriptor] {
        try await wrapped.crew(productionID: productionID, accessToken: accessToken)
    }

    func invitePreview(code: String, accessToken: String) async throws -> InvitePreview {
        try await wrapped.invitePreview(code: code, accessToken: accessToken)
    }

    func redeemInvite(code: String, accessToken: String) async throws -> ProductionSummary {
        try await wrapped.redeemInvite(code: code, accessToken: accessToken)
    }

    func startPrivateCall(
        productionID: UUID,
        peerID: UUID,
        accessToken: String
    ) async throws -> ChannelDescriptor {
        try await wrapped.startPrivateCall(
            productionID: productionID,
            peerID: peerID,
            accessToken: accessToken
        )
    }

    func endPrivateCall(productionID: UUID, channelID: UUID, accessToken: String) async throws {
        try await wrapped.endPrivateCall(
            productionID: productionID,
            channelID: channelID,
            accessToken: accessToken
        )
    }

    func realtimeTokens(
        productionID: UUID,
        channelIDs: [UUID],
        accessToken: String
    ) async throws -> RealtimeTokensResponse {
        realtimeTokenCalls += 1
        return try await wrapped.realtimeTokens(
            productionID: productionID,
            channelIDs: channelIDs,
            accessToken: accessToken
        )
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

    func waitForConfigurationStale(timeout: TimeInterval) async -> Bool {
        await waitFor(timeout: timeout) { events in
            events.contains { event in
                if case .configurationStale = event { return true }
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
                if case let .participantsChanged(id, participants) = event {
                    return id == channelID && participants.count >= minimum
                }
                return false
            }
        }
    }

    func describe() -> [String] {
        events.map { event in
            switch event {
            case let .connectionStateChanged(state): "state(\(state))"
            case let .participantsChanged(_, participants): "participants(\(participants.count))"
            case let .remoteSpeakingChanged(_, speaking): "speaking(\(speaking))"
            case .talkStopped: "talkStopped"
            case .statistics: "stats"
            case let .configurationStale(version): "configStale(\(version))"
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
