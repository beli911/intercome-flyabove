import XCTest
@testable import FlyAboveIntercom

/// Regression guard for a bug that cost real debugging time: the actor
/// implemented `events()` synchronously, so it never witnessed the protocol's
/// `async` requirement. Callers silently got the extension's empty stream
/// instead, and the view model received no transport events at all.
///
/// The extension default is gone now, which turns the same mistake into a
/// compile error — this test covers the runtime half of the contract.
final class TransportEventTests: XCTestCase {
    func testLiveKitTransportDeliversItsOwnEvents() async throws {
        // No server needed: `disconnect()` emits unconditionally.
        let api = HTTPIntercomAPI(baseURL: URL(string: "http://127.0.0.1:1/")!)
        let auth = AuthService(api: api, store: InMemoryTokenStore(), deviceName: "Teszt")
        let transport = LiveKitIntercomTransport(api: api, auth: auth)

        let stream = await transport.events()
        let received = Task { () -> IntercomTransportEvent? in
            for await event in stream { return event }
            return nil
        }

        await transport.disconnect()

        let event = await received.value
        guard case .connectionStateChanged(.disconnected)? = event else {
            return XCTFail("Nem érkezett esemény: \(String(describing: event))")
        }
    }

    func testPreviewTransportDeliversItsOwnEvents() async throws {
        let transport = PreviewIntercomTransport()
        let stream = await transport.events()
        let received = Task { () -> IntercomTransportEvent? in
            for await event in stream { return event }
            return nil
        }

        await transport.disconnect()

        let event = await received.value
        guard case .connectionStateChanged(.disconnected)? = event else {
            return XCTFail("Nem érkezett esemény: \(String(describing: event))")
        }
    }
}

/// Grants arrive from the network, so the code that indexes them has to treat a
/// malformed response as an error rather than as an impossibility.
final class GrantIndexingTests: XCTestCase {
    private func grant(channel: UUID, canPublish: Bool = true) -> RealtimeGrant {
        RealtimeGrant(
            channelId: channel,
            roomName: "p_x.c_\(channel.uuidString.lowercased())",
            token: "token",
            expiresAt: Date().addingTimeInterval(3600),
            canPublish: canPublish,
            canSubscribe: true
        )
    }

    func testDistinctChannelsAreIndexed() throws {
        let first = UUID()
        let second = UUID()
        let indexed = try LiveKitIntercomTransport.grantsByChannel([
            grant(channel: first), grant(channel: second)
        ])
        XCTAssertEqual(indexed.count, 2)
        XCTAssertEqual(indexed[first]?.channelId, first)
    }

    func testARepeatedChannelIsAReadableErrorNotATrap() {
        let channel = UUID()
        // Two grants for one channel differ in what they permit, so silently
        // keeping the last one would make publish rights depend on response
        // order.
        XCTAssertThrowsError(
            try LiveKitIntercomTransport.grantsByChannel([
                grant(channel: channel, canPublish: false),
                grant(channel: channel, canPublish: true)
            ])
        ) { error in
            guard case IntercomTransportError.invalidServerResponse = error else {
                return XCTFail("Nem a várt hiba: \(error)")
            }
        }
    }
}
