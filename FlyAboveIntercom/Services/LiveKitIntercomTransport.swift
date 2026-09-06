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

    private var serverURL: URL?
    private var grants: [UUID: RealtimeGrant] = [:]
    private var sessions: [UUID: ChannelSession] = [:]
    private var continuations: [UUID: AsyncStream<IntercomTransportEvent>.Continuation] = [:]
    private var statisticsTask: Task<Void, Never>?

    init(
        api: any IntercomAPI,
        auth: AuthService,
        extraIceServers: [IceServer] = [],
        statisticsInterval: Duration = .seconds(2)
    ) {
        self.api = api
        self.auth = auth
        self.extraIceServers = extraIceServers
        self.statisticsInterval = statisticsInterval
    }

    // MARK: - IntercomTransport

    func connect(configuration: IntercomConfiguration) async throws {
        guard let productionID = configuration.productionID else {
            throw IntercomTransportError.missingProduction
        }

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

            // Join everything the user is already listening to. Talk-only
            // channels stay unjoined until the Talk button is pressed, so an
            // idle client holds no peer connection it does not need.
            for channel in configuration.channels where channel.isListening && channel.canListen {
                try await join(channelID: channel.id)
            }

            startStatisticsPolling()
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
            try await join(channelID: channelID)
        } else if let session = sessions[channelID] {
            // Keep the room if we are still publishing into it: leaving would
            // cut our own Talk off mid-sentence.
            let isPublishing = !session.room.localParticipant.audioTracks.isEmpty
            guard !isPublishing else { return }
            await leave(channelID: channelID)
        }
    }

    func setTalking(_ enabled: Bool, channelID: UUID) async throws {
        guard let grant = grants[channelID] else { throw IntercomTransportError.unknownChannel }
        guard grant.canPublish else { throw IntercomTransportError.notPermittedToTalk }

        if enabled {
            // Pressing Talk on a channel we only had a grant for joins it now.
            try await join(channelID: channelID)
        }
        guard let session = sessions[channelID] else { throw IntercomTransportError.notConnected }

        do {
            try await session.room.localParticipant.setMicrophone(enabled: enabled)
        } catch {
            throw IntercomTransportError.realtime(message: error.readableMessage)
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

        sessions[channelID] = ChannelSession(room: room, observer: observer, grant: grant)
        emit(.participantCountChanged(channelID: channelID, count: room.remoteParticipants.count + 1))
    }

    private func leave(channelID: UUID) async {
        guard let session = sessions.removeValue(forKey: channelID) else { return }
        await session.room.disconnect()
        emit(.participantCountChanged(channelID: channelID, count: 0))
        emit(.remoteSpeakingChanged(channelID: channelID, isSpeaking: false))
    }

    private func teardown() async {
        statisticsTask?.cancel()
        statisticsTask = nil
        for (channelID, session) in sessions {
            await session.room.disconnect()
            emit(.talkStopped(channelID: channelID))
        }
        sessions.removeAll()
        grants.removeAll()
        serverURL = nil
    }

    private func handle(_ signal: RoomSignal, channelID: UUID) {
        switch signal {
        case let .connectionState(state):
            switch state {
            case .reconnecting:
                emit(.connectionStateChanged(.reconnecting))
                // The publisher transport is gone during a reconnect; the Talk
                // button must not keep claiming we are on air.
                emit(.talkStopped(channelID: channelID))
            case .connected:
                emit(.connectionStateChanged(.connected))
            case .disconnected:
                emit(.talkStopped(channelID: channelID))
                if sessions[channelID] != nil, sessions.count == 1 {
                    emit(.connectionStateChanged(.disconnected))
                }
            default:
                break
            }
        case let .participantCount(count):
            emit(.participantCountChanged(channelID: channelID, count: count))
        case let .remoteSpeaking(isSpeaking):
            emit(.remoteSpeakingChanged(channelID: channelID, isSpeaking: isSpeaking))
        case .localAudioUnpublished:
            emit(.talkStopped(channelID: channelID))
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func emit(_ event: IntercomTransportEvent) {
        for continuation in continuations.values { continuation.yield(event) }
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
    case participantCount(Int)
    case remoteSpeaking(Bool)
    case localAudioUnpublished
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

    func room(_ room: Room, participantDidConnect _: RemoteParticipant) {
        handler(channelID, .participantCount(room.remoteParticipants.count + 1))
    }

    func room(_ room: Room, participantDidDisconnect _: RemoteParticipant) {
        handler(channelID, .participantCount(room.remoteParticipants.count + 1))
    }

    func room(_: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        handler(channelID, .remoteSpeaking(participants.contains { $0 is RemoteParticipant }))
    }

    func room(_: Room, participant _: LocalParticipant, didUnpublishTrack _: LocalTrackPublication) {
        handler(channelID, .localAudioUnpublished)
    }
}
