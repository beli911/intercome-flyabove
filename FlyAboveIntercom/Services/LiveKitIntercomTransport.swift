import Foundation
import LiveKit

/// Production transport: one LiveKit room per intercom channel.
///
/// Room-per-channel is what makes a party line behave like an intercom rather
/// than a conference call. Talking on "Kamera" must not be audible on
/// "Rendező", and with an SFU the only reliable way to say that is to keep the
/// audiences in separate rooms. The cost is one peer connection per joined
/// channel, which is acceptable for the handful of channels a production runs.
///
/// Permissions are not enforced here: the server decides `canPublish` when it
/// mints each room token. The `canPublish` flag on the grant only lets the UI
/// fail fast with a readable message.
actor LiveKitIntercomTransport: IntercomTransport {
    private struct ChannelSession {
        let room: Room
        let observer: RoomObserver
        let grant: RealtimeGrant
    }

    private let api: any IntercomAPI
    private let auth: AuthService
    private let extraIceServers: [IceServer]
    private let statisticsInterval: Duration
    private let grantRenewalInterval: Duration
    /// Renew a grant this far before it expires. A room re-joined after a long
    /// outage must not present a token the server has already stopped honouring.
    private let grantRenewalLeadTime: TimeInterval
    private let recoveryAttempts: Int

    private var serverURL: URL?
    private var grants: [UUID: RealtimeGrant] = [:]
    private var sessions: [UUID: ChannelSession] = [:]
    /// What the user asked for, as opposed to which rooms happen to be joined.
    /// A room is kept alive while either flag holds, and released when neither
    /// does — the two are set from independent UI controls, so neither alone
    /// can decide the room's fate.
    private var wantsListening: Set<UUID> = []
    private var wantsTalking: Set<UUID> = []
    /// Per-channel playout gain. Kept here because a room that is left and
    /// re-joined would otherwise come back at unity and undo the operator's mix.
    private var volumes: [UUID: Double] = [:]
    /// Per-room connection state. One channel reconnecting must not be masked
    /// by another reporting `.connected`.
    private var roomStates: [UUID: RoomLinkState] = [:]
    /// In-flight joins. Actor isolation does not help here: `room.connect` is an
    /// await, and a Listen and a Talk arriving together would otherwise both
    /// find `sessions[channelID] == nil` and open two rooms, of which only the
    /// last would stay under lifecycle management.
    private var joinTasks: [UUID: (token: Int, task: Task<Void, any Error>)] = [:]
    private var nextJoinToken = 0
    /// Bumped by every connect and teardown. A `room.connect` that returns after
    /// the session it belonged to is gone must not install itself.
    private var sessionGeneration = 0
    private var lastConfigurationVersion = 0
    private var continuations: [UUID: AsyncStream<IntercomTransportEvent>.Continuation] = [:]
    private var statisticsTask: Task<Void, Never>?
    private var grantRenewalTask: Task<Void, Never>?
    /// Per-channel recovery for a room LiveKit has given up on.
    private var recoveryTasks: [UUID: Task<Void, Never>] = [:]
    /// Kept so grants can be re-minted without the UI asking.
    private var configuration: IntercomConfiguration?

    init(
        api: any IntercomAPI,
        auth: AuthService,
        extraIceServers: [IceServer] = [],
        statisticsInterval: Duration = .seconds(2),
        grantRenewalInterval: Duration = .seconds(60),
        grantRenewalLeadTime: TimeInterval = 10 * 60,
        recoveryAttempts: Int = 5
    ) {
        self.api = api
        self.auth = auth
        self.extraIceServers = extraIceServers
        self.statisticsInterval = statisticsInterval
        self.grantRenewalInterval = grantRenewalInterval
        self.grantRenewalLeadTime = grantRenewalLeadTime
        self.recoveryAttempts = recoveryAttempts
    }

    // MARK: - IntercomTransport

    func connect(configuration: IntercomConfiguration) async throws {
        guard let productionID = configuration.productionID else {
            throw IntercomTransportError.missingProduction
        }

        sessionGeneration += 1
        emit(.connectionStateChanged(.connecting))

        do {
            let accessToken = try await auth.validAccessToken()
            let response = try await api.realtimeTokens(
                productionID: productionID,
                channelIDs: configuration.channels.map(\.id),
                accessToken: accessToken
            )

            serverURL = response.url
            grants = Dictionary(uniqueKeysWithValues: response.grants.map { ($0.channelId, $0) })
            self.configuration = configuration

            // Join everything the user is already listening to. Talk-only
            // channels stay unjoined until the Talk button is pressed, so an
            // idle client holds no peer connection it does not need.
            for channel in configuration.channels where channel.isListening && channel.canListen {
                wantsListening.insert(channel.id)
                try await join(channelID: channel.id)
            }

            startStatisticsPolling()
            startGrantRenewal()
            emit(.connectionStateChanged(.connected))
        } catch {
            await teardown()
            emit(.connectionStateChanged(.failed(message: error.readableMessage)))
            throw error
        }
    }

    func disconnect() async {
        await teardown()
        emit(.connectionStateChanged(.disconnected))
    }

    func setListening(_ enabled: Bool, channelID: UUID) async throws {
        if enabled {
            wantsListening.insert(channelID)
            try await join(channelID: channelID)
        } else {
            wantsListening.remove(channelID)
            await releaseRoomIfUnwanted(channelID: channelID)
        }
    }

    func setTalking(_ enabled: Bool, channelID: UUID) async throws {
        guard let grant = grants[channelID] else { throw IntercomTransportError.unknownChannel }
        guard grant.canPublish else { throw IntercomTransportError.notPermittedToTalk }

        if enabled {
            // Pressing Talk on a channel we only had a grant for joins it now.
            wantsTalking.insert(channelID)
            try await join(channelID: channelID)
        } else {
            wantsTalking.remove(channelID)
        }
        guard let session = sessions[channelID] else { throw IntercomTransportError.notConnected }

        do {
            try await session.room.localParticipant.setMicrophone(enabled: enabled)
        } catch {
            wantsTalking.remove(channelID)
            throw IntercomTransportError.realtime(message: error.readableMessage)
        }

        if !enabled {
            // Listen may have been switched off while we were still talking;
            // that request was deferred, and this is where it comes due.
            await releaseRoomIfUnwanted(channelID: channelID)
        }
    }

    /// Leaves the room once neither Listen nor Talk needs it. Leaving mid-Talk
    /// would cut the user off in the middle of a sentence, so the decision waits
    /// until both are settled.
    private func releaseRoomIfUnwanted(channelID: UUID) async {
        guard !wantsListening.contains(channelID), !wantsTalking.contains(channelID) else {
            return
        }
        await leave(channelID: channelID)
    }

    func setVolume(_ volume: Double, channelID: UUID) async throws {
        volumes[channelID] = volume
        applyVolume(channelID: channelID)
    }

    private func applyVolume(channelID: UUID) {
        guard let session = sessions[channelID] else { return }
        let volume = volumes[channelID] ?? 1.0
        for participant in session.room.remoteParticipants.values {
            for publication in participant.audioTracks {
                (publication.track as? RemoteAudioTrack)?.volume = volume
            }
        }
    }

    func events() async -> AsyncStream<IntercomTransportEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    // MARK: - Rooms

    private func join(channelID: UUID) async throws {
        if let inFlight = joinTasks[channelID] {
            return try await inFlight.task.value
        }
        guard sessions[channelID] == nil else { return }

        nextJoinToken += 1
        let token = nextJoinToken
        let generation = sessionGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            try await self.performJoin(channelID: channelID, generation: generation)
        }
        joinTasks[channelID] = (token, task)
        // Only clear our own entry: a `leave` and a fresh `join` can have
        // replaced it while this call was suspended, and blindly nilling the map
        // would let a third caller start a second parallel join.
        defer { if joinTasks[channelID]?.token == token { joinTasks[channelID] = nil } }
        try await task.value
    }

    private func performJoin(channelID: UUID, generation: Int) async throws {
        guard sessions[channelID] == nil else { return }
        guard let serverURL else { throw IntercomTransportError.notConnected }
        guard let grant = grants[channelID] else { throw IntercomTransportError.unknownChannel }

        let observer = RoomObserver(channelID: channelID) { [weak self] channelID, signal in
            Task { await self?.handle(signal, channelID: channelID) }
        }

        let room = Room(
            delegate: observer,
            connectOptions: ConnectOptions(
                autoSubscribe: grant.canSubscribe,
                // Ten attempts with the SDK's backoff covers a lift ride or a
                // Wi-Fi/cellular handover without the user touching anything.
                reconnectAttempts: 10,
                iceServers: extraIceServers,
                // The mic is published explicitly by `setTalking`, never on join.
                enableMicrophone: false
            ),
            roomOptions: RoomOptions(
                adaptiveStream: false,
                dynacast: false,
                reportRemoteTrackStatistics: true
            )
        )

        do {
            try await room.connect(url: serverURL.absoluteString, token: grant.token)
        } catch {
            throw IntercomTransportError.realtime(message: error.readableMessage)
        }

        // The connect above can take seconds. If the session was torn down or
        // this channel was left in the meantime, this room belongs to nobody:
        // hand it back rather than installing an orphan that nothing will close.
        guard generation == sessionGeneration, !Task.isCancelled, sessions[channelID] == nil else {
            await room.disconnect()
            return
        }

        sessions[channelID] = ChannelSession(room: room, observer: observer, grant: grant)
        roomStates[channelID] = RoomLinkState(room.connectionState)
        applyVolume(channelID: channelID)
        emitParticipants(channelID: channelID)
    }

    private func leave(channelID: UUID) async {
        if let inFlight = joinTasks.removeValue(forKey: channelID) {
            inFlight.task.cancel()
            // Wait it out: a join that lands after we have cleaned up would
            // otherwise resurrect the room.
            _ = try? await inFlight.task.value
        }
        roomStates.removeValue(forKey: channelID)
        guard let session = sessions.removeValue(forKey: channelID) else { return }
        await session.room.disconnect()
        emit(.participantsChanged(channelID: channelID, participants: []))
        emit(.remoteSpeakingChanged(channelID: channelID, isSpeaking: false))
    }

    private func teardown() async {
        // Clear intent first: a room disconnecting because we asked it to must
        // not look like a drop worth recovering from.
        wantsListening.removeAll()
        wantsTalking.removeAll()
        volumes.removeAll()
        lastConfigurationVersion = 0
        for task in recoveryTasks.values { task.cancel() }
        recoveryTasks.removeAll()

        statisticsTask?.cancel()
        statisticsTask = nil
        grantRenewalTask?.cancel()
        grantRenewalTask = nil
        configuration = nil
        for (channelID, session) in sessions {
            await session.room.disconnect()
            emit(.talkStopped(channelID: channelID))
        }
        sessionGeneration += 1
        let pending = joinTasks.values
        joinTasks.removeAll()
        for entry in pending {
            entry.task.cancel()
            _ = try? await entry.task.value
        }
        sessions.removeAll()
        roomStates.removeAll()
        grants.removeAll()
        serverURL = nil
    }

    private func handle(_ signal: RoomSignal, channelID: UUID) {
        switch signal {
        case let .connectionState(state):
            guard sessions[channelID] != nil else { return }
            let link = RoomLinkState(state)
            roomStates[channelID] = link
            if link == .reconnecting || link == .disconnected {
                // The publisher transport is gone; the Talk button must not
                // keep claiming we are on air.
                wantsTalking.remove(channelID)
                emit(.talkStopped(channelID: channelID))
            }
            if link == .disconnected {
                // LiveKit has exhausted its own reconnect attempts. If we still
                // want this line, the most likely reason a rejoin would fail is
                // a stale grant, so recovery re-mints before trying again.
                scheduleRecovery(channelID: channelID)
            }
            emit(.connectionStateChanged(aggregatedConnectionState()))
        case .participantsChanged:
            // A newly subscribed track starts at unity gain, so the operator's
            // level has to be re-applied whenever the roster moves.
            applyVolume(channelID: channelID)
            emitParticipants(channelID: channelID)
        case let .remoteSpeaking(isSpeaking):
            emitParticipants(channelID: channelID)
            emit(.remoteSpeakingChanged(channelID: channelID, isSpeaking: isSpeaking))
        case .localAudioUnpublished:
            emit(.talkStopped(channelID: channelID))
        case let .configurationStale(version):
            // Every joined room gets the same broadcast; only the first one
            // needs to be acted on.
            guard version > lastConfigurationVersion else { return }
            lastConfigurationVersion = version
            emit(.configurationStale(version: version))
        }
    }

    private func aggregatedConnectionState() -> ConnectionState {
        ConnectionAggregation.state(from: Array(roomStates.values))
    }

    private func emitParticipants(channelID: UUID) {
        guard let session = sessions[channelID] else { return }
        let room = session.room

        var participants = room.remoteParticipants.values.map { participant in
            ChannelParticipant(
                id: participant.identity?.stringValue ?? "",
                displayName: participant.name ?? participant.identity?.stringValue ?? "—",
                isSpeaking: participant.isSpeaking,
                quality: LinkQuality(participant.connectionQuality)
            )
        }
        let local = room.localParticipant
        participants.append(ChannelParticipant(
            id: local.identity?.stringValue ?? "",
            displayName: local.name ?? "—",
            isSpeaking: local.isSpeaking,
            quality: LinkQuality(local.connectionQuality)
        ))

        emit(.participantsChanged(
            channelID: channelID,
            participants: participants.sorted { $0.displayName < $1.displayName }
        ))
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func emit(_ event: IntercomTransportEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }

    // MARK: - Grants and recovery

    private func startGrantRenewal() {
        grantRenewalTask?.cancel()
        let interval = grantRenewalInterval
        grantRenewalTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.renewGrantsIfExpiringSoon()
            }
        }
    }

    private func renewGrantsIfExpiringSoon() async {
        let threshold = Date().addingTimeInterval(grantRenewalLeadTime)
        guard grants.values.contains(where: { $0.expiresAt <= threshold }) else { return }
        await renewGrants()
    }

    /// Re-mints every grant for the current production.
    ///
    /// A failure is not fatal: the existing grants stay in place and the next
    /// tick tries again. Losing them would turn a recoverable outage into a
    /// forced re-login.
    @discardableResult
    private func renewGrants() async -> Bool {
        guard let configuration, let productionID = configuration.productionID else { return false }
        do {
            let accessToken = try await auth.validAccessToken()
            let response = try await api.realtimeTokens(
                productionID: productionID,
                channelIDs: configuration.channels.map(\.id),
                accessToken: accessToken
            )
            serverURL = response.url
            for grant in response.grants { grants[grant.channelId] = grant }
            return true
        } catch {
            return false
        }
    }

    private func scheduleRecovery(channelID: UUID) {
        guard recoveryTasks[channelID] == nil else { return }
        guard wantsListening.contains(channelID) || wantsTalking.contains(channelID) else { return }
        recoveryTasks[channelID] = Task { [weak self] in
            await self?.recover(channelID: channelID)
        }
    }

    /// Rebuilds a channel LiveKit could not hold, with a fresh grant and
    /// widening backoff.
    private func recover(channelID: UUID) async {
        defer { recoveryTasks[channelID] = nil }

        var delay = Duration.seconds(1)
        for _ in 0 ..< recoveryAttempts {
            guard wantsListening.contains(channelID) || wantsTalking.contains(channelID) else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            delay = min(delay * 2, .seconds(16))

            await renewGrants()
            await leave(channelID: channelID)
            do {
                try await join(channelID: channelID)
                emit(.connectionStateChanged(aggregatedConnectionState()))
                return
            } catch {
                continue
            }
        }

        emit(.connectionStateChanged(.failed(
            message: "Egy vonal nem állítható helyre. Bontsd és csatlakozz újra."
        )))
    }

    // MARK: - Statistics

    private func startStatisticsPolling() {
        statisticsTask?.cancel()
        let interval = statisticsInterval
        statisticsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.publishStatistics()
            }
        }
    }

    /// Reads the nominated ICE candidate pair of any joined room. All rooms run
    /// over the same network path, so one sample describes the link.
    private func publishStatistics() {
        let tracks = sessions.values.flatMap { session -> [Track] in
            let local = session.room.localParticipant.audioTracks.compactMap(\.track)
            let remote = session.room.remoteParticipants.values
                .flatMap(\.audioTracks)
                .compactMap(\.track)
            return local + remote
        }

        let pairs = tracks
            .compactMap(\.statistics)
            .flatMap(\.iceCandidatePair)
        guard let pair = pairs.first(where: { $0.nominated == true }) ?? pairs.first else { return }

        emit(.statistics(IntercomStatistics(
            roundTripTimeMilliseconds: pair.currentRoundTripTime.map { $0 * 1000 },
            availableOutgoingBitrateKbps: pair.availableOutgoingBitrate.map { $0 / 1000 },
            availableIncomingBitrateKbps: pair.availableIncomingBitrate.map { $0 / 1000 },
            updatedAt: Date()
        )))
    }
}

