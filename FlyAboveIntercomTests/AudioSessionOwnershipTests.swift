import XCTest
@testable import FlyAboveIntercom

/// A hang-munkamenet tulajdonjoga. A tét: ha rosszul dől el, a mikrofon lezárt
/// képernyőn CSENDBEN nem nyílik ki — hibaüzenet nélkül.
final class AudioSessionOwnershipTests: XCTestCase {
    func testWithoutABackgroundLineBothModesBehaveIdentically() {
        for mode in AudioSessionOwnership.Mode.allCases {
            XCTAssertTrue(
                AudioSessionOwnership.mayAppActivate(mode: mode, isBackgroundLineHeld: false),
                "\(mode): háttérvonal nélkül az app kezeli a munkamenetet"
            )
            XCTAssertTrue(
                AudioSessionOwnership.mayAppDeactivate(mode: mode, isBackgroundLineHeld: false),
                "\(mode)"
            )
        }
    }

    func testTheAppKeepsTheSessionInTheDefaultModeEvenWithALineHeld() {
        // Ez a ma mért viselkedés, és ez az alapértelmezés: a Push to Talk
        // bekapcsolása önmagában nem változtathat a működő úton.
        XCTAssertTrue(AudioSessionOwnership.mayAppActivate(mode: .appOwns, isBackgroundLineHeld: true))
        XCTAssertTrue(AudioSessionOwnership.mayAppDeactivate(mode: .appOwns, isBackgroundLineHeld: true))
    }

    func testInHandoverModeTheAppDoesNotTouchAHeldSession() {
        XCTAssertFalse(
            AudioSessionOwnership.mayAppActivate(mode: .systemOwnsDuringPushToTalk, isBackgroundLineHeld: true),
            "egy már aktív munkamenetet a rendszer nem tud újra aktiválni, és a didActivate elmarad"
        )
        XCTAssertFalse(
            AudioSessionOwnership.mayAppDeactivate(mode: .systemOwnsDuringPushToTalk, isBackgroundLineHeld: true),
            "a lezárás pont az adást vágná el"
        )
    }

    func testOnlyTheHandoverModeReleasesLiveKit() {
        XCTAssertFalse(AudioSessionOwnership.shouldDisableLiveKitAutomaticConfiguration(mode: .appOwns))
        XCTAssertTrue(AudioSessionOwnership.shouldDisableLiveKitAutomaticConfiguration(mode: .systemOwnsDuringPushToTalk))
    }

    /// A LiveKit doksija szerint ezt egyszer, indulás közben kell beállítani —
    /// tehát a döntés a MÓDBÓL jön, és nem attól függ, tart-e épp valaki egy
    /// vonalat. Ha ez elcsúszna, a beállítás menet közben változna.
    func testTheLiveKitDecisionDoesNotDependOnWhetherALineIsHeld() {
        for mode in AudioSessionOwnership.Mode.allCases {
            let decision = AudioSessionOwnership.shouldDisableLiveKitAutomaticConfiguration(mode: mode)
            XCTAssertEqual(decision, AudioSessionOwnership.shouldDisableLiveKitAutomaticConfiguration(mode: mode))
            XCTAssertEqual(mode == .systemOwnsDuringPushToTalk, decision)
        }
    }
}
