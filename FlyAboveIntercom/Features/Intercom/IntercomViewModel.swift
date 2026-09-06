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
    /// Called when the server says our configuration is stale. The view model
    /// does not fetch: whoever owns the API sets this and hands back the fresh
    /// channel list.
    var onConfigurationStale: (@MainActor (Int) async -> Void)?
    private var observationTasks: [Task<Void, Never>] = []

    /// What the user asked for, and what the transport has been told. A Talk
    /// change is never applied directly: the request is recorded synchronously
    /// and a per-channel worker drives the transport towards it.
    private var desiredTalk: [UUID: Bool] = [:]
    /// What the transport has been told. `unknown` matters: a failed *stop* is
    /// not a stop, and recording it as `off` is how a stuck microphone slips
    /// past the fail-safe.
    private var appliedTalk: [UUID: AppliedTalk] = [:]
    /// Incremented by every connect and disconnect, so a permission prompt that
    /// resolves after the user left cannot act on a session that is gone.
    private var sessionGeneration = 0

    private enum AppliedTalk: Sendable, Equatable {
        case off
        case on
        case unknown
    }
    /// Channel to the session generation its worker belongs to. A forced
    /// disconnect bumps the generation, and any worker still in flight then
    /// exits instead of writing state into a session that is gone — or
    /// blocking the first Talk of the next one.
    private var talkWorkers: [UUID: Int] = [:]
    /// Talk-all starts one worker per channel; without this they would each
    /// raise their own permission request and their own session activation.
    private var microphoneTask: Task<MicrophoneOutcome, Never>?

    private enum MicrophoneOutcome: Sendable, Equatable {
        case ready
        case denied
        /// The session was torn down while the system prompt was on screen.
        case abandoned
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

    /// The app left the foreground. A latched microphone must not stay open
    /// behind another app: the button that would close it is no longer on
    /// screen.
    func handleSceneActivation(isActive: Bool) async {
        guard !isActive else { return }
        await stopTalkingEverywhere()
    }

    /// Per-channel playout gain. Unity is 1.0; the UI offers roughly -∞ to +6 dB.
    func setVolume(_ volume: Double, channelID: UUID) async {
        guard let index = channelIndex(for: channelID) else { return }
        let previous = configuration.channels[index].volume
        configuration.channels[index].volume = volume
        do {
            try await transport.setVolume(volume, channelID: channelID)
        } catch {
            configuration.channels[index].volume = previous
            fail(with: error, preservingConnection: true)
        }
    }

    /// The production roster merged with who the transport can actually hear.
    ///
    /// The API knows who belongs here; only the realtime connection knows who
    /// turned up. A crew list built from either one alone would be wrong.
    func crew(roster: [CrewMember]) -> [CrewMember] {
        var presence: [String: (speaking: Bool, quality: LinkQuality, channels: [UUID])] = [:]
        for channel in configuration.channels {
            for participant in channel.participants {
                var entry = presence[participant.id] ?? (false, .unknown, [])
                entry.speaking = entry.speaking || participant.isSpeaking
                entry.quality = max(entry.quality, participant.quality)
                entry.channels.append(channel.id)
                presence[participant.id] = entry
            }
        }

        return roster.map { member in
            var merged = member
            if let seen = presence[member.id.uuidString.lowercased()] {
                merged.isOnline = true
                merged.isSpeaking = seen.speaking
                merged.quality = seen.quality
                merged.activeChannelIDs = seen.channels
            } else {
                merged.isOnline = false
                merged.isSpeaking = false
                merged.quality = .unknown
                merged.activeChannelIDs = []
            }
            return merged
        }
        // Speaking first, then online, then alphabetical: the person talking is
        // the one an operator is looking for.
        .sorted { lhs, rhs in
            if lhs.isSpeaking != rhs.isSpeaking { return lhs.isSpeaking }
            if lhs.isOnline != rhs.isOnline { return lhs.isOnline }
            return lhs.displayName < rhs.displayName
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
        sessionGeneration += 1
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
            // A programme feed must be at the right level from the first
            // moment, not from the first time somebody speaks.
            await updateDucking()
        } catch {
            await audioSession.deactivate()
            fail(with: error)
        }
    }

    func disconnect() async {
        sessionGeneration += 1
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
        // Through `setTalkingFlag`, not inline: that is what recomputes the
        // ducking, and a programme feed has to dip as the button goes down,
        // not once the transport has caught up.
        setTalkingFlag(enabled, channelID: channelID)
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
        // An entry from an older generation is stale: its worker is on its way
        // out and must not stop this one from starting.
        if let existing = talkWorkers[channelID], existing == sessionGeneration { return }
        let generation = sessionGeneration
        talkWorkers[channelID] = generation
        Task { @MainActor [weak self] in
            await self?.reconcileTalk(channelID: channelID, generation: generation)
        }
    }

    /// Drives one channel towards its desired state, re-reading that state after
    /// every await so the most recent request always wins.
    private func reconcileTalk(channelID: UUID, generation: Int) async {
        defer { if talkWorkers[channelID] == generation { talkWorkers[channelID] = nil } }

        while true {
            // Re-checked after every suspension: a fail-safe disconnect on
            // another channel may have ended this session in the meantime.
            guard generation == sessionGeneration else { return }
            let desired = desiredTalk[channelID] ?? false
            let applied = appliedTalk[channelID] ?? .off
            // `unknown` is deliberately never "already in the desired state":
            // it has to be resolved by an actual transport call.
            guard applied != (desired ? .on : .off) else { return }

            // The permission sheet can sit on screen for seconds. Acquire access
            // first, then loop so the desired state is read again — otherwise a
            // button released while the prompt was up would still open the
            // microphone once the user tapped "Allow".
            if desired, isMicrophoneGranted != true {
                let granted = await ensureMicrophoneAccess()
                guard generation == sessionGeneration else { return }
                guard granted else {
                    clearTalk(channelID: channelID)
                    return
                }
                continue
            }

            do {
                try await transport.setTalking(desired, channelID: channelID)
                guard generation == sessionGeneration else { return }
                appliedTalk[channelID] = desired ? .on : .off
            } catch {
                guard generation == sessionGeneration else { return }
                desiredTalk[channelID] = false
                setTalkingFlag(false, channelID: channelID)

                if desired {
                    // Failing to open is safe: nothing is being transmitted.
                    appliedTalk[channelID] = .off
                    fail(with: error, preservingConnection: true)
                } else {
                    // Failing to *close* is the dangerous direction. We do not
                    // know whether the microphone is still open, so we must
                    // assume it is.
                    appliedTalk[channelID] = .unknown
                    await forceDisconnectForUnstoppableMicrophone()
                }
                return
            }
        }
    }

    /// Last resort when a microphone will not close. Dropping the session is
    /// drastic, but an open microphone nobody can see on a live production is
    /// worse than a lost connection.
    private func forceDisconnectForUnstoppableMicrophone() async {
        errorMessage = "A mikrofon nem állt le, a kapcsolat biztonságból bontásra került."
        sessionGeneration += 1
        desiredTalk.removeAll()
        appliedTalk.removeAll()
        for index in configuration.channels.indices {
            configuration.channels[index].isTalking = false
        }
        await transport.disconnect()
        await audioSession.deactivate()
        connectionState = .disconnected
    }

    private func setTalkingFlag(_ value: Bool, channelID: UUID) {
        guard let index = channelIndex(for: channelID) else { return }
        configuration.channels[index].isTalking = value
        Task { await updateDucking() }
    }

    /// Applies the ducking rules to every channel.
    ///
    /// Idempotent and cheap: the transport ignores a multiplier it already has,
    /// so this can be called from anywhere the inputs might have moved without
    /// worrying about how often.
    func updateDucking() async {
        let input = DuckingPolicy.Input(
            isPriorityActive: configuration.channels.contains {
                $0.role == .priority && $0.isRemoteSpeaking
            },
            isSelfTalking: configuration.channels.contains(where: \.isTalking)
        )

        for channel in configuration.channels {
            let multiplier = DuckingPolicy.gainMultiplier(
                for: channel.role,
                input: input,
                duckDecibels: channel.duckDecibels
            )
            try? await transport.setDucking(multiplier, channelID: channel.id)
        }
    }

    /// True while something is stepping back, so the UI can say so rather than
    /// leaving the operator wondering why a line went quiet.
    var isDuckingActive: Bool {
        let input = DuckingPolicy.Input(
            isPriorityActive: configuration.channels.contains {
                $0.role == .priority && $0.isRemoteSpeaking
            },
            isSelfTalking: configuration.channels.contains(where: \.isTalking)
        )
        return configuration.channels.contains {
            DuckingPolicy.shouldDuck(role: $0.role, input: input)
        }
    }

    private func clearTalk(channelID: UUID) {
        desiredTalk[channelID] = false
        appliedTalk[channelID] = .off
        setTalkingFlag(false, channelID: channelID)
    }

    /// Asks for the microphone the first time the user actually wants to speak,
    /// once, however many channels want it at that moment.
    private func ensureMicrophoneAccess() async -> Bool {
        if isMicrophoneGranted == true { return true }

        var isOwner = false
        if microphoneTask == nil {
            let audioSession = audioSession
            let generation = sessionGeneration
            microphoneTask = Task { @MainActor [weak self] in
                guard await audioSession.requestMicrophonePermission() else { return .denied }
                // The system prompt can stay up indefinitely. If the user hung
                // up while it was there, activating a recording session now
                // would arm a microphone for a session that no longer exists.
                guard let self, self.sessionGeneration == generation else { return .abandoned }
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
        case .abandoned:
            // The user disconnected on purpose; this is not an error to report.
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

        case let .participantsChanged(channelID, participants):
            guard let index = channelIndex(for: channelID) else { return }
            configuration.channels[index].participants = participants
            configuration.channels[index].participantCount = participants.count

        case let .remoteSpeakingChanged(channelID, isSpeaking):
            guard let index = channelIndex(for: channelID) else { return }
            configuration.channels[index].isRemoteSpeaking = isSpeaking
            Task { await updateDucking() }

        case let .talkStopped(channelID):
            clearTalk(channelID: channelID)

        case let .statistics(values):
            statistics = values

        case let .configurationStale(version):
            Task { await onConfigurationStale?(version) }
        }
    }

    /// Applies a configuration the server has just changed under us.
    ///
    /// Order matters and is deliberate. A revoked Talk is silenced before
    /// anything else is touched: the operator may be holding the button down
    /// right now, and the whole point of this push is that the microphone stops
    /// when the production says so. Only then do the cosmetic and structural
    /// changes land.
    func applyUpdatedChannels(_ descriptors: [ChannelDescriptor]) async {
        let incoming = Dictionary(
            uniqueKeysWithValues: descriptors.map { ($0.id, $0) }
        )

        // 1. Revoked Talk, on every affected channel, first.
        for channel in configuration.channels where channel.isTalking {
            let stillAllowed = incoming[channel.id]?.canTalk ?? false
            guard !stillAllowed else { continue }
            desiredTalk[channel.id] = false
            setTalkingFlag(false, channelID: channel.id)
            startTalkWorker(channelID: channel.id)
        }
        await waitForTalkWorkToSettle()

        // 2. Revoked Listen, and channels that are gone entirely.
        for channel in configuration.channels {
            let descriptor = incoming[channel.id]
            let stillAudible = descriptor?.canListen ?? false
            guard channel.isListening, !stillAudible else { continue }
            try? await transport.setListening(false, channelID: channel.id)
        }

        // 3. Merge. Names, details and colours follow the server; Listen state
        //    and volume belong to the operator and are kept where still valid.
        var merged: [IntercomChannel] = []
        for descriptor in descriptors {
            if let existing = configuration.channels.first(where: { $0.id == descriptor.id }) {
                var channel = existing
                channel.name = descriptor.name
                channel.detail = descriptor.detail
                channel.colorHex = descriptor.colorHex
                channel.canTalk = descriptor.canTalk
                channel.canListen = descriptor.canListen
                channel.role = descriptor.role ?? .line
                channel.isPrivate = descriptor.isPrivate ?? false
                channel.duckDecibels = descriptor.duckDecibels ?? 12
                channel.isListening = existing.isListening && descriptor.canListen
                channel.isTalking = existing.isTalking && descriptor.canTalk
                merged.append(channel)
            } else {
                // A channel we have just been given access to, following the
                // server's `defaultListening` exactly as a fresh session would.
                // Granting access mid-show is usually the production saying
                // "you need to hear this", and having the same descriptor mean
                // one thing at launch and another an hour later would be worse
                // than either choice on its own.
                merged.append(IntercomChannel(descriptor: descriptor))
            }
        }

        let removed = configuration.channels.filter { incoming[$0.id] == nil }
        configuration.channels = merged

        for channel in removed {
            desiredTalk[channel.id] = nil
            appliedTalk[channel.id] = nil
            try? await transport.setListening(false, channelID: channel.id)
        }

        // Roles may have changed with the configuration.
        await updateDucking()

        if !removed.isEmpty || descriptors.count != merged.count {
            errorMessage = nil
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

        // Anything that is not a confirmed `off` means the screen says silent
        // while the line may not be.
        if appliedTalk.values.contains(where: { $0 != .off }) {
            await forceDisconnectForUnstoppableMicrophone()
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
