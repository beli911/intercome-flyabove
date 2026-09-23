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

    /// The one line the system can hold open behind a locked screen, and why it
    /// is that one. Nil on a build without Push to Talk.
    @Published private(set) var backgroundLine: BackgroundTalkLine.Selection?
    /// The background line is the feature an operator cannot see working. Every
    /// refusal and every silent move of it ends up here, in words, rather than
    /// being discovered on a live set.
    @Published private(set) var backgroundLineWarning: String?

    /// Ki kezelje az `AVAudioSession`-t. Alapból az app — tehát Push to Talk
    /// nélkül minden pontosan úgy működik, ahogy eddig. A másik mód a
    /// dokumentált átadás, amit **csak fizikai telefonon lehet eldönteni**,
    /// ezért váltható, nem bedrótozott.
    @Published var audioSessionOwnership: AudioSessionOwnership.Mode = .appOwns {
        didSet {
            guard oldValue != audioSessionOwnership else { return }
            let external = AudioSessionOwnership
                .shouldDisableLiveKitAutomaticConfiguration(mode: audioSessionOwnership)
            Task { [transport] in await transport.setAudioSessionManagedExternally(external) }
        }
    }
    /// Hányszor NEM nyúltunk a munkamenethez, mert a rendszeré volt. Ez a szám
    /// mondja meg egy eszközös próbán, hogy az átadás egyáltalán életbe
    /// lépett-e — enélkül a „nem működik” és a „nem is futott le”
    /// megkülönböztethetetlen.
    @Published private(set) var suppressedAudioSessionCalls = 0

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

    let events: EventLog
    private let transport: any IntercomTransport
    private let audioSession: any AudioSessionControlling
    /// Nil on a build without Push to Talk. With it nil, everything below
    /// behaves exactly as it did before this existed — which is asserted, not
    /// assumed.
    private let backgroundTalk: (any BackgroundTalkControlling)?
    /// True only while the *system* is holding the microphone open for the
    /// background line. This is what makes the background exemption safe: the
    /// system's own stop control is on screen whenever it is true.
    private var isSystemTransmitting = false
    /// The operator's explicit pick, if they made one.
    private var operatorBackgroundChoice: UUID?
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
    /// Incremented on each ducking recalculation to prevent async out-of-order race conditions.
    private var duckingGeneration = 0

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
        backgroundTalk: (any BackgroundTalkControlling)? = nil,
        events: EventLog = EventLog(),
        isDeveloperModeEnabled: Bool = IntercomViewModel.defaultDeveloperMode
    ) {
        self.configuration = configuration
        self.transport = transport
        self.audioSession = audioSession
        self.backgroundTalk = backgroundTalk
        self.events = events
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
        let toSilence = BackgroundTalkLine.channelsToSilenceOnLeavingForeground(
            talking: openTalkChannelIDs,
            backgroundLine: backgroundLine?.channelID,
            isSystemTransmitting: isSystemTransmitting
        )
        await stopTalking(on: toSilence)
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
            try await activateSessionIfOurs(recording: false)
            audioRouteName = await audioSession.currentOutputName()
            try await transport.connect(configuration: configuration)
            connectionState = .connected
            events.record(.connected, detail: configuration.productionName.isEmpty
                ? nil
                : configuration.productionName)
            // A programme feed must be at the right level from the first
            // moment, not from the first time somebody speaks.
            await updateDucking()
            await refreshBackgroundLine()
        } catch {
            await deactivateSessionIfOurs()
            fail(with: error)
        }
    }

    func disconnect() async {
        sessionGeneration += 1
        // Before the talk teardown: a system line left held after the session is
        // gone would put a live-looking Push to Talk control on the lock screen
        // of a phone that is no longer connected to anything.
        await releaseBackgroundLine()
        await stopTalkingEverywhere()
        await transport.disconnect()
        await deactivateSessionIfOurs()
        desiredTalk.removeAll()
        appliedTalk.removeAll()
        statistics = nil
        connectionState = .disconnected
        events.record(.disconnected)
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
        events.record(.failsafeDisconnect, severity: .error)
        errorMessage = "A mikrofon nem állt le, a kapcsolat biztonságból bontásra került."
        sessionGeneration += 1
        desiredTalk.removeAll()
        appliedTalk.removeAll()
        for index in configuration.channels.indices {
            configuration.channels[index].isTalking = false
        }
        await transport.disconnect()
        await deactivateSessionIfOurs()
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
        duckingGeneration += 1
        let currentGen = duckingGeneration

        let input = DuckingPolicy.Input(
            isPriorityActive: configuration.channels.contains {
                $0.role == .priority && $0.isRemoteSpeaking
            },
            isSelfTalking: configuration.channels.contains(where: \.isTalking)
        )

        for channel in configuration.channels {
            guard currentGen == duckingGeneration else { return }
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
                    try await activateSessionIfOurs(recording: true)
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
            events.record(.microphoneGranted)
            return true
        case .denied:
            isMicrophoneGranted = false
            events.record(.microphoneDenied, severity: .warning)
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

        if let backgroundTalk {
            observationTasks.append(Task { [weak self] in
                for await event in backgroundTalk.events() {
                    guard let self else { return }
                    await self.apply(event)
                }
            })
        }
    }

    private func apply(_ event: IntercomTransportEvent) {
        // LiveKit delegates fire on their own queues, so an event can land after
        // the user has already disconnected. Nothing from a torn-down session
        // may touch the UI — otherwise a late `.connected` lights it back up,
        // or a stale participant count contradicts an empty screen.
        guard connectionState != .disconnected else { return }

        switch event {
        case let .connectionStateChanged(state):
            // Only transitions are worth logging; the transport repeats the
            // current state on every room event.
            if state != connectionState {
                switch state {
                case .reconnecting: events.record(.reconnecting, severity: .warning)
                case .connected where connectionState == .reconnecting:
                    events.record(.connected)
                case let .failed(message):
                    events.record(.connectionFailed, severity: .error, detail: message)
                default: break
                }
            }
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
            if configuration.channels.first(where: { $0.id == channelID })?.isTalking == true {
                events.record(
                    .talkStoppedBySystem,
                    severity: .warning,
                    detail: channelName(channelID)
                )
            }
            clearTalk(channelID: channelID)

        case let .statistics(values):
            statistics = values

        case let .configurationStale(version):
            events.record(.configurationChanged, detail: "v\(version)")
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
        // Not `uniqueKeysWithValues`: a server that names a channel twice would
        // trap here, taking the app down mid-broadcast instead of producing
        // something readable. A duplicate is refused rather than resolved,
        // because which copy wins would depend on response order.
        var incoming: [UUID: ChannelDescriptor] = [:]
        for descriptor in descriptors {
            guard incoming.updateValue(descriptor, forKey: descriptor.id) == nil else {
                events.record(
                    .invalidServerResponse,
                    severity: .error,
                    detail: "ugyanaz a csatorna kétszer szerepel a listában"
                )
                return
            }
        }

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
        // So may the background line: the server can revoke talk on exactly the
        // line the operator was relying on from their pocket.
        await refreshBackgroundLine()

        if !removed.isEmpty || descriptors.count != merged.count {
            errorMessage = nil
        }
    }

    private func apply(_ event: AudioSessionEvent) async {
        switch event {
        case .interruptionBegan:
            events.record(.interrupted, severity: .warning)
            // A call or Siri owns the microphone now. Drop Talk immediately so
            // the user is never shown as on air while nothing is transmitted.
            await stopTalkingEverywhere()

        case let .interruptionEnded(shouldResume):
            guard shouldResume, isConnected else { return }
            // Talk is momentary, so the finger has long left the button: restore
            // the session at the level the user is actually using.
            let isTalking = desiredTalk.values.contains(true) && isMicrophoneGranted == true
            try? await activateSessionIfOurs(recording: isTalking)

        case let .routeChanged(reason, outputName):
            if outputName != audioRouteName {
                events.record(.routeChanged, detail: outputName)
            }
            audioRouteName = outputName
            if reason == .deviceDisconnected {
                // Headset unplugged: audio would fall back to the speaker and
                // the phone's own mic, which on a live set means feedback.
                await stopTalkingEverywhere()
            }

        case .mediaServicesWereReset:
            events.record(.mediaServicesReset, severity: .error)
            // Everything below us was rebuilt; the only safe move is a full
            // reconnect.
            errorMessage = "A rendszer hangszolgáltatása újraindult, újracsatlakozás szükséges."
            await disconnect()
        }
    }

    // MARK: - Helpers

    private func channelName(_ id: UUID) -> String? {
        configuration.channels.first { $0.id == id }?.name
    }

    private func channelIndex(for id: UUID) -> Int? {
        configuration.channels.firstIndex(where: { $0.id == id })
    }

    /// Every line whose microphone is open or on its way open.
    private var openTalkChannelIDs: [UUID] {
        configuration.channels
            .filter { $0.isTalking || desiredTalk[$0.id] == true }
            .map(\.id)
    }

    /// Closes some of the open microphones rather than all of them.
    ///
    /// When nothing is exempt this hands straight over to
    /// `stopTalkingEverywhere`, so the path the app has always taken is
    /// literally the same code. The subset branch exists for exactly one case: a
    /// background line the system is holding open with its own stop control on
    /// screen.
    private func stopTalking(on channelIDs: [UUID]) async {
        let exempt = openTalkChannelIDs.filter { !channelIDs.contains($0) }
        guard !exempt.isEmpty else {
            await stopTalkingEverywhere()
            return
        }

        for id in channelIDs {
            desiredTalk[id] = false
            if let index = channelIndex(for: id) {
                configuration.channels[index].isTalking = false
            }
            startTalkWorker(channelID: id)
        }
        await waitForTalkWorkToSettle()

        // Judged only on the lines we actually tried to close. Reading the
        // deliberately-open background line as a stuck microphone would drop the
        // session every time an operator pockets the phone mid-transmission —
        // the fail-safe would be firing on the feature working.
        if channelIDs.contains(where: { (appliedTalk[$0] ?? .off) != .off }) {
            await forceDisconnectForUnstoppableMicrophone()
        }
    }

    /// Aktiválja a munkamenetet, ha az most a miénk.
    ///
    /// A kihagyás nem néma: számlálót léptet és naplóz. Egy csendes no-op
    /// pontosan az a hibaosztály, ami ellen ez az egész készült.
    private func activateSessionIfOurs(recording: Bool) async throws {
        guard AudioSessionOwnership.mayAppActivate(
            mode: audioSessionOwnership,
            isBackgroundLineHeld: backgroundLine?.channelID != nil
        ) else {
            suppressedAudioSessionCalls += 1
            events.record(.audioSessionHandedOver, detail: "aktiválás kihagyva")
            return
        }
        try await audioSession.activate(recording: recording)
    }

    private func deactivateSessionIfOurs() async {
        guard AudioSessionOwnership.mayAppDeactivate(
            mode: audioSessionOwnership,
            isBackgroundLineHeld: backgroundLine?.channelID != nil
        ) else {
            suppressedAudioSessionCalls += 1
            events.record(.audioSessionHandedOver, detail: "lezárás kihagyva")
            return
        }
        await audioSession.deactivate()
    }

    // MARK: - Background line

    /// Re-decides which line the system holds, and says so when it moved.
    private func refreshBackgroundLine() async {
        guard let backgroundTalk else { return }

        let candidates = configuration.channels.map {
            BackgroundTalkLine.Candidate(
                id: $0.id,
                name: $0.name,
                role: $0.role,
                canTalk: $0.canTalk,
                isListening: $0.isListening,
                isPrivate: $0.isPrivate
            )
        }
        let selection = BackgroundTalkLine.select(
            from: candidates,
            operatorChoice: operatorBackgroundChoice
        )
        guard selection != backgroundLine else { return }
        backgroundLine = selection
        print("[Flycom][hattervonal] alap=\(selection.basis) csatorna=\(selection.channelID.flatMap(channelName) ?? "nincs") elveszett=\(String(describing: selection.lostOperatorChoice))")

        if let lost = selection.lostOperatorChoice {
            // The operator's pick is kept, not cleared: if the server grants
            // talk back, the line they chose should return without them having
            // to notice it ever went.
            backgroundLineWarning = Self.warning(for: lost, replacedBy: selection.channelID.flatMap(channelName))
            events.record(.backgroundLineLost, severity: .warning, detail: backgroundLineWarning)
        }

        if let id = selection.channelID, let name = channelName(id) {
            await backgroundTalk.join(channelID: id, name: name)
        } else {
            isSystemTransmitting = false
            await backgroundTalk.leave()
        }
    }

    private static func warning(for lost: BackgroundTalkLine.LostChoice, replacedBy: String?) -> String {
        let replacement = replacedBy.map { "Mostantól a(z) „\($0)” vonalon szólalhatsz meg." }
            ?? "Jelenleg EGYETLEN vonalon sem tudsz megszólalni lezárt képernyőn."
        switch lost {
        case .removed:
            return "A háttérvonalnak választott csatorna megszűnt. " + replacement
        case let .noLongerTalkable(name):
            return "A(z) „\(name)” vonalon a szerver visszavonta a beszéd jogát. " + replacement
        case let .becamePrivate(name):
            return "A(z) „\(name)” privát hívás lett, azt nem tartjuk háttérvonalként. " + replacement
        }
    }

    private func releaseBackgroundLine() async {
        guard let backgroundTalk else { return }
        isSystemTransmitting = false
        backgroundLine = nil
        await backgroundTalk.leave()
    }

    private func apply(_ event: BackgroundTalkEvent) async {
        switch event {
        case let .joined(channelID, wasRestored):
            events.record(
                .backgroundLineHeld,
                detail: wasRestored ? "visszaállítva" : channelName(channelID)
            )

        case let .left(channelID, wasOurDecision):
            isSystemTransmitting = false
            guard !wasOurDecision else { return }
            // The system or the user took the line. Nothing on our screen would
            // show that, so it has to be said: the pocket just went quiet.
            let name = channelName(channelID).map { "„\($0)”" } ?? "A háttérvonal"
            backgroundLineWarning = "\(name) lekerült a rendszerről: lezárt képernyőn most nem tudsz megszólalni."
            events.record(.backgroundLineLost, severity: .warning, detail: channelName(channelID))
            backgroundLine = nil

        case let .beganTransmitting(channelID, fromAccessoryButton):
            isSystemTransmitting = true
            if fromAccessoryButton {
                events.record(.backgroundLineHeld, detail: "gombos adás")
            }
            requestTalking(true, channelID: channelID)

        case let .endedTransmitting(channelID):
            isSystemTransmitting = false
            requestTalking(false, channelID: channelID)

        case .audioSessionActivated, .audioSessionDeactivated:
            // Ownership of the session while the system transmits is a separate,
            // device-measured round: see the vault note. Recording nothing here
            // is deliberate — a log line would suggest we had acted.
            break

        case let .unavailable(reason):
            backgroundLineWarning = reason
            events.record(.backgroundLineLost, severity: .warning, detail: reason)

        case let .unsupported(reason):
            // Logged, not warned about. The line simply does not exist on this
            // build, and the screen says so by showing no background line at
            // all rather than by raising an alarm the operator cannot act on.
            backgroundLine = nil
            events.record(.backgroundLineLost, detail: reason)
        }
    }

    /// The name of the line the system holds, or nil when it holds none.
    var backgroundLineName: String? {
        backgroundLine?.channelID.flatMap(channelName)
    }

    /// Clears a background-line warning the operator has read.
    func dismissBackgroundLineWarning() {
        backgroundLineWarning = nil
    }

    /// Lets the operator nominate the background line themselves.
    func chooseBackgroundLine(_ channelID: UUID?) async {
        operatorBackgroundChoice = channelID
        backgroundLineWarning = nil
        await refreshBackgroundLine()
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
