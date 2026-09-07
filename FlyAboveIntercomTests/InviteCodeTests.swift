import XCTest
@testable import FlyAboveIntercom

final class InviteCodeTests: XCTestCase {
    func testLowercaseIsAccepted() {
        // Someone typing what they were told, in the case their keyboard gave
        // them, meant the right thing.
        XCTAssertEqual(InviteCode.normalised("dm2ph4"), "DM2PH4")
    }

    func testSeparatorsAndSpacesAreStripped() {
        XCTAssertEqual(InviteCode.normalised("DM2 PH4"), "DM2PH4")
        XCTAssertEqual(InviteCode.normalised("DM2-PH4"), "DM2PH4")
    }

    func testAmbiguousCharactersAreNotInTheAlphabet() {
        // The alphabet leaves out O, I, L, 0 and 1 on purpose; a code read
        // aloud over a talkback must not be ambiguous.
        for character in "OIL01" {
            XCTAssertFalse(InviteCode.alphabet.contains(character), "\(character) nem lehet a kódban")
        }
    }

    func testOverlongInputIsTruncated() {
        XCTAssertEqual(InviteCode.normalised("DM2PH4XYZ"), "DM2PH4")
    }

    func testCompleteness() {
        XCTAssertFalse(InviteCode.isComplete("DM2PH"))
        XCTAssertTrue(InviteCode.isComplete("DM2PH4"))
        XCTAssertFalse(InviteCode.isComplete(""))
    }

    func testCustomSchemeLink() {
        XCTAssertEqual(
            InviteCode.from(url: URL(string: "flyabove-intercom://invite/DM2PH4")!),
            "DM2PH4"
        )
    }

    func testCustomSchemeLinkWithoutDoubleSlash() {
        XCTAssertEqual(
            InviteCode.from(url: URL(string: "flyabove-intercom:invite/DM2PH4")!),
            "DM2PH4"
        )
    }

    func testHTTPSLink() {
        XCTAssertEqual(
            InviteCode.from(url: URL(string: "https://intercom.flyabove.hu/invite/DM2PH4")!),
            "DM2PH4"
        )
    }

    func testLinkWithoutACodeIsRejected() {
        XCTAssertNil(InviteCode.from(url: URL(string: "flyabove-intercom://invite")!))
        XCTAssertNil(InviteCode.from(url: URL(string: "https://intercom.flyabove.hu/")!))
        // Too short after filtering: not a code, and must not be sent as one.
        XCTAssertNil(InviteCode.from(url: URL(string: "flyabove-intercom://invite/OI1")!))
    }
}
