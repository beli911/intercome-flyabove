import XCTest
@testable import FlyAboveIntercom

/// The rule that decides what the operator sees in the header.
final class ConnectionAggregationTests: XCTestCase {
    func testNoRoomsIsDisconnected() {
        XCTAssertEqual(ConnectionAggregation.state(from: []), .disconnected)
    }

    func testAllConnectedIsConnected() {
        XCTAssertEqual(
            ConnectionAggregation.state(from: [.connected, .connected]),
            .connected
        )
    }

    func testAllDisconnectedIsDisconnected() {
        XCTAssertEqual(
            ConnectionAggregation.state(from: [.disconnected, .disconnected]),
            .disconnected
        )
    }

    func testOneDeadRoomIsNotHiddenByAHealthyOne() {
        // The case that matters: a dropped line behind a working one used to
        // read as fully connected, and that is how a cue gets missed.
        XCTAssertEqual(
            ConnectionAggregation.state(from: [.connected, .disconnected]),
            .reconnecting
        )
    }

    func testOneReconnectingRoomDegradesTheWhole() {
        XCTAssertEqual(
            ConnectionAggregation.state(from: [.connected, .reconnecting]),
            .reconnecting
        )
    }

    func testJoiningRoomDegradesTheWhole() {
        XCTAssertEqual(
            ConnectionAggregation.state(from: [.connected, .connecting]),
            .reconnecting
        )
    }
}