// MARK: - Delegate bridge

/// LiveKit calls back on its own queues; this class turns those callbacks into
/// `Sendable` values and hops them onto the transport actor. Nothing that is not
/// a plain value ever crosses the boundary.
private enum RoomSignal: Sendable {
    case connectionState(LiveKit.ConnectionState)
    case participantsChanged
    case remoteSpeaking(Bool)
    case localAudioUnpublished
    case configurationStale(version: Int)
}

private final class RoomObserver: NSObject, RoomDelegate, @unchecked Sendable {
    private let channelID: UUID
    private let handler: @Sendable (UUID, RoomSignal) -> Void

    init(channelID: UUID, handler: @escaping @Sendable (UUID, RoomSignal) -> Void) {
        self.channelID = channelID
        self.handler = handler
    }

    func room(
        _: Room,
        didUpdateConnectionState connectionState: LiveKit.ConnectionState,
        from _: LiveKit.ConnectionState
    ) {
        handler(channelID, .connectionState(connectionState))
    }

    func room(_: Room, participantDidConnect _: RemoteParticipant) {
        handler(channelID, .participantsChanged)
    }

    func room(_: Room, participantDidDisconnect _: RemoteParticipant) {
        handler(channelID, .participantsChanged)
    }

    func room(_: Room, participant _: RemoteParticipant, didSubscribeTrack _: RemoteTrackPublication) {
        handler(channelID, .participantsChanged)
    }

