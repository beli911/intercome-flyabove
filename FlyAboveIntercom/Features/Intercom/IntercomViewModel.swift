import Combine
import Foundation

@MainActor
final class IntercomViewModel: ObservableObject {
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var configuration: IntercomConfiguration
    @Published private(set) var statistics: IntercomStatistics?
    @Published private(set) var audioRouteName: String?
    @Published var errorMessage: String?

    /// Shows the RTT/bitrate overlay. Debug builds opt in by default.
    @Published var isDeveloperModeEnabled: Bool

    private let transport: any IntercomTransport
    private let audioSession: any AudioSessionControlling
    private var observationTasks: [Task<Void, Never>] = []
    /// Channels the user was talking on when an interruption hit, so the Talk
    /// state can be restored if the interruption ends cleanly.
    private var talkChannelsBeforeInterruption: [UUID] = []

    init(
        configuration: IntercomConfiguration = .demo,
        transport: any IntercomTransport,
        audioSession: any AudioSessionControlling,
        isDeveloperModeEnabled: Bool = IntercomViewModel.defaultDeveloperMode
    ) {
        self.configuration = configuration
        self.transport = transport
        self.audioSession = audioSession
        self.isDeveloperModeEnabled = isDeveloperModeEnabled
        startObserving()
    }

    deinit {
        for task in observationTasks { task.cancel() }
    }

    static var defaultDeveloperMode: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    var isConnected: Bool { connectionState == .connected }
    var activeTalkChannelCount: Int { configuration.channels.filter(\.isTalking).count }

    func connect() async {
        guard connectionState != .connecting else { return }
        connectionState = .connecting
        errorMessage = nil

        guard await audioSession.requestMicrophonePermission() else {
            fail(with: AudioSessionError.microphonePermissionDenied)
            return
        }

        do {
            try await audioSession.activate()
            audioRouteName = await audioSession.currentOutputName()
            try await transport.connect(configuration: configuration)
            connectionState = .connected
        } catch {
            await audioSession.deactivate()
            fail(with: error)
        }
    }

    func disconnect() async {
        await stopTalkingEverywhere()
        await transport.disconnect()
        await audioSession.deactivate()
        statistics = nil
        connectionState = .disconnected
    }

    func toggleListening(channelID: UUID) async {
        guard let index = channelIndex(for: channelID), isConnected else { return }
        guard configuration.channels[index].canListen else { return }
        let previous = configuration.channels[index].isListening
        configuration.channels[index].isListening.toggle()

        do {
            try await transport.setListening(!previous, channelID: channelID)
        } catch {
            configuration.channels[index].isListening = previous
            fail(with: error, preservingConnection: true)
        }
    }

    func setTalking(_ enabled: Bool, channelID: UUID) async {
        guard let index = channelIndex(for: channelID), isConnected else { return }
        guard configuration.channels[index].canTalk else {
            errorMessage = IntercomTransportError.notPermittedToTalk.errorDescription
            return
        }
        let previous = configuration.channels[index].isTalking
        configuration.channels[index].isTalking = enabled

        do {
            try await transport.setTalking(enabled, channelID: channelID)
        } catch {
            configuration.channels[index].isTalking = previous
            fail(with: error, preservingConnection: true)
        }
    }

    // MARK: - Event handling

    private func startObserving() {
        observationTasks.append(Task { [weak self] in
            guard let transport = self?.transport else { return }
            for await event in await transport.events() {
                guard let self else { return }
                self.apply(event)
            }
        })

        observationTasks.append(Task { [weak self] in
            guard let audioSession = self?.audioSession else { return }
            for await event in await audioSession.events() {
                guard let self else { return }
                await self.apply(event)
            }
        })
    }

    private func apply(_ event: IntercomTransportEvent) {
        switch event {
        case let .connectionStateChanged(state):
            // A transport-driven `.connected` must not resurrect a session the
            // user has already torn down.
            if case .disconnected = state, connectionState == .disconnected { return }
            connectionState = state
            if case let .failed(message) = state { errorMessage = message }

        case let .participantCountChanged(channelID, count):
            guard let index = channelIndex(for: channelID) else { return }
            configuration.channels[index].participantCount = count

        case let .remoteSpeakingChanged(channelID, isSpeaking):
            guard let index = channelIndex(for: channelID) else { return }
            configuration.channels[index].isRemoteSpeaking = isSpeaking

        case let .talkStopped(channelID):
            guard let index = channelIndex(for: channelID) else { return }
            configuration.channels[index].isTalking = false

        case let .statistics(values):
            statistics = values
        }
    }

    private func apply(_ event: AudioSessionEvent) async {
        switch event {
        case .interruptionBegan:
            // A call or Siri owns the microphone now. Drop Talk immediately so
            // the user is never shown as on air while nothing is transmitted.
            talkChannelsBeforeInterruption = configuration.channels.filter(\.isTalking).map(\.id)
            await stopTalkingEverywhere()

        case let .interruptionEnded(shouldResume):
            guard shouldResume, isConnected else {
                talkChannelsBeforeInterruption = []
                return
            }
            try? await audioSession.activate()
            // Talk is momentary: the finger has long left the button by now, so
            // the session is restored but the user has to press again.
            talkChannelsBeforeInterruption = []

        case let .routeChanged(reason, outputName):
            audioRouteName = outputName
            if reason == .deviceDisconnected {
                // Headset unplugged: audio would fall back to the speaker and
                // the phone's own mic, which on a live set means feedback.
                await stopTalkingEverywhere()
            }

        case .mediaServicesWereReset:
            // Everything below us was rebuilt; the only safe move is a full
            // reconnect.
            errorMessage = "A rendszer hangszolgáltatása újraindult, újracsatlakozás szükséges."
            await disconnect()
        }
    }

    // MARK: - Helpers

    private func channelIndex(for id: UUID) -> Int? {
        configuration.channels.firstIndex(where: { $0.id == id })
    }

    private func stopTalkingEverywhere() async {
        for index in configuration.channels.indices where configuration.channels[index].isTalking {
            let channelID = configuration.channels[index].id
            configuration.channels[index].isTalking = false
            try? await transport.setTalking(false, channelID: channelID)
        }
    }

    private func fail(with error: any Error, preservingConnection: Bool = false) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        errorMessage = message
        if !preservingConnection {
            connectionState = .failed(message: message)
        }
    }
}
