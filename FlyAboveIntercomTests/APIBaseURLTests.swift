import XCTest
@testable import FlyAboveIntercom

final class APIBaseURLTests: XCTestCase {
    func testTrailingSlashIsAdded() throws {
        // Without it, `URL(string:relativeTo:)` drops the last path component
        // and "https://host/api" + "v1/auth/login" silently loses "/api".
        let url = try APIBaseURL.normalised("https://api.flyabove.hu/api")
        XCTAssertEqual(url.absoluteString, "https://api.flyabove.hu/api/")

        let path = URL(string: "v1/auth/login", relativeTo: url)?.absoluteURL
        XCTAssertEqual(path?.absoluteString, "https://api.flyabove.hu/api/v1/auth/login")
    }

    func testExistingTrailingSlashIsKept() throws {
        let url = try APIBaseURL.normalised("https://api.flyabove.hu/")
        XCTAssertEqual(url.absoluteString, "https://api.flyabove.hu/")
    }

    func testWhitespaceIsTrimmed() throws {
        let url = try APIBaseURL.normalised("  https://api.flyabove.hu  ")
        XCTAssertEqual(url.absoluteString, "https://api.flyabove.hu/")
    }

    func testSchemeIsLowercased() throws {
        let url = try APIBaseURL.normalised("HTTPS://API.flyabove.hu")
        XCTAssertEqual(url.scheme, "https")
    }

    func testQueryAndFragmentAreDropped() throws {
        // A base URL carrying a query would corrupt every path built from it.
        let url = try APIBaseURL.normalised("https://api.flyabove.hu/base?debug=1#top")
        XCTAssertEqual(url.absoluteString, "https://api.flyabove.hu/base/")
    }

    func testPlainHTTPIsAllowedForDevelopment() throws {
        let url = try APIBaseURL.normalised("http://192.168.1.10:8080", allowInsecure: true)
        XCTAssertEqual(url.absoluteString, "http://192.168.1.10:8080/")
    }

    func testPlainHTTPIsRefusedWhenInsecureIsNotAllowed() {
        // A release build must never carry production traffic over plain HTTP.
        XCTAssertThrowsError(
            try APIBaseURL.normalised("http://api.flyabove.hu", allowInsecure: false)
        ) { error in
            XCTAssertEqual(error as? APIBaseURLError, .insecureInRelease(host: "api.flyabove.hu"))
        }
    }

    func testNonHTTPSchemeIsRefused() {
        XCTAssertThrowsError(try APIBaseURL.normalised("wss://api.flyabove.hu")) { error in
            XCTAssertEqual(error as? APIBaseURLError, .notHTTP(scheme: "wss"))
        }
    }

    func testGarbageIsRefused() {
        XCTAssertThrowsError(try APIBaseURL.normalised("nem egy url"))
        XCTAssertThrowsError(try APIBaseURL.normalised(""))
        XCTAssertThrowsError(try APIBaseURL.normalised("https://"))
    }
}
