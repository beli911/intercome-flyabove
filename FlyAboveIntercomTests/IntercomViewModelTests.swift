import XCTest
@testable import FlyAboveIntercom

@MainActor
final class IntercomViewModelTests: XCTestCase {
    // MARK: - Connection

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
        let (subject, _, _) = await makeConnectedSubject()
        let firstID = try! XCTUnwrap(subject.configuration.channels.first?.id)
        await subject.setTalking(true, channelID: firstID)

        await subject.disconnect()

        XCTAssertEqual(subject.connectionState, .disconnected)
        XCTAssertTrue(subject.configuration.channels.allSatisfy { !$0.isTalking })
    }

    // MARK: - Transport events

    func testTalkStoppedEventReleasesTalkState() async {
        let (subject, transport, _) = await makeConnectedSubject()
        let channelID = try! XCTUnwrap(subject.configuration.channels.first?.id)
        await subject.setTalking(true, channelID: channelID)
        XCTAssertEqual(subject.activeTalkChannelCount, 1)

        // The server revoked publish, or the reconnect dropped the track.
        await transport.emit(.talkStopped(channelID: channelID))

        await waitUntil { subject.activeTalkChannelCount == 0 }
    }

    func testReconnectingEventIsReflected() async {
        let (subject, transport, _) = await makeConnectedSubject()

        await transport.emit(.connectionStateChanged(.reconnecting))

        await waitUntil { subject.connectionState == .reconnecting }
    }

    func testStatisticsEventIsPublished() async {
        let (subject, transport, _) = await makeConnectedSubject()

        await transport.emit(.statistics(IntercomStatistics(
            roundTripTimeMilliseconds: 42.4,
            availableOutgoingBitrateKbps: 300,
            availableIncomingBitrateKbps: 250,
            updatedAt: Date(timeIntervalSince1970: 1)
        )))

        await waitUntil { subject.statistics?.roundTripDescription == "RTT 42 ms" }
    }

    func testParticipantAndSpeakingEventsUpdateChannel() async {
        let (subject, transport, _) = await makeConnectedSubject()
        let channelID = try! XCTUnwrap(subject.configuration.channels.first?.id)

        await transport.emit(.participantCountChanged(channelID: channelID, count: 7))
        await transport.emit(.remoteSpeakingChanged(channelID: channelID, isSpeaking: true))

        await waitUntil {
            subject.configuration.channels[0].participantCount == 7
                && subject.configuration.channels[0].isRemoteSpeaking
        }
    }

    func testLateConnectedEventDoesNotResurrectADisconnectedSession() async {
        let (subject, transport, _) = await makeConnectedSubject()
        await subject.disconnect()
        XCTAssertEqual(subject.connectionState, .disconnected)

        // A LiveKit delegate callback that was already in flight when the user
        // hit disconnect. It must not light the UI back up.
        await transport.emit(.connectionStateChanged(.connected))

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(subject.connectionState, .disconnected)
    }

    func testLateParticipantEventIsIgnoredAfterDisconnect() async {
        let (subject, transport, _) = await makeConnectedSubject()
        let channelID = try! XCTUnwrap(subject.configuration.channels.first?.id)
        await subject.disconnect()

        await transport.emit(.participantCountChanged(channelID: channelID, count: 99))

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNotEqual(subject.configuration.channels[0].participantCount, 99)
    }

    func testRapidTalkTogglesEndWithTheMicrophoneOff() async {
        let (subject, transport, _) = await makeConnectedSubject()
        let channelID = try! XCTUnwrap(subject.configuration.channels.first?.id)
        // The transport is slow enough that unserialised tasks would finish out
        // of order, which is exactly what a press-and-drag used to produce.
        await transport.setTalkDelay(.milliseconds(30))

        async let first: Void = subject.setTalking(true, channelID: channelID)
        async let second: Void = subject.setTalking(true, channelID: channelID)
        async let third: Void = subject.setTalking(false, channelID: channelID)
        _ = await (first, second, third)

        XCTAssertEqual(subject.activeTalkChannelCount, 0)
        let calls = await transport.talkCallsValue()
        XCTAssertEqual(calls.last?.enabled, false, "A mikrofon bekapcsolva maradt a felengedés után.")
        // The duplicate press must not reach the transport twice.
        XCTAssertEqual(calls.filter(\.enabled).count, 1)
    }

    // MARK: - Audio session events

    func testInterruptionStopsTalkingEverywhere() async {
        let (subject, transport, audio) = await makeConnectedSubject()
        let channelID = try! XCTUnwrap(subject.configuration.channels.first?.id)
        await subject.setTalking(true, channelID: channelID)

        // An incoming call takes the microphone: the user must never be shown
        // as on air while nothing is transmitted.
        await audio.emit(.interruptionBegan)

        await waitUntil { subject.activeTalkChannelCount == 0 }
        let talkCalls = await transport.talkCallsValue()
        XCTAssertEqual(talkCalls.last?.enabled, false)
    }

    func testHeadsetDisconnectStopsTalking() async {
        let (subject, _, audio) = await makeConnectedSubject()
        let channelID = try! XCTUnwrap(subject.configuration.channels.first?.id)
        await subject.setTalking(true, channelID: channelID)

        await audio.emit(.routeChanged(reason: .deviceDisconnected, outputName: "Speaker"))

        // Falling back to the built-in mic and speaker on a live set means
        // feedback, so Talk is released rather than rerouted.
        await waitUntil { subject.activeTalkChannelCount == 0 }
        await waitUntil { subject.audioRouteName == "Speaker" }
    }

    func testHeadsetConnectKeepsTalking() async {
        let (subject, _, audio) = await makeConnectedSubject()
        let channelID = try! XCTUnwrap(subject.configuration.channels.first?.id)
        await subject.setTalking(true, channelID: channelID)

        await audio.emit(.routeChanged(reason: .deviceConnected, outputName: "AirPods Pro"))

        await waitUntil { subject.audioRouteName == "AirPods Pro" }
        XCTAssertEqual(subject.activeTalkChannelCount, 1)
    }

    func testMediaServicesResetDisconnects() async {
        let (subject, _, audio) = await makeConnectedSubject()

        await audio.emit(.mediaServicesWereReset)

        await waitUntil { subject.connectionState == .disconnected }
        XCTAssertNotNil(subject.errorMessage)
    }

    // MARK: - Permissions

    func testTalkIsRefusedWithoutPermission() async {
        let configuration = IntercomConfiguration(
            displayName: "Teszt",
            productionID: UUID(),
            serverURL: URL(string: "wss://example.invalid"),
            channels: [
                IntercomChannel(name: "Program", detail: "Csak hallgatás", colorHex: "5B8CFF", canTalk: false)
            ]
        )
        let transport = TransportSpy()
        let subject = IntercomViewModel(
            configuration: configuration,
            transport: transport,
            audioSession: AudioSessionSpy(permissionGranted: true)
        )
        await subject.connect()

        await subject.setTalking(true, channelID: configuration.channels[0].id)

        XCTAssertEqual(subject.activeTalkChannelCount, 0)
        XCTAssertNotNil(subject.errorMessage)
        let talkCalls = await transport.talkCallsValue()
        XCTAssertTrue(talkCalls.isEmpty)
    }

    func testListenToggleIsRefusedWithoutPermission() async {
        let configuration = IntercomConfiguration(
            displayName: "Teszt",
            productionID: UUID(),
            serverURL: URL(string: "wss://example.invalid"),
            channels: [
                IntercomChannel(
                    name: "Rendező",
                    detail: "Zárt vonal",
                    colorHex: "F59E0B",
                    isListening: false,
                    canListen: false
                )
            ]
        )
        let transport = TransportSpy()
        let subject = IntercomViewModel(
            configuration: configuration,
            transport: transport,
            audioSession: AudioSessionSpy(permissionGranted: true)
        )
        await subject.connect()

        await subject.toggleListening(channelID: configuration.channels[0].id)

        XCTAssertFalse(subject.configuration.channels[0].isListening)
    }

    // MARK: - Helpers

    private func makeConnectedSubject() async -> (IntercomViewModel, TransportSpy, AudioSessionSpy) {
        let transport = TransportSpy()
        let audio = AudioSessionSpy(permissionGranted: true)
        let subject = IntercomViewModel(transport: transport, audioSession: audio)
        await subject.connect()
        XCTAssertEqual(subject.connectionState, .connected)
        return (subject, transport, audio)
    }

    /// The view model consumes events on a detached task, so assertions have to
    /// wait for the state to settle rather than assume it already has.
    private func waitUntil(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Időtúllépés: a várt állapot nem állt be.", file: file, line: line)
    }
}

