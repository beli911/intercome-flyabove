import XCTest
@testable import FlyAboveIntercom

/// The one line an operator can still talk on with the phone in a pocket. Being
/// wrong here is invisible until the moment it matters, and the dangerous
/// failure is not silence — it is talking on a line the operator did not pick.
final class BackgroundTalkLineTests: XCTestCase {
    private func candidate(
        _ name: String,
        role: ChannelRole = .line,
        canTalk: Bool = true,
        isListening: Bool = false,
        isPrivate: Bool = false,
        id: UUID = UUID()
    ) -> BackgroundTalkLine.Candidate {
        BackgroundTalkLine.Candidate(
            id: id,
            name: name,
            role: role,
            canTalk: canTalk,
            isListening: isListening,
            isPrivate: isPrivate
        )
    }

    // MARK: - Eligibility

    func testALineWeCannotTalkOnIsNeverNominated() {
        let mute = candidate("Program", role: .program, canTalk: false)
        let talkable = candidate("Rendező", role: .priority)

        let selection = BackgroundTalkLine.select(from: [mute, talkable], operatorChoice: nil)

        XCTAssertEqual(selection.channelID, talkable.id, "néma vonalra nem szabad rendszer-gombot kínálni")
    }

    func testAPrivateEphemeralCallIsNeverNominated() {
        let privateCall = candidate("Oszkár", isPrivate: true)

        let selection = BackgroundTalkLine.select(from: [privateCall], operatorChoice: nil)

        XCTAssertNil(selection.channelID)
        XCTAssertEqual(selection.basis, .noTalkableLine)
    }

    func testAPrivateCallIsRefusedEvenWhenTheOperatorPicksIt() {
        let privateCall = candidate("Oszkár", isPrivate: true)
        let line = candidate("Vonal 1")

        let selection = BackgroundTalkLine.select(from: [privateCall, line], operatorChoice: privateCall.id)

        XCTAssertEqual(selection.channelID, line.id)
        XCTAssertEqual(selection.lostOperatorChoice, .becamePrivate(name: "Oszkár"))
    }

    // MARK: - Preference order

    func testTheOperatorsOwnPickWins() {
        let director = candidate("Rendező", role: .priority)
        let line = candidate("Vonal 2", isListening: true)

        let selection = BackgroundTalkLine.select(from: [director, line], operatorChoice: line.id)

        XCTAssertEqual(selection.channelID, line.id)
        XCTAssertEqual(selection.basis, .operatorChoice)
        XCTAssertNil(selection.lostOperatorChoice)
    }

    func testTheDirectorsLineIsTheDefault() {
        let line = candidate("Vonal 1", isListening: true)
        let director = candidate("Rendező", role: .priority)

        let selection = BackgroundTalkLine.select(from: [line, director], operatorChoice: nil)

        XCTAssertEqual(selection.channelID, director.id, "a rendező vonala előzi a hallgatottat")
        XCTAssertEqual(selection.basis, .directorsLine)
    }

    func testAListenedLineBeatsOneWeOnlyHavePermissionFor() {
        let unlistened = candidate("Vonal 1")
        let listened = candidate("Vonal 2", isListening: true)

        let selection = BackgroundTalkLine.select(from: [unlistened, listened], operatorChoice: nil)

        XCTAssertEqual(selection.channelID, listened.id)
        XCTAssertEqual(selection.basis, .listenedLine)
    }

    func testWithNothingElseTheFirstTalkableLineIsUsed() {
        let first = candidate("Vonal 1")
        let second = candidate("Vonal 2")

        let selection = BackgroundTalkLine.select(from: [first, second], operatorChoice: nil)

        XCTAssertEqual(selection.channelID, first.id)
        XCTAssertEqual(selection.basis, .firstTalkableLine)
    }

    func testASingleTalkableLineIsReportedAsSuch() {
        let only = candidate("Rendező", role: .priority, isListening: true)
        let mute = candidate("Program", role: .program, canTalk: false)

        let selection = BackgroundTalkLine.select(from: [only, mute], operatorChoice: nil)

        XCTAssertEqual(selection.channelID, only.id)
        XCTAssertEqual(selection.basis, .onlyTalkableLine, "egy vonalnál ezt kell mondani, nem azt, hogy ő a rendezőé")
    }

