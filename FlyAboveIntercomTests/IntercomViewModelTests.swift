import XCTest
@testable import FlyAboveIntercom

@MainActor
final class IntercomViewModelTests: XCTestCase {
    func testConnectTransitionsToConnected() async {
        let transport = TransportSpy()
        let audio = AudioSessionSpy(permissionGranted: true)
        let subject = IntercomViewModel(transport: transport, audioSession: audio)

        await subject.connect()

        XCTAssertEqual(subject.connectionState, .connected)
        let didConnect = await transport.connectedValue()
        let didActivate = await audio.activatedValue()
        XCTAssertTrue(didConnect)
        XCTAssertTrue(didActivate)
    }

    func testDeniedPermissionDoesNotConnect() async {
        let transport = TransportSpy()
        let audio = AudioSessionSpy(permissionGranted: false)
        let subject = IntercomViewModel(transport: transport, audioSession: audio)

        await subject.connect()

        XCTAssertFalse(subject.isConnected)
        XCTAssertNotNil(subject.errorMessage)
        let didConnect = await transport.connectedValue()
        XCTAssertFalse(didConnect)
    }

    func testDisconnectStopsAllTalkChannels() async {
        let transport = TransportSpy()
        let audio = AudioSessionSpy(permissionGranted: true)
        let subject = IntercomViewModel(transport: transport, audioSession: audio)
        await subject.connect()
        let firstID = try! XCTUnwrap(subject.configuration.channels.first?.id)
        await subject.setTalking(true, channelID: firstID)

        await subject.disconnect()

        XCTAssertEqual(subject.connectionState, .disconnected)
        XCTAssertTrue(subject.configuration.channels.allSatisfy { !$0.isTalking })
    }
}

private actor TransportSpy: IntercomTransport {
    private(set) var didConnect = false

    func connect(configuration: IntercomConfiguration) async throws { didConnect = true }
    func disconnect() async {}
    func setListening(_ enabled: Bool, channelID: UUID) async throws {}
    func setTalking(_ enabled: Bool, channelID: UUID) async throws {}
    func connectedValue() -> Bool { didConnect }
}

private actor AudioSessionSpy: AudioSessionControlling {
    let permissionGranted: Bool
    private(set) var didActivate = false

    init(permissionGranted: Bool) { self.permissionGranted = permissionGranted }
    func requestMicrophonePermission() async -> Bool { permissionGranted }
    func activate() async throws { didActivate = true }
    func deactivate() async {}
    func activatedValue() -> Bool { didActivate }
}