    func room(_: Room, participant _: Participant, didUpdateConnectionQuality _: ConnectionQuality) {
        handler(channelID, .participantsChanged)
    }

    func room(_: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        handler(channelID, .remoteSpeaking(participants.contains { $0 is RemoteParticipant }))
    }

    func room(_: Room, participant _: LocalParticipant, didUnpublishTrack _: LocalTrackPublication) {
        handler(channelID, .localAudioUnpublished)
    }

    /// Server-sent control messages. Parsed here so nothing but a value type
    /// crosses onto the transport actor.
    func room(
        _: Room,
        participant _: RemoteParticipant?,
        didReceiveData data: Data,
        forTopic _: String,
        encryptionType _: EncryptionType
    ) {
        guard
            let payload = try? JSONDecoder().decode(ControlMessage.self, from: data),
            payload.type == "configuration"
        else { return }
        handler(channelID, .configurationStale(version: payload.version))
    }
}

private struct ControlMessage: Decodable {
    let type: String
    let version: Int
}


private extension RoomLinkState {
    init(_ state: LiveKit.ConnectionState) {
        switch state {
        case .connected: self = .connected
        case .connecting: self = .connecting
        case .reconnecting: self = .reconnecting
        case .disconnected, .disconnecting: self = .disconnected
        @unknown default: self = .disconnected
        }
    }
}


private extension LinkQuality {
    init(_ quality: ConnectionQuality) {
        switch quality {
        case .excellent: self = .excellent
        case .good: self = .good
        case .poor: self = .poor
        case .lost: self = .lost
        case .unknown: self = .unknown
        @unknown default: self = .unknown
        }
    }
}
