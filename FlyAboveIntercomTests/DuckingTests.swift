import XCTest
@testable import FlyAboveIntercom

/// Every combination of the two inputs against every role. This is the one
/// piece of audio behaviour where being wrong is inaudible until it matters.
final class DuckingTests: XCTestCase {
    private func input(priority: Bool, talking: Bool) -> DuckingPolicy.Input {
        DuckingPolicy.Input(isPriorityActive: priority, isSelfTalking: talking)
    }

    func testPriorityLineIsNeverDucked() {
        for priority in [true, false] {
            for talking in [true, false] {
                XCTAssertFalse(
                    DuckingPolicy.shouldDuck(
                        role: .priority,
                        input: input(priority: priority, talking: talking)
                    ),
                    "prioritás=\(priority) beszél=\(talking)"
                )
            }
        }
    }

    func testProgramDucksForTheDirectorAndForUs() {
        XCTAssertTrue(DuckingPolicy.shouldDuck(role: .program, input: input(priority: true, talking: false)))
        XCTAssertTrue(DuckingPolicy.shouldDuck(role: .program, input: input(priority: false, talking: true)))
        XCTAssertTrue(DuckingPolicy.shouldDuck(role: .program, input: input(priority: true, talking: true)))
        XCTAssertFalse(DuckingPolicy.shouldDuck(role: .program, input: input(priority: false, talking: false)))
    }

    func testOrdinaryLinesDuckOnlyForTheDirector() {
        XCTAssertTrue(DuckingPolicy.shouldDuck(role: .line, input: input(priority: true, talking: false)))
        // The case that matters: ducking the lines while we talk would mute
        // the very people we are talking to.
        XCTAssertFalse(DuckingPolicy.shouldDuck(role: .line, input: input(priority: false, talking: true)))
        XCTAssertFalse(DuckingPolicy.shouldDuck(role: .line, input: input(priority: false, talking: false)))
    }

    func testMultiplierIsUnityWhenNotDucking() {
        XCTAssertEqual(
            DuckingPolicy.gainMultiplier(
                for: .line,
                input: input(priority: false, talking: false),
                duckDecibels: 12
            ),
            1
        )
    }

    func testMultiplierMatchesTheRequestedDecibels() {
        let multiplier = DuckingPolicy.gainMultiplier(
            for: .line,
            input: input(priority: true, talking: false),
            duckDecibels: 12
        )
        XCTAssertEqual(20 * log10(multiplier), -12, accuracy: 0.001)
    }

    func testASignedDecibelValueStillDucksDownwards() {
        // A production writing -12 means the same thing as 12; neither may
        // turn into a 12 dB boost.
        let negative = DuckingPolicy.gainMultiplier(
            for: .line,
            input: input(priority: true, talking: false),
            duckDecibels: -12
        )
        XCTAssertEqual(20 * log10(negative), -12, accuracy: 0.001)
    }

    func testZeroDecibelsIsAudiblyNothing() {
        XCTAssertEqual(
            DuckingPolicy.gainMultiplier(
                for: .line,
                input: input(priority: true, talking: false),
                duckDecibels: 0
            ),
            1,
            accuracy: 0.0001
        )
    }
}

@MainActor
final class DuckingIntegrationWithViewModelTests: XCTestCase {
    private func makeConfiguration() -> IntercomConfiguration {
        IntercomConfiguration(
            displayName: "Teszt",
            productionID: UUID(),
            serverURL: URL(string: "wss://example.invalid"),
            channels: [
                IntercomChannel(name: "Mindenki", detail: "", colorHex: "5B8CFF", role: .line),
                IntercomChannel(name: "Rendező", detail: "", colorHex: "F59E0B", role: .priority),
                IntercomChannel(
                    name: "Program",
                    detail: "",
                    colorHex: "4FD6D2",
                    canTalk: false,
                    role: .program,
                    duckDecibels: 15
                )
            ]
        )
    }

