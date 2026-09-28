import XCTest
@testable import FlyAboveIntercom

final class HostAddressTests: XCTestCase {
    func testPrivateRangesAreRecognised() {
        // These are exactly the addresses a phone can only reach once the user
        // has granted local network access.
        for host in ["192.168.55.199", "10.0.0.4", "172.16.0.1", "172.31.255.254",
                     "127.0.0.1", "169.254.1.1", "localhost", "macbook.local"] {
            XCTAssertTrue(HostAddress.isPrivate(host), host)
        }
    }

    func testPublicHostsAreNot() {
        for host in ["api.flyabove.hu", "8.8.8.8", "172.32.0.1", "172.15.0.1", "11.0.0.1"] {
            XCTAssertFalse(HostAddress.isPrivate(host), host)
        }
    }

    func testMalformedInputIsNotTreatedAsPrivate() {
        for host in ["", "192.168.1", "999.999.999.999", "192.168.1.1.1", "nem-egy-cim"] {
            XCTAssertFalse(HostAddress.isPrivate(host), host)
        }
    }

    func testUnreachableErrorsAreRecognised() {
        for code in [URLError.cannotConnectToHost, .timedOut, .networkConnectionLost,
                     .notConnectedToInternet, .cannotFindHost] {
            XCTAssertTrue(HostAddress.isUnreachable(URLError(code)), "\(code)")
        }
    }

    func testAServerThatAnsweredBadlyIsNotUnreachable() {
        // A refused or cancelled request is not the same as nothing answering,
        // and must not be reported as a Wi-Fi problem.
        XCTAssertFalse(HostAddress.isUnreachable(URLError(.cancelled)))
        XCTAssertFalse(HostAddress.isUnreachable(URLError(.badServerResponse)))
        XCTAssertFalse(HostAddress.isUnreachable(APIError.unauthorized(code: nil, message: nil)))
    }
}
