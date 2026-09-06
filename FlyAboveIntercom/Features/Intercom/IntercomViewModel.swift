import Combine
import Foundation

@MainActor
final class IntercomViewModel: ObservableObject {
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var configuration: IntercomConfiguration
    @Published private(set) var statistics: IntercomStatistics?
    @Published private(set) var audioRouteName: String?
    /// Nil until we have actually asked. Listening never needs the microphone,
    /// so most sessions answer this only when the user first presses Talk.
    @Published private(set) var isMicrophoneGranted: Bool?
    @Published var errorMessage: String?

    /// Shows the RTT/bitrate overlay. Debug builds opt in by default.
    @Published var isDeveloperModeEnabled: Bool
    /// Momentary by default: a microphone that needs holding cannot be left
    /// open by accident.
    @Published var talkMode: TalkMode = .momentary {
        didSet {
            guard oldValue != talkMode else { return }
            // Switching away from latch would otherwise leave a microphone open
            // with no button holding it. The safe reading of a mode change is
            // "start from silence".
            requestTalkingOnAllChannels(false)
        }
    }
    @Published var theme: AppTheme = IntercomViewModel.storedTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey) }
    }

    private static let themeKey = "hu.flyabove.intercom.theme"

    private static var storedTheme: AppTheme {
        guard let raw = UserDefaults.standard.string(forKey: themeKey) else { return .dark }
        return AppTheme(rawValue: raw) ?? .dark
    }

    private let transport: any IntercomTransport
    private let audioSession: any AudioSessionControlling
    private var observationTasks: [Task<Void, Never>] = []

    /// What the user asked for, and what the transport has been told. A Talk
    /// change is never applied directly: the request is recorded synchronously
    /// and a per-channel worker drives the transport towards it.
    private var desiredTalk: [UUID: Bool] = [:]
    private var appliedTalk: [UUID: Bool] = [:]
    private var talkWorkers: Set<UUID> = []
    /// Talk-all starts one worker per channel; without this they would each
    /// raise their own permission request and their own session activation.
    private var microphoneTask: Task<MicrophoneOutcome, Never>?

    private enum MicrophoneOutcome: Sendable, Equatable {
        case ready
        case denied
        case sessionFailed(String)
    }

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
    /// A session exists even while it is re-establishing itself. Offering
    /// "connect" here would start a second one on top of the live transport.
    var isSessionActive: Bool { connectionState == .connected || connectionState == .reconnecting }
    var isBusyConnecting: Bool { connectionState == .connecting }
    var activeTalkChannelCount: Int { configuration.channels.filter(\.isTalking).count }
    var canTalkOnAnyChannel: Bool { configuration.channels.contains(where: \.canTalk) }
    var isTalkingAnywhere: Bool { activeTalkChannelCount > 0 }

    /// True only when every line the operator may speak on is open. The
    /// "talk all" key must not claim the whole desk is live when a single
    /// channel is.
    var isTalkingOnEveryChannel: Bool {
        let talkable = configuration.channels.filter(\.canTalk)
        return !talkable.isEmpty && talkable.allSatisfy(\.isTalking)
    }

    /// Opens or closes every line the operator may speak on at once — the
    /// "call everybody" key on a physical panel.
    func requestTalkingOnAllChannels(_ enabled: Bool) {
        for channel in configuration.channels where channel.canTalk {
            requestTalking(enabled, channelID: channel.id)
        }
    }

    /// Silences every line without leaving them, so nothing is missed on the
    /// way back.
    func setListeningOnAllChannels(_ enabled: Bool) async {
        for channel in configuration.channels where channel.canListen && channel.isListening != enabled {
            await toggleListening(channelID: channel.id)
        }
    }

    var isListeningAnywhere: Bool {
        configuration.channels.contains { $0.canListen && $0.isListening }
    }

    // MARK: - Connection

    func connect() async {
        guard !isBusyConnecting, !isSessionActive else { return }
        connectionState = .connecting
        errorMessage = nil

        do {
            // Listening needs no microphone. Asking up front would lock a
            // listen-only operator out of the show over a permission they never
            // use, and would collect access we may never need. The prompt comes
            // on the first Talk instead.
            try await audioSession.activate(recording: false)
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
        desiredTalk.removeAll()
        appliedTalk.removeAll()
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

    // MARK: - Talk

    /// Records what the user wants, right now, on the main actor.
    ///
    /// Synchronous on purpose. A press and its release arrive as two separate
    /// gesture callbacks; if each started its own task, their arrival order at
    /// the transport would not be guaranteed and a late "start talking" could
    /// reopen the microphone after the finger had already left the button.
    /// Recording the intent before any suspension point makes the order a fact
    /// rather than a race.
    func requestTalking(_ enabled: Bool, channelID: UUID) {
        guard let index = channelIndex(for: channelID), isConnected else { return }
        guard configuration.channels[index].canTalk else {
            errorMessage = IntercomTransportError.notPermittedToTalk.errorDescription
            return
        }

        desiredTalk[channelID] = enabled
        configuration.channels[index].isTalking = enabled
        startTalkWorker(channelID: channelID)
    }

    /// Request and wait for the reconciler to settle. Used by tests and by any
    /// caller that needs the transport to have caught up.
    func setTalking(_ enabled: Bool, channelID: UUID) async {
        requestTalking(enabled, channelID: channelID)
        await waitForTalkWorkToSettle()
    }

    /// Resolves once no channel has pending Talk work.
    func waitForTalkWorkToSettle(timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !talkWorkers.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func startTalkWorker(channelID: UUID) {
        guard !talkWorkers.contains(channelID) else { return }
        talkWorkers.insert(channelID)
        Task { @MainActor [weak self] in
            await self?.reconcileTalk(channelID: channelID)
        }
    }

    /// Drives one channel towards its desired state, re-reading that state after
    /// every await so the most recent request always wins.
    private func reconcileTalk(channelID: UUID) async {
        defer { talkWorkers.remove(channelID) }

        while true {
            let desired = desiredTalk[channelID] ?? false
            let applied = appliedTalk[channelID] ?? false
            guard desired != applied else { return }

            // The permission sheet can sit on screen for seconds. Acquire access
            // first, then loop so the desired state is read again — otherwise a
            // button released while the prompt was up would still open the
            // microphone once the user tapped "Allow".
            if desired, isMicrophoneGranted != true {
                guard await ensureMicrophoneAccess() else {
                    clearTalk(channelID: channelID)
                    return
                }
                continue
            }

            do {
                try await transport.setTalking(desired, channelID: channelID)
                appliedTalk[channelID] = desired
            } catch {
                clearTalk(channelID: channelID)
                fail(with: error, preservingConnection: true)
                return
            }
        }
    }

    private func clearTalk(channelID: UUID) {
        desiredTalk[channelID] = false
        appliedTalk[channelID] = false
        if let index = channelIndex(for: channelID) {
            configuration.channels[index].isTalking = false
        }
    }

    /// Asks for the microphone the first time the user actually wants to speak,
    /// once, however many channels want it at that moment.
    private func ensureMicrophoneAccess() async -> Bool {
        if isMicrophoneGranted == true { return true }

        var isOwner = false
        if microphoneTask == nil {
            let audioSession = audioSession
            microphoneTask = Task { @MainActor in
                guard await audioSession.requestMicrophonePermission() else { return .denied }
                // Listening ran on a playback-only session; speaking needs the
                // record category.
                do {
                    try await audioSession.activate(recording: true)
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    return .sessionFailed(message)
                }
                return .ready
            }
            isOwner = true
        }

        guard let task = microphoneTask else { return false }
        let outcome = await task.value
        if isOwner { microphoneTask = nil }

        switch outcome {
        case .ready:
            isMicrophoneGranted = true
            return true
        case .denied:
            isMicrophoneGranted = false
            errorMessage = AudioSessionError.microphonePermissionDenied.errorDescription
            return false
        case let .sessionFailed(message):
            errorMessage = message
            return false
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
        // LiveKit delegates fire on their own queues, so an event can land after
        // the user has already disconnected. Nothing from a torn-down session
        // may touch the UI — otherwise a late `.connected` lights it back up,
        // or a stale participant count contradicts an empty screen.
        guard connectionState != .disconnected else { return }

        switch event {
        case let .connectionStateChanged(state):
            connectionState = state
            if case let .failed(message) = state { errorMessage = message }

        case let .participantCountChanged(channelID, count):
            guard let index = channelIndex(for: channelID) else { return }
            configuration.channels[index].participantCount = count

        case let .remoteSpeakingChanged(channelID, isSpeaking):
            guard let index = channelIndex(for: channelID) else { return }
            configuration.channels[index].isRemoteSpeaking = isSpeaking

        case let .talkStopped(channelID):
            clearTalk(channelID: channelID)

        case let .statistics(values):
            statistics = values
        }
    }

    private func apply(_ event: AudioSessionEvent) async {
        switch event {
        case .interruptionBegan:
            // A call or Siri owns the microphone now. Drop Talk immediately so
            // the user is never shown as on air while nothing is transmitted.
            await stopTalkingEverywhere()

        case let .interruptionEnded(shouldResume):
            guard shouldResume, isConnected else { return }
            // Talk is momentary, so the finger has long left the button: restore
            // the session at the level the user is actually using.
            try? await audioSession.activate(recording: isMicrophoneGranted == true)

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
        for channel in configuration.channels where channel.isTalking || desiredTalk[channel.id] == true {
            desiredTalk[channel.id] = false
            if let index = channelIndex(for: channel.id) {
                configuration.channels[index].isTalking = false
            }
            startTalkWorker(channelID: channel.id)
        }
        await waitForTalkWorkToSettle()

        // If a microphone still has not closed, the screen says silent while the
        // line may not be. Tearing the transport down is drastic, but a stuck
        // open microphone on a live production is worse than a dropped session.
        if appliedTalk.values.contains(true) {
            errorMessage = "A mikrofon nem állt le időben, a kapcsolat bontásra került."
            appliedTalk.removeAll()
            await transport.disconnect()
            connectionState = .disconnected
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
