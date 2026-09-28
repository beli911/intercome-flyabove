import XCTest
@testable import FlyAboveIntercom

/// The crew list is a merge of two sources that disagree by design: the roster
/// knows who belongs to the production, the transport knows who turned up.
@MainActor
final class CrewTests: XCTestCase {
    private let operatorID = UUID(uuidString: "8B2B8A5C-1B7C-4E1E-9C1F-1E6C2E5C4A11")!
    private let cameraID = UUID(uuidString: "9C3C9B6D-2C8D-4F2F-8D20-2F7D3F6D5B22")!
    private let absentID = UUID(uuidString: "1A1A1A1A-1A1A-4A1A-8A1A-1A1A1A1A1A1A")!

    private func roster() -> [CrewMember] {
        [
            member(operatorID, "Teszt Operátor", "operator"),
            member(cameraID, "Teszt Kamera", "kameraman"),
            member(absentID, "Ábel Nincs", "hang")
        ]
    }

    private func member(_ id: UUID, _ name: String, _ role: String) -> CrewMember {
        CrewMember(
            id: id,
            displayName: name,
            role: role,
            isOnline: false,
            isSpeaking: false,
            quality: .unknown,
            activeChannelIDs: []
        )
    }

    private func makeViewModel(
        participantsByChannel: [Int: [ChannelParticipant]]
    ) -> IntercomViewModel {
        var configuration = IntercomConfiguration.demo
        for (index, participants) in participantsByChannel {
            configuration.channels[index].participants = participants
        }
        return IntercomViewModel(
            configuration: configuration,
            transport: PreviewIntercomTransport(),
            audioSession: AudioSessionController()
        )
    }

    private func participant(_ id: UUID, speaking: Bool, quality: LinkQuality) -> ChannelParticipant {
        ChannelParticipant(
            id: id.uuidString.lowercased(),
            displayName: "—",
            isSpeaking: speaking,
            quality: quality
        )
    }

    func testPresenceIsTakenFromTheTransportNotTheRoster() {
        let viewModel = makeViewModel(participantsByChannel: [
            0: [participant(operatorID, speaking: false, quality: .good)]
        ])

        let crew = viewModel.crew(roster: roster())

        let online = crew.first { $0.id == operatorID }
        XCTAssertEqual(online?.isOnline, true)
        // The roster lists them; nothing heard them. That is offline.
        XCTAssertEqual(crew.first { $0.id == absentID }?.isOnline, false)
    }

    func testAMemberOnSeveralChannelsListsAllOfThem() {
        let viewModel = makeViewModel(participantsByChannel: [
            0: [participant(cameraID, speaking: false, quality: .good)],
            1: [participant(cameraID, speaking: false, quality: .good)]
        ])

        let crew = viewModel.crew(roster: roster())

        let member = crew.first { $0.id == cameraID }
        XCTAssertEqual(member?.activeChannelIDs.count, 2)
    }

    func testSpeakingOnAnyChannelCountsAsSpeaking() {
        let viewModel = makeViewModel(participantsByChannel: [
            0: [participant(cameraID, speaking: false, quality: .good)],
            1: [participant(cameraID, speaking: true, quality: .good)]
        ])

        let crew = viewModel.crew(roster: roster())

        XCTAssertEqual(crew.first { $0.id == cameraID }?.isSpeaking, true)
    }

    func testBestQualityWins() {
        // One weak line does not make the person unreachable; the operator
        // needs to know they can be heard at all.
        let viewModel = makeViewModel(participantsByChannel: [
            0: [participant(cameraID, speaking: false, quality: .poor)],
            1: [participant(cameraID, speaking: false, quality: .excellent)]
        ])

        let crew = viewModel.crew(roster: roster())

        XCTAssertEqual(crew.first { $0.id == cameraID }?.quality, .excellent)
    }

    func testWhoeverIsTalkingComesFirst() {
        let viewModel = makeViewModel(participantsByChannel: [
            0: [
                participant(operatorID, speaking: false, quality: .good),
                participant(cameraID, speaking: true, quality: .good)
            ]
        ])

        let crew = viewModel.crew(roster: roster())

        XCTAssertEqual(crew.first?.id, cameraID)
        // Then the ones who are present, and offline members last.
        XCTAssertEqual(crew.last?.id, absentID)
    }

    func testSomeoneOnTheLineWhoIsNotOnTheRosterIsNotInvented() {
        let stranger = UUID()
        let viewModel = makeViewModel(participantsByChannel: [
            0: [participant(stranger, speaking: true, quality: .good)]
        ])

        let crew = viewModel.crew(roster: roster())

        // The roster is the source of identity. An unknown participant is a
        // server-side inconsistency, not a person to display with no name.
        XCTAssertEqual(crew.count, 3)
        XCTAssertFalse(crew.contains { $0.id == stranger })
    }
}
