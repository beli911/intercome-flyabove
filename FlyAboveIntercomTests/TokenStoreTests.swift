import XCTest
@testable import FlyAboveIntercom

final class AuthTokensTests: XCTestCase {
    private func tokens(expiringIn seconds: TimeInterval) -> AuthTokens {
        AuthTokens(
            accessToken: "access",
            refreshToken: "refresh",
            accessTokenExpiresAt: Date(timeIntervalSince1970: 1_000).addingTimeInterval(seconds)
        )
    }

    private let now = Date(timeIntervalSince1970: 1_000)

    func testTokenWithPlentyOfTimeIsNotExpired() {
        XCTAssertFalse(tokens(expiringIn: 600).isExpired(now: now))
    }

    func testTokenInsideLeewayCountsAsExpired() {
        // 30s left, 60s leeway: refresh now rather than fail a request in flight.
        XCTAssertTrue(tokens(expiringIn: 30).isExpired(now: now))
    }

    func testPastTokenIsExpired() {
        XCTAssertTrue(tokens(expiringIn: -1).isExpired(now: now))
    }
}

final class InMemoryTokenStoreTests: XCTestCase {
    func testRoundTrip() throws {
        let store = InMemoryTokenStore()
        XCTAssertNil(try store.load())

        let saved = AuthTokens(accessToken: "a", refreshToken: "r", accessTokenExpiresAt: .now)
        try store.save(saved)
        XCTAssertEqual(try store.load(), saved)

        try store.clear()
        XCTAssertNil(try store.load())
    }
}

final class KeychainTokenStoreTests: XCTestCase {
    /// A dedicated service name so the test never touches the app's real item.
    private let store = KeychainTokenStore(
        service: "hu.flyabove.intercom.tests.\(UUID().uuidString)",
        account: "primary"
    )

    override func tearDown() {
        try? store.clear()
        super.tearDown()
    }

    func testSaveLoadUpdateAndClear() throws {
        XCTAssertNil(try store.load())

        let first = AuthTokens(
            accessToken: "access-1",
            refreshToken: "refresh-1",
            accessTokenExpiresAt: Date(timeIntervalSince1970: 2_000)
        )
        try store.save(first)
        XCTAssertEqual(try store.load(), first)

        // Second save must update the existing item, not fail as a duplicate.
        let second = AuthTokens(
            accessToken: "access-2",
            refreshToken: "refresh-2",
            accessTokenExpiresAt: Date(timeIntervalSince1970: 3_000)
        )
        try store.save(second)
        XCTAssertEqual(try store.load(), second)

        try store.clear()
        XCTAssertNil(try store.load())
    }

    func testClearOnEmptyStoreDoesNotThrow() {
        XCTAssertNoThrow(try store.clear())
    }
}
