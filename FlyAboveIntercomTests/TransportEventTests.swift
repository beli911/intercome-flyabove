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
