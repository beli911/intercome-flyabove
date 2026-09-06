import XCTest
@testable import FlyAboveIntercom

@MainActor
final class EventLogTests: XCTestCase {
    /// A clock the log can call from anywhere, advancing one second per entry
    /// so ordering is a fact rather than a matter of timing.
    private final class Tick: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds = 0.0

        func next() -> Date {
            lock.withLock {
                seconds += 1
                return Date(timeIntervalSince1970: seconds)
            }
        }
    }

    private func log(limit: Int = 200) -> EventLog {
        let tick = Tick()
        return EventLog(limit: limit, now: { tick.next() })
    }

    func testNewestFirst() {
        // An operator opening this wants the last thing that happened.
        let subject = log()
        subject.record(.connected)
        subject.record(.reconnecting, severity: .warning)

        XCTAssertEqual(subject.entries.first?.code, .reconnecting)
        XCTAssertEqual(subject.entries.last?.code, .connected)
    }

    func testTheLogIsBounded() {
        // A session runs for hours; an unbounded log is a memory leak with a
        // user interface.
        let subject = log(limit: 3)
        for _ in 0 ..< 10 { subject.record(.connected) }

        XCTAssertEqual(subject.entries.count, 3)
    }

    func testBoundingDropsTheOldest() {
        let subject = log(limit: 2)
        subject.record(.connected)
        subject.record(.reconnecting)
        subject.record(.disconnected)

        XCTAssertEqual(subject.entries.map(\.code), [.disconnected, .reconnecting])
    }

    func testProblemCountIgnoresRoutineEntries() {
        let subject = log()
        subject.record(.connected)
        subject.record(.routeChanged)
        subject.record(.interrupted, severity: .warning)
        subject.record(.failsafeDisconnect, severity: .error)

        XCTAssertEqual(subject.problemCount, 2)
    }

    func testClearing() {
        let subject = log()
        subject.record(.connected)
        subject.clear()
        XCTAssertTrue(subject.entries.isEmpty)
    }
}

@MainActor
final class ViewModelEventRecordingTests: XCTestCase {
    private func makeSubject() -> (IntercomViewModel, EventRecordingTransport, EventLog) {
        let transport = EventRecordingTransport()
        let log = EventLog()
        let subject = IntercomViewModel(
            transport: transport,
            audioSession: EventRecordingAudioSession(),
            events: log
        )
        return (subject, transport, log)
    }

    func testConnectAndDisconnectAreRecorded() async {
        let (subject, _, log) = makeSubject()
        await subject.connect()
        await subject.disconnect()

        XCTAssertEqual(log.entries.map(\.code), [.disconnected, .connected])
    }

    func testOnlyStateChangesAreRecorded() async {
        let (subject, transport, log) = makeSubject()
        await subject.connect()

        // The transport repeats the current state on every room event; logging
        // each one would bury the transitions that matter.
        await transport.emit(.connectionStateChanged(.connected))
        await transport.emit(.connectionStateChanged(.connected))
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(log.entries.count { $0.code == .connected }, 1)
    }

    func testReconnectAndRecoveryAreBothRecorded() async {
        let (subject, transport, log) = makeSubject()
        await subject.connect()

        await transport.emit(.connectionStateChanged(.reconnecting))
        try? await Task.sleep(for: .milliseconds(80))
        await transport.emit(.connectionStateChanged(.connected))
        try? await Task.sleep(for: .milliseconds(80))

        let codes = log.entries.map(\.code)
        XCTAssertEqual(codes.prefix(2).map { $0 }, [.connected, .reconnecting])
        XCTAssertEqual(log.problemCount, 1)
    }

    func testATalkStoppedByTheSystemIsRecordedAsAProblem() async {
        let (subject, transport, log) = makeSubject()
        await subject.connect()
        let channelID = subject.configuration.channels[0].id
        await subject.setTalking(true, channelID: channelID)

        await transport.emit(.talkStopped(channelID: channelID))
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertTrue(log.entries.contains { $0.code == .talkStoppedBySystem })
        XCTAssertEqual(log.entries.first?.detail, subject.configuration.channels[0].name)
    }

    func testAnUnpromptedTalkStopIsNotRecorded() async {
        let (subject, transport, log) = makeSubject()
        await subject.connect()
        let channelID = subject.configuration.channels[0].id

        // Nothing was open, so nothing was taken away.
        await transport.emit(.talkStopped(channelID: channelID))
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertFalse(log.entries.contains { $0.code == .talkStoppedBySystem })
    }
}

private actor EventRecordingTransport: IntercomTransport {
    private let stream: AsyncStream<IntercomTransportEvent>
    private let continuation: AsyncStream<IntercomTransportEvent>.Continuation

    init() { (stream, continuation) = AsyncStream.makeStream() }

    func connect(configuration _: IntercomConfiguration) async throws {}
    func disconnect() async {}
    func setListening(_: Bool, channelID _: UUID) async throws {}
    func setTalking(_: Bool, channelID _: UUID) async throws {}
    func setVolume(_: Double, channelID _: UUID) async throws {}
    func setDucking(_: Double, channelID _: UUID) async throws {}
    func events() async -> AsyncStream<IntercomTransportEvent> { stream }
    func emit(_ event: IntercomTransportEvent) { continuation.yield(event) }
}

private actor EventRecordingAudioSession: AudioSessionControlling {
    func requestMicrophonePermission() async -> Bool { true }
    func activate(recording _: Bool) async throws {}
    func deactivate() async {}
    func events() async -> AsyncStream<AudioSessionEvent> { AsyncStream { $0.finish() } }
    func currentOutputName() async -> String? { "Teszt" }
}