    func testTheDirectorSpeakingDucksTheOtherLines() async {
        let transport = DuckingTransportSpy()
        let subject = IntercomViewModel(
            configuration: makeConfiguration(),
            transport: transport,
            audioSession: PermissiveAudioSession()
        )
        await subject.connect()

        await transport.emit(.remoteSpeakingChanged(
            channelID: subject.configuration.channels[1].id,
            isSpeaking: true
        ))

        try? await Task.sleep(for: .milliseconds(150))
        let line = await transport.duck(subject.configuration.channels[0].id)
        let priority = await transport.duck(subject.configuration.channels[1].id)
        let program = await transport.duck(subject.configuration.channels[2].id)

        XCTAssertEqual(20 * log10(line ?? 1), -12, accuracy: 0.01)
        XCTAssertEqual(priority, 1, "A prioritás vonal nem halkulhat le.")
        XCTAssertEqual(20 * log10(program ?? 1), -15, accuracy: 0.01)
        XCTAssertTrue(subject.isDuckingActive)
    }

    func testTalkingDucksOnlyTheProgramFeed() async {
        let transport = DuckingTransportSpy()
        let subject = IntercomViewModel(
            configuration: makeConfiguration(),
            transport: transport,
            audioSession: PermissiveAudioSession()
        )
        await subject.connect()

        await subject.setTalking(true, channelID: subject.configuration.channels[0].id)
        try? await Task.sleep(for: .milliseconds(150))

        let line = await transport.duck(subject.configuration.channels[0].id)
        let program = await transport.duck(subject.configuration.channels[2].id)
        XCTAssertEqual(line, 1, "A vonalakat nem szabad lehalkítani, amíg beszélünk rajtuk.")
        XCTAssertEqual(20 * log10(program ?? 1), -15, accuracy: 0.01)
    }

    func testDuckingEndsWhenSpeechStops() async {
        let transport = DuckingTransportSpy()
        let subject = IntercomViewModel(
            configuration: makeConfiguration(),
            transport: transport,
            audioSession: PermissiveAudioSession()
        )
        await subject.connect()
        let priorityID = subject.configuration.channels[1].id

        await transport.emit(.remoteSpeakingChanged(channelID: priorityID, isSpeaking: true))
        try? await Task.sleep(for: .milliseconds(150))
        await transport.emit(.remoteSpeakingChanged(channelID: priorityID, isSpeaking: false))
        try? await Task.sleep(for: .milliseconds(150))

        // Back to exactly unity, not an approximation of the level before.
        let line = await transport.duck(subject.configuration.channels[0].id)
        XCTAssertEqual(line, 1)
        XCTAssertFalse(subject.isDuckingActive)
    }
}

/// Grants the microphone without asking, so a ducking test measures ducking
/// and not the permission dialog.
private actor PermissiveAudioSession: AudioSessionControlling {
    func requestMicrophonePermission() async -> Bool { true }
    func activate(recording _: Bool) async throws {}
    func deactivate() async {}
    func events() async -> AsyncStream<AudioSessionEvent> { AsyncStream { $0.finish() } }
    func currentOutputName() async -> String? { "Teszt" }
}

private actor DuckingTransportSpy: IntercomTransport {
    private var ducks: [UUID: Double] = [:]
    private let stream: AsyncStream<IntercomTransportEvent>
    private let continuation: AsyncStream<IntercomTransportEvent>.Continuation

    init() { (stream, continuation) = AsyncStream.makeStream() }

    func connect(configuration _: IntercomConfiguration) async throws {}
    func disconnect() async {}
    func setListening(_: Bool, channelID _: UUID) async throws {}
    func setTalking(_: Bool, channelID _: UUID) async throws {}
    func setVolume(_: Double, channelID _: UUID) async throws {}

    func setDucking(_ multiplier: Double, channelID: UUID) async throws {
        ducks[channelID] = multiplier
    }

    func events() async -> AsyncStream<IntercomTransportEvent> { stream }
    func emit(_ event: IntercomTransportEvent) { continuation.yield(event) }
    func duck(_ channelID: UUID) -> Double? { ducks[channelID] }
}
