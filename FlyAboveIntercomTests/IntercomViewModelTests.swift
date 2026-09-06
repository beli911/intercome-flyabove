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

    func testConnectingDoesNotAskForTheMicrophone() async {
        let audio = AudioSessionSpy(permissionGranted: true)
        let subject = IntercomViewModel(transport: TransportSpy(), audioSession: audio)

        await subject.connect()

        // Listening needs no microphone, so nothing should be asked for yet.
        let asked = await audio.permissionRequestCount()
        XCTAssertEqual(asked, 0)
        XCTAssertNil(subject.isMicrophoneGranted)
        let recordingModes = await audio.activateRecordingModes()
        XCTAssertEqual(recordingModes, [false])
    }

    func testDeniedMicrophoneStillAllowsListening() async {
        let transport = TransportSpy()
        let audio = AudioSessionSpy(permissionGranted: false)
        let subject = IntercomViewModel(transport: transport, audioSession: audio)

        await subject.connect()

        // A listen-only operator who refuses the microphone must still get on
        // the line — refusing it is not a reason to lock them out of the show.
        XCTAssertTrue(subject.isConnected)
        let didConnect = await transport.connectedValue()
        XCTAssertTrue(didConnect)
    }

    func testDeniedMicrophoneBlocksTalkWithAMessage() async {
        let transport = TransportSpy()
        let audio = AudioSessionSpy(permissionGranted: false)
        let subject = IntercomViewModel(transport: transport, audioSession: audio)
        await subject.connect()
        let channelID = try! XCTUnwrap(subject.configuration.channels.first?.id)

        await subject.setTalking(true, channelID: channelID)

        XCTAssertEqual(subject.activeTalkChannelCount, 0)
        XCTAssertEqual(subject.isMicrophoneGranted, false)
        XCTAssertNotNil(subject.errorMessage)
        let talkCalls = await transport.talkCallsValue()
        XCTAssertTrue(talkCalls.isEmpty, "Engedély nélkül nem szabad publikálni.")
    }

    func testMicrophoneIsAskedForOnceOnFirstTalk() async {
        let audio = AudioSessionSpy(permissionGranted: true)
        let subject = IntercomViewModel(transport: TransportSpy(), audioSession: audio)
        await subject.connect()
        let channelID = try! XCTUnwrap(subject.configuration.channels.first?.id)

        await subject.setTalking(true, channelID: channelID)
        await subject.setTalking(false, channelID: channelID)
        await subject.setTalking(true, channelID: channelID)

        let asked = await audio.permissionRequestCount()
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(subject.isMicrophoneGranted, true)
        // Playback-only for listening, then the record category once we speak.
        let recordingModes = await audio.activateRecordingModes()
        XCTAssertEqual(recordingModes, [false, true])
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

        await transport.emit(.participantsChanged(
            channelID: channelID,
            participants: (0 ..< 7).map {
                ChannelParticipant(
                    id: "user-\($0)",
                    displayName: "Teszt \($0)",
                    isSpeaking: false,
                    quality: .good
                )
            }
        ))
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

        await transport.emit(.participantsChanged(
            channelID: channelID,
            participants: [
                ChannelParticipant(id: "x", displayName: "X", isSpeaking: false, quality: .good)
            ]
        ))

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(subject.configuration.channels[0].participants.isEmpty)
    }

    func testReleaseDuringAnInFlightPressStillEndsWithTheMicrophoneOff() async {
        let (subject, transport, _) = await makeConnectedSubject()
        let channelID = try! XCTUnwrap(subject.configuration.channels.first?.id)

        // Hold the transport inside the "start talking" call, then release the
        // button while it is genuinely still in there. Deterministic: the test
        // waits for the call to be in flight instead of hoping for a schedule.
        await transport.blockNextTalkCall()
        subject.requestTalking(true, channelID: channelID)
        let entered = await transport.waitUntilBlocked()
        XCTAssertTrue(entered, "A transport hívás nem indult el.")

        subject.requestTalking(false, channelID: channelID)

        await transport.unblock()
        await subject.waitForTalkWorkToSettle()

        XCTAssertEqual(subject.activeTalkChannelCount, 0)
        let calls = await transport.talkCallsValue()
        XCTAssertEqual(
            calls.last?.enabled,
            false,
            "A mikrofon bekapcsolva maradt a felengedés után: \(calls)"
        )
    }

    func testRepeatedPressReleaseAlwaysEndsWithTheMicrophoneOff() async {
        let (subject, transport, _) = await makeConnectedSubject()
        let channelID = try! XCTUnwrap(subject.configuration.channels.first?.id)

        for _ in 0 ..< 50 {
            subject.requestTalking(true, channelID: channelID)
            subject.requestTalking(false, channelID: channelID)
        }
        await subject.waitForTalkWorkToSettle()

        XCTAssertEqual(subject.activeTalkChannelCount, 0)
        let calls = await transport.talkCallsValue()
        XCTAssertNotEqual(calls.last?.enabled, true)
    }

    func testRedundantRequestsAreNotSentTwice() async {
        let (subject, transport, _) = await makeConnectedSubject()
        let channelID = try! XCTUnwrap(subject.configuration.channels.first?.id)

        subject.requestTalking(true, channelID: channelID)
        subject.requestTalking(true, channelID: channelID)
        subject.requestTalking(true, channelID: channelID)
        await subject.waitForTalkWorkToSettle()

        let calls = await transport.talkCallsValue()
        XCTAssertEqual(calls.filter(\.enabled).count, 1)
    }

    func testReleaseDuringThePermissionPromptNeverOpensTheMicrophone() async {
        let transport = TransportSpy()
        let audio = AudioSessionSpy(permissionGranted: true)
        let subject = IntercomViewModel(transport: transport, audioSession: audio)
        await subject.connect()
        let channelID = try! XCTUnwrap(subject.configuration.channels.first?.id)

        // Hold the system permission prompt open, press, then let go while it is
        // still up. Granting afterwards must not open a microphone the user is
        // no longer asking for.
        await audio.blockNextPermissionRequest()
        subject.requestTalking(true, channelID: channelID)
        let prompting = await audio.waitUntilPrompting()
        XCTAssertTrue(prompting, "Az engedélykérés nem indult el.")

        subject.requestTalking(false, channelID: channelID)
        await audio.unblockPermissionRequest()
        await subject.waitForTalkWorkToSettle()

        XCTAssertEqual(subject.activeTalkChannelCount, 0)
        let calls = await transport.talkCallsValue()
        XCTAssertTrue(
            calls.filter(\.enabled).isEmpty,
            "A mikrofon elindult, pedig a gombot már elengedték: \(calls)"
        )
    }

    func testTalkAllAsksForTheMicrophoneOnlyOnce() async {
        let audio = AudioSessionSpy(permissionGranted: true)
        let subject = IntercomViewModel(transport: TransportSpy(), audioSession: audio)
        await subject.connect()

        subject.requestTalkingOnAllChannels(true)
        await subject.waitForTalkWorkToSettle()

        // Three channels, one prompt and one session activation.
        let asked = await audio.permissionRequestCount()
        XCTAssertEqual(asked, 1)
        let recordingModes = await audio.activateRecordingModes()
        XCTAssertEqual(recordingModes, [false, true])
    }

    func testSwitchingTalkModeReleasesAnOpenLatch() async {
        let (subject, transport, _) = await makeConnectedSubject()
        subject.talkMode = .latch
        let channelID = try! XCTUnwrap(subject.configuration.channels.first?.id)
        subject.requestTalking(true, channelID: channelID)
        await subject.waitForTalkWorkToSettle()
        XCTAssertEqual(subject.activeTalkChannelCount, 1)

        subject.talkMode = .momentary
        await subject.waitForTalkWorkToSettle()

        // Momentary has no button holding it open, so the latch must not survive
        // the switch.
        XCTAssertEqual(subject.activeTalkChannelCount, 0)
        let calls = await transport.talkCallsValue()
        XCTAssertEqual(calls.last?.enabled, false)
    }

    func testConnectIsIgnoredWhileReconnecting() async {
        let (subject, transport, _) = await makeConnectedSubject()
        await transport.emit(.connectionStateChanged(.reconnecting))
        await waitUntil { subject.connectionState == .reconnecting }
        let connectsBefore = await transport.connectCount()

        await subject.connect()

        // A second connect on a live transport would mint new grants alongside
        // the existing sessions.
        let connectsAfter = await transport.connectCount()
        XCTAssertEqual(connectsAfter, connectsBefore)
        XCTAssertEqual(subject.connectionState, .reconnecting)
    }

    func testAMicrophoneThatWillNotStopForcesTheSessionDown() async {
        let (subject, transport, audio) = await makeConnectedSubject()
        let channelID = try! XCTUnwrap(subject.configuration.channels.first?.id)
        await subject.setTalking(true, channelID: channelID)
        XCTAssertEqual(subject.activeTalkChannelCount, 1)

        await transport.failTalkCalls(enabling: false, disabling: true)
        await subject.setTalking(false, channelID: channelID)

        // The stop failed, so the microphone's real state is unknown. Recording
        // it as "off" and carrying on would leave an open microphone that
        // nothing on screen reveals.
        XCTAssertEqual(subject.connectionState, .disconnected)
        let disconnects = await transport.disconnectCount()
        XCTAssertEqual(disconnects, 1)
        XCTAssertNotNil(subject.errorMessage)
        XCTAssertEqual(subject.activeTalkChannelCount, 0)
    }

    func testAMicrophoneThatWillNotStartKeepsTheSession() async {
        let (subject, transport, _) = await makeConnectedSubject()
        let channelID = try! XCTUnwrap(subject.configuration.channels.first?.id)

        await transport.failTalkCalls(enabling: true, disabling: false)
        await subject.setTalking(true, channelID: channelID)

        // Failing to open transmits nothing, so there is nothing to protect
        // against: report it and stay on the line.
        XCTAssertEqual(subject.connectionState, .connected)
        let disconnects = await transport.disconnectCount()
        XCTAssertEqual(disconnects, 0)
        XCTAssertEqual(subject.activeTalkChannelCount, 0)
        XCTAssertNotNil(subject.errorMessage)
    }

    func testDisconnectDuringThePermissionPromptDoesNotArmRecording() async {
        let transport = TransportSpy()
        let audio = AudioSessionSpy(permissionGranted: true)
        let subject = IntercomViewModel(transport: transport, audioSession: audio)
        await subject.connect()
        let channelID = try! XCTUnwrap(subject.configuration.channels.first?.id)

        await audio.blockNextPermissionRequest()
        subject.requestTalking(true, channelID: channelID)
        let prompting = await audio.waitUntilPrompting()
        XCTAssertTrue(prompting)

        // The user hangs up while the system prompt is still on screen, then
        // taps Allow. The disconnect runs concurrently on purpose: awaiting it
        // first would block on the still-suspended worker and burn the whole
        // settle timeout on every run.
        async let disconnecting: Void = subject.disconnect()
        try? await Task.sleep(for: .milliseconds(30))
        await audio.unblockPermissionRequest()
        await disconnecting
        await subject.waitForTalkWorkToSettle()

        // Only the playback session from `connect` may have been activated;
        // arming a recording session for a session that is gone would leave the
        // microphone indicator on with nothing behind it.
        let recordingModes = await audio.activateRecordingModes()
        XCTAssertEqual(recordingModes, [false])
        XCTAssertEqual(subject.connectionState, .disconnected)
    }

    func testLeavingTheForegroundReleasesTalk() async {
        let (subject, transport, _) = await makeConnectedSubject()
        subject.talkMode = .latch
        let channelID = try! XCTUnwrap(subject.configuration.channels.first?.id)
        subject.requestTalking(true, channelID: channelID)
        await subject.waitForTalkWorkToSettle()
        XCTAssertEqual(subject.activeTalkChannelCount, 1)

        await subject.handleSceneActivation(isActive: false)

        // Nothing on a background screen can close a latched microphone.
        XCTAssertEqual(subject.activeTalkChannelCount, 0)
        let calls = await transport.talkCallsValue()
        XCTAssertEqual(calls.last?.enabled, false)
    }

    func testAFailedStopDoesNotLeaveOtherChannelWorkersRunning() async {
        let (subject, transport, _) = await makeConnectedSubject()
        let first = try! XCTUnwrap(subject.configuration.channels.first?.id)
        let second = try! XCTUnwrap(subject.configuration.channels.dropFirst().first?.id)

        subject.requestTalking(true, channelID: first)
        subject.requestTalking(true, channelID: second)
        await subject.waitForTalkWorkToSettle()
        XCTAssertEqual(subject.activeTalkChannelCount, 2)

        // Hold the second channel's stop in flight while the first one fails.
        // The fail-safe tears the session down; the late worker must not write
        // into it afterwards, nor block the next session's first Talk.
        await transport.failTalkCalls(enabling: false, disabling: true)
        await transport.blockNextTalkCall()
        subject.requestTalking(false, channelID: second)
        let blocked = await transport.waitUntilBlocked()
        XCTAssertTrue(blocked)

        // Not `setTalking`: that waits for every worker, including the one this
        // test is deliberately holding, and would burn the settle timeout.
        subject.requestTalking(false, channelID: first)
        await waitUntil { subject.connectionState == .disconnected }

        await transport.unblock()
        await subject.waitForTalkWorkToSettle()

        // The late worker belongs to a session that no longer exists. Without
        // that binding its own stop also fails, and it tears the transport down
        // a second time — for a session already gone.
        let disconnects = await transport.disconnectCount()
        XCTAssertEqual(disconnects, 1, "Egy elavult worker másodszor is bontott.")

        // A new session must be able to talk immediately: a leftover worker
        // entry from the dead session would silently swallow the request.
        await transport.failTalkCalls(enabling: false, disabling: false)
        await subject.connect()
        XCTAssertEqual(subject.connectionState, .connected)
        await subject.setTalking(true, channelID: second)
        XCTAssertEqual(subject.activeTalkChannelCount, 1)
    }

    // MARK: - Configuration pushed by the server

    private func descriptor(
        _ channel: IntercomChannel,
        canTalk: Bool? = nil,
        canListen: Bool? = nil,
        name: String? = nil
    ) -> ChannelDescriptor {
        ChannelDescriptor(
            id: channel.id,
            name: name ?? channel.name,
            detail: channel.detail,
            colorHex: channel.colorHex,
            canTalk: canTalk ?? channel.canTalk,
            canListen: canListen ?? channel.canListen,
            defaultListening: channel.isListening,
            participantCount: channel.participantCount,
            role: .line,
            duckDecibels: 12
        )
    }

    func testRevokedTalkSilencesAMicrophoneThatIsOpen() async {
        let (subject, transport, _) = await makeConnectedSubject()
        subject.talkMode = .latch
        let channel = subject.configuration.channels[0]
        subject.requestTalking(true, channelID: channel.id)
        await subject.waitForTalkWorkToSettle()
        XCTAssertEqual(subject.activeTalkChannelCount, 1)

        // The production takes the line away while the microphone is open.
        // This is the case the whole push mechanism exists for.
        await subject.applyUpdatedChannels([
            descriptor(channel, canTalk: false),
            descriptor(subject.configuration.channels[1]),
            descriptor(subject.configuration.channels[2])
        ])

        XCTAssertEqual(subject.activeTalkChannelCount, 0)
        XCTAssertFalse(subject.configuration.channels[0].canTalk)
        let calls = await transport.talkCallsValue()
        XCTAssertEqual(calls.last?.enabled, false)
    }

    func testRevokedListenLeavesTheChannel() async {
        let (subject, transport, _) = await makeConnectedSubject()
        let channel = subject.configuration.channels[0]
        XCTAssertTrue(channel.isListening)

        await subject.applyUpdatedChannels([
            descriptor(channel, canListen: false),
            descriptor(subject.configuration.channels[1]),
            descriptor(subject.configuration.channels[2])
        ])

        XCTAssertFalse(subject.configuration.channels[0].isListening)
        let calls = await transport.listenCallsValue()
        XCTAssertEqual(calls.last?.enabled, false)
    }

    func testARenamedChannelKeepsTheOperatorsOwnSettings() async {
        let (subject, _, _) = await makeConnectedSubject()
        let channel = subject.configuration.channels[2]
        XCTAssertFalse(channel.isListening)
        await subject.setVolume(0.5, channelID: channel.id)

        await subject.applyUpdatedChannels([
            descriptor(subject.configuration.channels[0]),
            descriptor(subject.configuration.channels[1]),
            descriptor(channel, name: "Rendező 2")
        ])

        // The server owns the name; Listen state and level belong to the
        // operator and must survive a rename.
        XCTAssertEqual(subject.configuration.channels[2].name, "Rendező 2")
        XCTAssertFalse(subject.configuration.channels[2].isListening)
        XCTAssertEqual(subject.configuration.channels[2].volume, 0.5)
    }

    func testANewChannelFollowsTheServersDefault() async {
        let (subject, _, _) = await makeConnectedSubject()
        let newChannel = ChannelDescriptor(
            id: UUID(),
            name: "Hang",
            detail: "FOH",
            colorHex: "4FD6D2",
            canTalk: true,
            canListen: true,
            defaultListening: true,
            participantCount: 0,
            role: .line,
            duckDecibels: 12
        )

        await subject.applyUpdatedChannels(
            subject.configuration.channels.map { descriptor($0) } + [newChannel]
        )

        XCTAssertEqual(subject.configuration.channels.count, 4)
        // Granting access mid-show is the production saying "you need to hear
        // this", and the descriptor has to mean the same thing here as it does
        // at launch.
        XCTAssertTrue(subject.configuration.channels[3].isListening)
        XCTAssertEqual(subject.configuration.channels[3].name, "Hang")
    }

    func testANewChannelTheServerWantsMutedStaysMuted() async {
        let (subject, _, _) = await makeConnectedSubject()
        let quiet = ChannelDescriptor(
            id: UUID(),
            name: "Archív",
            detail: "Nem élő",
            colorHex: "B36BFF",
            canTalk: false,
            canListen: true,
            defaultListening: false,
            participantCount: 0,
            role: .line,
            duckDecibels: 12
        )

        await subject.applyUpdatedChannels(
            subject.configuration.channels.map { descriptor($0) } + [quiet]
        )

        XCTAssertFalse(subject.configuration.channels[3].isListening)
    }

    func testARemovedChannelDisappearsAndIsLeft() async {
        let (subject, transport, _) = await makeConnectedSubject()
        let removed = subject.configuration.channels[0]

        await subject.applyUpdatedChannels([
            descriptor(subject.configuration.channels[1]),
            descriptor(subject.configuration.channels[2])
        ])

        XCTAssertEqual(subject.configuration.channels.count, 2)
        XCTAssertFalse(subject.configuration.channels.contains { $0.id == removed.id })
        let calls = await transport.listenCallsValue()
        XCTAssertTrue(calls.contains { $0.channelID == removed.id && !$0.enabled })
    }

    func testAStaleConfigurationEventReachesTheOwner() async {
        let (subject, transport, _) = await makeConnectedSubject()
        let versions = VersionRecorder()
        subject.onConfigurationStale = { version in await versions.record(version) }

        await transport.emit(.configurationStale(version: 7))

        await waitUntilAsync { await versions.values() == [7] }
    }

    // MARK: - Audio session events

    func testInterruptionStopsTalkingEverywhere() async {
        let (subject, transport, audio) = await makeConnectedSubject()
        let channelID = try! XCTUnwrap(subject.configuration.channels.first?.id)
        await subject.setTalking(true, channelID: channelID)

        // An incoming call takes the microphone: the user must never be shown
        // as on air while nothing is transmitted.
        await audio.emit(.interruptionBegan)

        // Wait on the transport, not on the optimistic UI flag: the view model
        // clears `isTalking` before the call goes out, so asserting on the flag
        // races the worker that actually closes the microphone.
        await waitUntilAsync { await transport.talkCallsValue().last?.enabled == false }
        XCTAssertEqual(subject.activeTalkChannelCount, 0)
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

    /// Same as `waitUntil`, for a condition that has to be read off an actor.
    private func waitUntilAsync(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Időtúllépés: a várt állapot nem állt be.", file: file, line: line)
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
    private var gate: CheckedContinuation<Void, Never>?
    private var blockNext = false
    private var isBlocked = false
    private var failEnabling = false
    private var failDisabling = false
    private(set) var disconnects = 0

    struct TalkFailure: Error {}

    func failTalkCalls(enabling: Bool, disabling: Bool) {
        failEnabling = enabling
        failDisabling = disabling
    }

    func disconnectCount() -> Int { disconnects }
    private let stream: AsyncStream<IntercomTransportEvent>
    private let continuation: AsyncStream<IntercomTransportEvent>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    private(set) var connects = 0

    func connect(configuration _: IntercomConfiguration) async throws {
        didConnect = true
        connects += 1
    }

    func connectCount() -> Int { connects }
    func disconnect() async { disconnects += 1 }
    private(set) var listenCalls: [TalkCall] = []

    func setListening(_ enabled: Bool, channelID: UUID) async throws {
        listenCalls.append(TalkCall(enabled: enabled, channelID: channelID))
    }

    func listenCallsValue() -> [TalkCall] { listenCalls }
    private(set) var volumes: [UUID: Double] = [:]
    func setVolume(_ volume: Double, channelID: UUID) async throws { volumes[channelID] = volume }
    func volumeValue(_ channelID: UUID) -> Double? { volumes[channelID] }
    private(set) var ducks: [UUID: Double] = [:]
    func setDucking(_ multiplier: Double, channelID: UUID) async throws { ducks[channelID] = multiplier }
    func duckValue(_ channelID: UUID) -> Double? { ducks[channelID] }

    /// Suspends the next `setTalking` until `unblock()`, so a test can hold the
    /// transport open and act while a call is genuinely in flight.
    func blockNextTalkCall() { blockNext = true }

    /// Resolves once the transport is actually suspended inside `setTalking`.
    func waitUntilBlocked(timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isBlocked, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return isBlocked
    }

    func unblock() {
        blockNext = false
        isBlocked = false
        gate?.resume()
        gate = nil
    }

    func setTalking(_ enabled: Bool, channelID: UUID) async throws {
        if blockNext {
            blockNext = false
            isBlocked = true
            await withCheckedContinuation { continuation in gate = continuation }
        }
        talkCalls.append(TalkCall(enabled: enabled, channelID: channelID))
        if enabled ? failEnabling : failDisabling { throw TalkFailure() }
    }

    func events() async -> AsyncStream<IntercomTransportEvent> { stream }

    func emit(_ event: IntercomTransportEvent) { continuation.yield(event) }
    func connectedValue() -> Bool { didConnect }
    func talkCallsValue() -> [TalkCall] { talkCalls }
}

private actor AudioSessionSpy: AudioSessionControlling {
    let permissionGranted: Bool
    private(set) var didActivate = false
    private(set) var permissionRequests = 0
    private(set) var recordingModes: [Bool] = []
    private let stream: AsyncStream<AudioSessionEvent>
    private let continuation: AsyncStream<AudioSessionEvent>.Continuation

    init(permissionGranted: Bool) {
        self.permissionGranted = permissionGranted
        (stream, continuation) = AsyncStream.makeStream()
    }

    private var permissionGate: CheckedContinuation<Void, Never>?
    private var blockPermission = false
    private var isPrompting = false

    /// Holds the next permission request open, so a test can release the button
    /// while the system prompt is still on screen.
    func blockNextPermissionRequest() { blockPermission = true }

    func waitUntilPrompting(timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isPrompting, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return isPrompting
    }

    func unblockPermissionRequest() {
        blockPermission = false
        isPrompting = false
        permissionGate?.resume()
        permissionGate = nil
    }

    func requestMicrophonePermission() async -> Bool {
        permissionRequests += 1
        if blockPermission {
            blockPermission = false
            isPrompting = true
            await withCheckedContinuation { continuation in permissionGate = continuation }
        }
        return permissionGranted
    }

    func activate(recording: Bool) async throws {
        didActivate = true
        recordingModes.append(recording)
    }

    func permissionRequestCount() -> Int { permissionRequests }
    func activateRecordingModes() -> [Bool] { recordingModes }

    func deactivate() async {}
    func events() async -> AsyncStream<AudioSessionEvent> { stream }
    func currentOutputName() async -> String? { "Speaker" }

    func emit(_ event: AudioSessionEvent) { continuation.yield(event) }
    func activatedValue() -> Bool { didActivate }
}


/// Collects the versions handed to `onConfigurationStale`.
private actor VersionRecorder {
    private var recorded: [Int] = []
    func record(_ version: Int) { recorded.append(version) }
    func values() -> [Int] { recorded }
}