// MARK: - Doubles

private actor TransportSpy: IntercomTransport {
    struct TalkCall: Equatable {
        let enabled: Bool
        let channelID: UUID
    }

    private(set) var didConnect = false
    private(set) var talkCalls: [TalkCall] = []
    private var talkDelay: Duration = .zero
    private let stream: AsyncStream<IntercomTransportEvent>
    private let continuation: AsyncStream<IntercomTransportEvent>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func connect(configuration _: IntercomConfiguration) async throws { didConnect = true }
    func disconnect() async {}
    func setListening(_: Bool, channelID _: UUID) async throws {}

    func setTalkDelay(_ delay: Duration) { talkDelay = delay }

    func setTalking(_ enabled: Bool, channelID: UUID) async throws {
        if talkDelay > .zero { try? await Task.sleep(for: talkDelay) }
        talkCalls.append(TalkCall(enabled: enabled, channelID: channelID))
    }

    func events() async -> AsyncStream<IntercomTransportEvent> { stream }

    func emit(_ event: IntercomTransportEvent) { continuation.yield(event) }
    func connectedValue() -> Bool { didConnect }
    func talkCallsValue() -> [TalkCall] { talkCalls }
}

private actor AudioSessionSpy: AudioSessionControlling {
    let permissionGranted: Bool
    private(set) var didActivate = false
    private(set) var activateCount = 0
    private let stream: AsyncStream<AudioSessionEvent>
    private let continuation: AsyncStream<AudioSessionEvent>.Continuation

    init(permissionGranted: Bool) {
        self.permissionGranted = permissionGranted
        (stream, continuation) = AsyncStream.makeStream()
    }

    func requestMicrophonePermission() async -> Bool { permissionGranted }

    func activate() async throws {
        didActivate = true
        activateCount += 1
    }

    func deactivate() async {}
    func events() async -> AsyncStream<AudioSessionEvent> { stream }
    func currentOutputName() async -> String? { "Speaker" }

    func emit(_ event: AudioSessionEvent) { continuation.yield(event) }
    func activatedValue() -> Bool { didActivate }
}