    // MARK: - A pick that fell away

    func testARemovedPickIsReportedAndFallsBack() {
        let director = candidate("Rendező", role: .priority)
        let gone = UUID()

        let selection = BackgroundTalkLine.select(from: [director], operatorChoice: gone)

        XCTAssertEqual(selection.channelID, director.id)
        XCTAssertEqual(selection.lostOperatorChoice, .removed, "a némán elmozduló háttérvonal a veszélyes eset")
    }

    func testARevokedPickIsReportedByName() {
        let revoked = candidate("Vonal 3", canTalk: false)
        let director = candidate("Rendező", role: .priority)

        let selection = BackgroundTalkLine.select(from: [revoked, director], operatorChoice: revoked.id)

        XCTAssertEqual(selection.channelID, director.id)
        XCTAssertEqual(selection.lostOperatorChoice, .noLongerTalkable(name: "Vonal 3"))
    }

    func testALostPickIsStillReportedWhenNothingCanReplaceIt() {
        let revoked = candidate("Vonal 3", canTalk: false)

        let selection = BackgroundTalkLine.select(from: [revoked], operatorChoice: revoked.id)

        XCTAssertNil(selection.channelID)
        XCTAssertEqual(selection.basis, .noTalkableLine)
        XCTAssertEqual(
            selection.lostOperatorChoice,
            .noLongerTalkable(name: "Vonal 3"),
            "a 'nincs háttérvonal' önmagában nem mondja meg, hogy az OVÉ veszett el"
        )
    }

    func testAnEmptyConfigurationIsDistinctFromOneWithNoTalkableLine() {
        XCTAssertEqual(
            BackgroundTalkLine.select(from: [], operatorChoice: nil).basis,
            .noChannels
        )
        XCTAssertEqual(
            BackgroundTalkLine.select(from: [candidate("Program", canTalk: false)], operatorChoice: nil).basis,
            .noTalkableLine
        )
    }

    /// The invariant that keeps the two halves of `Selection` from drifting: a
    /// basis that means "none" must not carry a channel, and one that names a
    /// line must.
    func testChannelPresenceMatchesTheBasis() {
        let cases: [[BackgroundTalkLine.Candidate]] = [
            [],
            [candidate("Program", canTalk: false)],
            [candidate("Privát", isPrivate: true)],
            [candidate("Vonal 1")],
            [candidate("Vonal 1"), candidate("Rendező", role: .priority)],
            [candidate("Vonal 1", isListening: true), candidate("Vonal 2")],
        ]

        for candidates in cases {
            for choice in [nil, candidates.first?.id, UUID()] {
                let selection = BackgroundTalkLine.select(from: candidates, operatorChoice: choice)
                let isNone = selection.basis == .noChannels || selection.basis == .noTalkableLine
                XCTAssertEqual(
                    selection.channelID == nil,
                    isNone,
                    "alap=\(selection.basis) csatorna=\(String(describing: selection.channelID))"
                )
            }
        }
    }

    // MARK: - Leaving the foreground

    func testEverythingClosesWhenTheSystemIsNotHoldingTheMicrophone() {
        let background = UUID()
        let other = UUID()

        let silenced = BackgroundTalkLine.channelsToSilenceOnLeavingForeground(
            talking: [background, other],
            backgroundLine: background,
            isSystemTransmitting: false
        )

        XCTAssertEqual(
            Set(silenced),
            Set([background, other]),
            "app által nyitott mikrofont a háttérvonalon is le kell zárni: nincs látható megállító"
        )
    }

    func testTheSystemHeldBackgroundLineStaysOpen() {
        let background = UUID()
        let other = UUID()

        let silenced = BackgroundTalkLine.channelsToSilenceOnLeavingForeground(
            talking: [background, other],
            backgroundLine: background,
            isSystemTransmitting: true
        )

        XCTAssertEqual(silenced, [other], "épp ezért létezik a háttér-PTT")
    }

    func testWithoutABackgroundLineTheExemptionCannotApply() {
        let other = UUID()

        let silenced = BackgroundTalkLine.channelsToSilenceOnLeavingForeground(
            talking: [other],
            backgroundLine: nil,
            isSystemTransmitting: true
        )

        XCTAssertEqual(silenced, [other])
    }
}
